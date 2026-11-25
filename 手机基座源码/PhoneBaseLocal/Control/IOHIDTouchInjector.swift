import Foundation
import UIKit
import Darwin

/// 对齐 tipa `STHIDEventGenerator`（OwnGoalStudio/TrollVNC）digitizer / Home 路径。
final class IOHIDTouchInjector: TouchInjector {
    private let client: OpaquePointer?
    private let queue = DispatchQueue(label: "cn.local.phonebase.hid-events", qos: .userInteractive)
    /// Home/按键独立队列，不被滑动 drain 堵在后面（否则点 Home 体感慢半拍～1s）
    private let keyQueue = DispatchQueue(label: "cn.local.phonebase.hid-keys", qos: .userInteractive)
    private let moveLock = NSLock()
    private var touching = false
    private var lastX: Double = 0.5
    private var lastY: Double = 0.5
    /// 样板 pointerQueue：down/move/up 同一有序队列。旧实现 move 与 down 分路 async，
    /// 快拖时 move 可能在 touching=true 前被 drain 丢掉 → 偶发拖不动。
    private enum PtrEvt {
        case down(Double, Double)
        case move(Double, Double)
        case up(Double, Double)
        case cancel
    }
    private var evtQueue: [PtrEvt] = []
    private var moveDrainScheduled = false
    private static let evtQueueCap = 128
    /// 更细步进（约 0.6% 屏），悬浮球命中区小也不易跳脱
    private static let maxMoveStep = 0.006
    private static let maxInterpSteps = 160
    /// tipa fingerIdentifiers[0]
    private let fingerId: UInt32 = 2
    private let senderID: UInt64 = 0x8000_0008_1731_9371

    private let createDigitizer: CreateDigitizerFn?
    private let createFinger: CreateFingerFn?
    private let appendEvent: AppendEventFn?
    private let setInteger: SetIntegerFn?
    private let setFloat: SetFloatFn?
    private let setSender: SetSenderFn?
    private let createKeyboard: CreateKeyboardFn?
    private let createUnicode: CreateUnicodeFn?
    private let createUnicodeWithQuality: CreateUnicodeQualityFn?
    private let dispatchFn: DispatchFn?
    private let retainFn: RetainFn?
    private let releaseFn: ReleaseFn?

    let isAvailable: Bool

    // tipa include-spi/IOKitSPI.h — Range=1<<0 Touch=1<<1 Position=1<<2
    private static let transducerHand: UInt32 = 3
    private static let digRange: UInt32 = 1 << 0
    private static let digTouch: UInt32 = 1 << 1
    private static let digPosition: UInt32 = 1 << 2
    private static let fieldIsBuiltIn: UInt32 = 4
    private static let fieldDisplayIntegrated: UInt32 = (11 << 16) | 25
    private static let fieldMajorRadius: UInt32 = (11 << 16) | 20
    private static let fieldMinorRadius: UInt32 = (11 << 16) | 21
    private static let defaultMajorRadius: Double = 5
    private static let defaultPathPressure: Double = 0
    private static let defaultTwist: Double = 0

    static func makeIfPossible() -> IOHIDTouchInjector? {
        let inj = IOHIDTouchInjector()
        return inj.isAvailable ? inj : nil
    }

    private init() {
        _ = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

        typealias CreateClientFn = @convention(c) (CFAllocator?) -> OpaquePointer?

        createDigitizer = Self.sym("IOHIDEventCreateDigitizerEvent")
        createFinger = Self.sym("IOHIDEventCreateDigitizerFingerEvent")
        appendEvent = Self.sym("IOHIDEventAppendEvent")
        setInteger = Self.sym("IOHIDEventSetIntegerValue")
        setFloat = Self.sym("IOHIDEventSetFloatValue")
        setSender = Self.sym("IOHIDEventSetSenderID")
        createKeyboard = Self.sym("IOHIDEventCreateKeyboardEvent")
        // 同一符号两种调用约定：6 参 / 7 参(quality)；postUnicode 里依次试
        createUnicode = Self.sym("IOHIDEventCreateUnicodeEvent")
        createUnicodeWithQuality = Self.sym("IOHIDEventCreateUnicodeEvent")
        dispatchFn = Self.sym("IOHIDEventSystemClientDispatchEvent")
        retainFn = Self.sym("CFRetain")
        releaseFn = Self.sym("CFRelease")

        var clientRef: OpaquePointer?
        if let create: CreateClientFn = Self.sym("IOHIDEventSystemClientCreate") {
            // tipa: 单参数 Create(allocator)
            clientRef = create(kCFAllocatorDefault)
        }

        let ok =
            createDigitizer != nil
            && createFinger != nil
            && appendEvent != nil
            && setInteger != nil
            && setFloat != nil
            && createKeyboard != nil
            && createUnicode != nil
            && dispatchFn != nil
            && clientRef != nil

        client = clientRef
        isAvailable = ok
        NSLog(ok ? "[IOHID] ready (tipa STHID path)" : "[IOHID] unavailable")
    }

    func pointer(action: String, x: Double, y: Double) {
        guard isAvailable else { return }
        let nx = min(max(x, 0), 1)
        let ny = min(max(y, 0), 1)
        moveLock.lock()
        switch action {
        case "down":
            evtQueue.append(.down(nx, ny))
        case "move":
            evtQueue.append(.move(nx, ny))
        case "up":
            evtQueue.append(.up(nx, ny))
        case "cancel":
            // 丢掉未发出的 move，保留 down/up；最后抬指（勿用 0,0 跳点）
            evtQueue.removeAll { if case .move = $0 { return true }; return false }
            evtQueue.append(.cancel)
        default:
            moveLock.unlock()
            return
        }
        while evtQueue.count > Self.evtQueueCap {
            // 优先丢最旧 move，尽量保住 down/up/cancel 次序
            if let i = evtQueue.firstIndex(where: { if case .move = $0 { return true }; return false }) {
                evtQueue.remove(at: i)
            } else {
                evtQueue.removeFirst()
            }
        }
        let schedule = !moveDrainScheduled
        if schedule { moveDrainScheduled = true }
        moveLock.unlock()
        if schedule {
            queue.async { [weak self] in self?.drainEvtQueue() }
        }
    }

    private func drainEvtQueue() {
        while true {
            moveLock.lock()
            if evtQueue.isEmpty {
                moveDrainScheduled = false
                moveLock.unlock()
                return
            }
            let next = evtQueue.removeFirst()
            moveLock.unlock()
            switch next {
            case let .down(x, y):
                pointerLocked(action: "down", x: x, y: y)
            case let .move(x, y):
                pointerLocked(action: "move", x: x, y: y)
            case let .up(x, y):
                pointerLocked(action: "up", x: x, y: y)
            case .cancel:
                pointerLocked(action: "cancel", x: lastX, y: lastY)
            }
        }
    }

    func pressHome() {
        guard isAvailable else { return }
        // 丢掉未发出的指针事件，避免 digitizer 队列拖住后续抬起
        moveLock.lock()
        evtQueue.removeAll(keepingCapacity: true)
        moveDrainScheduled = false
        moveLock.unlock()
        keyQueue.async { [weak self] in self?.menuPulseFast() }
    }

    /// 双击 Home：两次 Menu 脉冲 → SpringBoard 多任务
    func pressAppSwitcher() {
        guard isAvailable else { return }
        moveLock.lock()
        evtQueue.removeAll(keepingCapacity: true)
        moveDrainScheduled = false
        moveLock.unlock()
        keyQueue.async { [weak self] in
            guard let self else { return }
            NSLog("[IOHID] app-switcher (double menu)")
            self.menuPulseFast()
            usleep(200_000)
            self.menuPulseFast()
        }
    }

    /// 在 keyQueue 上执行：先快速抬指，再短脉冲 Menu（约 12ms）
    private func menuPulseFast() {
        if touching {
            let sem = DispatchSemaphore(value: 0)
            queue.async { [weak self] in
                guard let self else { sem.signal(); return }
                if self.touching {
                    self.postHand(phase: .lifted, x: self.lastX, y: self.lastY)
                    self.touching = false
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 0.03)
        }
        // tipa Consumer Menu/Home 0x0C/0x40；脉冲尽量短，跟手
        postKeyboard(usagePage: 0x0C, usage: 0x40, down: true)
        usleep(12_000)
        postKeyboard(usagePage: 0x0C, usage: 0x40, down: false)
    }

    func injectText(_ text: String) {
        guard isAvailable, !text.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            NSLog("[IOHID] injectText len=%d", text.utf16.count)
            // ASCII → 键盘；中文等 → UTF16LE Unicode HID（旧实现 encoding=0=UTF8 导致进不去）
            var pending = ""
            func flushPending() {
                guard !pending.isEmpty else { return }
                let chunk = pending
                pending = ""
                if self.postUnicode(chunk) { return }
                // 兜底：逐字再试 + 剪贴板粘贴
                var ok = true
                for ch in chunk {
                    if !self.postUnicode(String(ch)) { ok = false }
                    usleep(8_000)
                }
                if !ok { self.pasteViaClipboard(chunk) }
            }
            for ch in text {
                if ch == "\n" || ch == "\r" {
                    flushPending()
                    self.injectKeyLocked("enter")
                    continue
                }
                if ch == "\t" {
                    flushPending()
                    self.injectKeyLocked("tab")
                    continue
                }
                if let usage = Self.asciiUsage(ch) {
                    flushPending()
                    self.postAsciiKey(ch, usage: usage)
                    continue
                }
                pending.append(ch)
            }
            flushPending()
        }
    }

    private func postAsciiKey(_ ch: Character, usage: UInt32) {
        let shift = ch.isUppercase || Self.shiftedAscii.contains(ch)
        if shift { postKeyboard(usagePage: 0x07, usage: 0xE1, down: true) }
        postKeyboard(usagePage: 0x07, usage: usage, down: true)
        usleep(6_000)
        postKeyboard(usagePage: 0x07, usage: usage, down: false)
        if shift { postKeyboard(usagePage: 0x07, usage: 0xE1, down: false) }
        usleep(3_000)
    }

    /// 剪贴板 + Cmd+V（Unicode 失败时兜底）
    private func pasteViaClipboard(_ text: String) {
        DispatchQueue.main.sync {
            UIPasteboard.general.string = text
        }
        usleep(40_000)
        postKeyboard(usagePage: 0x07, usage: 0xE3, down: true)
        usleep(12_000)
        postKeyboard(usagePage: 0x07, usage: 0x19, down: true)
        usleep(30_000)
        postKeyboard(usagePage: 0x07, usage: 0x19, down: false)
        usleep(12_000)
        postKeyboard(usagePage: 0x07, usage: 0xE3, down: false)
        usleep(30_000)
    }

    func injectKey(_ key: String) {
        guard isAvailable else { return }
        queue.async { [weak self] in self?.injectKeyLocked(key) }
    }

    private enum Phase { case touched, moved, lifted }

    /// 大位移插值补点：快拖时 HID 点距过大，第三方悬浮球会跟丢
    private func injectMovedInterpolated(toX x: Double, toY y: Double) {
        let x0 = lastX
        let y0 = lastY
        let dx = x - x0
        let dy = y - y0
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist < 1e-9 {
            return
        }
        var steps = Int(ceil(dist / Self.maxMoveStep))
        if steps < 1 { steps = 1 }
        if steps > Self.maxInterpSteps { steps = Self.maxInterpSteps }
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let nx = x0 + dx * t
            let ny = y0 + dy * t
            lastX = nx
            lastY = ny
            postHand(phase: .moved, x: nx, y: ny)
        }
    }

    private func pointerLocked(action: String, x: Double, y: Double) {
        switch action {
        case "down":
            touching = true
            lastX = x
            lastY = y
            postHand(phase: .touched, x: x, y: y)
        case "move":
            guard touching else { return }
            injectMovedInterpolated(toX: x, toY: y)
        case "up", "cancel":
            guard touching else { return }
            touching = false
            lastX = x
            lastY = y
            postHand(phase: .lifted, x: x, y: y)
        default:
            break
        }
    }

    /// baguette/vphone：down+move 保持 Range|Touch|Position(0x07)，
    /// 清掉 Touch 会被当成断触 → 滑动卡卡。
    private func postHand(phase: Phase, x: Double, y: Double) {
        guard
            let createDigitizer,
            let createFinger,
            let appendEvent,
            let setInteger,
            let setFloat
        else { return }

        let isTouching = (phase == .touched || phase == .moved)
        // 0x07 sustained；0x06 lift（Touch|Position）
        let eventMask: UInt32 = isTouching
            ? (Self.digRange | Self.digTouch | Self.digPosition)
            : (Self.digTouch | Self.digPosition)
        let rangeBit: Int32 = isTouching ? 1 : 0
        let touchBit: Int32 = isTouching ? 1 : 0
        let radius = isTouching ? Self.defaultMajorRadius : 0
        let ts = mach_absolute_time()

        guard let parent = createDigitizer(
            kCFAllocatorDefault, ts,
            Self.transducerHand, 0, fingerId, eventMask, 0,
            x, y, 0, Self.defaultPathPressure, 0,
            rangeBit, touchBit, 0
        ) else { return }

        setInteger(parent, Self.fieldIsBuiltIn, 1)
        setInteger(parent, Self.fieldDisplayIntegrated, 1)

        if let finger = createFinger(
            kCFAllocatorDefault, ts,
            fingerId, fingerId, eventMask,
            x, y, 0,
            Self.defaultPathPressure,
            Self.defaultTwist,
            rangeBit, touchBit, 0
        ) {
            setFloat(finger, Self.fieldMinorRadius, radius)
            setFloat(finger, Self.fieldMajorRadius, radius)
            appendEvent(parent, finger, 0)
            releaseFn?(UnsafeRawPointer(finger))
        }

        sendEvent(parent)
    }

    private func injectKeyLocked(_ key: String) {
        let map: [String: (UInt32, UInt32)] = [
            "backspace": (0x07, 0x2A),
            "enter": (0x07, 0x28),
            "tab": (0x07, 0x2B),
            "escape": (0x07, 0x29),
            "left": (0x07, 0x50),
            "right": (0x07, 0x4F),
            "up": (0x07, 0x52),
            "down": (0x07, 0x51),
        ]
        guard let (page, usage) = map[key] else { return }
        postKeyboard(usagePage: page, usage: usage, down: true)
        usleep(15_000)
        postKeyboard(usagePage: page, usage: usage, down: false)
    }

    private func postKeyboard(usagePage: UInt32, usage: UInt32, down: Bool) {
        guard let createKeyboard else { return }
        let ts = mach_absolute_time()
        guard let event = createKeyboard(kCFAllocatorDefault, ts, usagePage, usage, down ? 1 : 0, 0) else { return }
        sendEvent(event)
    }

    /// IOHIDEvent::unicodeEvent — payload + byte length + encoding(UTF16LE=1) + quality + options
    @discardableResult
    private func postUnicode(_ text: String) -> Bool {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return false }
        let byteLen = UInt32(utf16.count * 2)
        let encodingUTF16LE: UInt32 = 1
        let qualityOne: Int32 = 0x10000 // IOFixed 1.0
        let ts = mach_absolute_time()

        let event: OpaquePointer? = utf16.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return nil }
            let raw = UnsafeRawPointer(base)
            // 用户态常见 6 参：(payload, lengthBytes, encoding=UTF16LE, options)
            if let createUnicode,
               let ev = createUnicode(
                kCFAllocatorDefault, ts, raw, byteLen, encodingUTF16LE, 0
               ) {
                return ev
            }
            // 对齐内核 unicodeEvent 的 7 参（多 quality）
            if let createUnicodeWithQuality,
               let ev = createUnicodeWithQuality(
                kCFAllocatorDefault, ts, raw, byteLen, encodingUTF16LE, qualityOne, 0
               ) {
                return ev
            }
            return nil
        }
        guard let event else {
            NSLog("[IOHID] unicode create failed len=%d", text.utf16.count)
            return false
        }
        sendEvent(event)
        return true
    }

    /// tipa `_sendHIDEvent`：SetSenderID + Dispatch。
    /// 调用方已在 hid queue 上，勿再 async（否则滑动事件双跳排队，左右滑发卡）。
    private func sendEvent(_ event: OpaquePointer) {
        guard let client, let dispatchFn else {
            releaseFn?(UnsafeRawPointer(event))
            return
        }
        if let setSender {
            setSender(event, senderID)
        }
        dispatchFn(client, event)
        releaseFn?(UnsafeRawPointer(event))
    }

    private static let shiftedAscii: Set<Character> = Set("!@#$%^&*()_+{}|:\"<>?~")

    private static func asciiUsage(_ ch: Character) -> UInt32? {
        guard let v = ch.asciiValue else { return nil }
        switch v {
        case 0x30: return 0x27
        case 0x31 ... 0x39: return UInt32(0x1E + (v - 0x31))
        case 0x61 ... 0x7A: return UInt32(0x04 + (v - 0x61))
        case 0x41 ... 0x5A: return UInt32(0x04 + (v - 0x41))
        case 0x20: return 0x2C
        case 0x2D, 0x5F: return 0x2D // - _
        case 0x3D, 0x2B: return 0x2E // = +
        case 0x5B, 0x7B: return 0x2F // [ {
        case 0x5D, 0x7D: return 0x30 // ] }
        case 0x5C, 0x7C: return 0x31 // \ |
        case 0x3B, 0x3A: return 0x33 // ; :
        case 0x27, 0x22: return 0x34 // ' "
        case 0x60, 0x7E: return 0x35 // ` ~
        case 0x2C, 0x3C: return 0x36 // , <
        case 0x2E, 0x3E: return 0x37 // . >
        case 0x2F, 0x3F: return 0x38 // / ?
        case 0x21: return 0x1E // !
        case 0x40: return 0x1F // @
        case 0x23: return 0x20 // #
        case 0x24: return 0x21 // $
        case 0x25: return 0x22 // %
        case 0x5E: return 0x23 // ^
        case 0x26: return 0x24 // &
        case 0x2A: return 0x25 // *
        case 0x28: return 0x26 // (
        case 0x29: return 0x27 // )
        default: return nil
        }
    }

    private static func sym<T>(_ name: String) -> T? {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
}

private typealias CreateDigitizerFn = @convention(c) (
    CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
    Double, Double, Double, Double, Double, Int32, Int32, UInt32
) -> OpaquePointer?

private typealias CreateFingerFn = @convention(c) (
    CFAllocator?, UInt64, UInt32, UInt32, UInt32,
    Double, Double, Double, Double, Double, Int32, Int32, UInt32
) -> OpaquePointer?

private typealias AppendEventFn = @convention(c) (OpaquePointer?, OpaquePointer?, UInt32) -> Void
private typealias SetIntegerFn = @convention(c) (OpaquePointer?, UInt32, Int64) -> Void
private typealias SetFloatFn = @convention(c) (OpaquePointer?, UInt32, Double) -> Void
private typealias SetSenderFn = @convention(c) (OpaquePointer?, UInt64) -> Void
private typealias CreateKeyboardFn = @convention(c) (
    CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32
) -> OpaquePointer?
/// CreateUnicode(allocator, ts, payload, lengthBytes, encoding, options)
private typealias CreateUnicodeFn = @convention(c) (
    CFAllocator?, UInt64, UnsafeRawPointer?, UInt32, UInt32, UInt32
) -> OpaquePointer?
/// CreateUnicode(..., encoding, quality IOFixed, options)
private typealias CreateUnicodeQualityFn = @convention(c) (
    CFAllocator?, UInt64, UnsafeRawPointer?, UInt32, UInt32, Int32, UInt32
) -> OpaquePointer?
private typealias DispatchFn = @convention(c) (OpaquePointer?, OpaquePointer?) -> Void
private typealias RetainFn = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer
private typealias ReleaseFn = @convention(c) (UnsafeRawPointer?) -> Void
