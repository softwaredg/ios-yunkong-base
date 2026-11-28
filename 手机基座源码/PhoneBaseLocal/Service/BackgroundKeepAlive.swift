import AVFoundation
import Foundation

/// 锁屏/后台用静音循环播放占住 `audio` 后台模式，避免进程被挂起导致 11019 掉线。
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var watchTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "cn.iosmirror.base.keepalive")

    func start() {
        queue.async { [weak self] in self?.startLocked(reason: "start") }
    }

    func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    private func startLocked(reason: String) {
        installObserversIfNeeded()
        startWatchIfNeeded()
        if let player, player.isPlaying {
            return
        }
        rebuildPlayer(reason: reason)
    }

    private func stopLocked() {
        if let t = watchTimer {
            t.cancel()
            watchTimer = nil
        }
        for o in observers {
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func rebuildPlayer(reason: String) {
        player?.stop()
        player = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            let p = try AVAudioPlayer(data: Self.silentWav)
            p.numberOfLoops = -1
            p.volume = 0.01
            p.prepareToPlay()
            guard p.play() else {
                NSLog("[KeepAlive] play failed reason=%@", reason)
                AppRunLog.shared.append("keepalive · play failed · \(reason)")
                return
            }
            player = p
            NSLog("[KeepAlive] audio on reason=%@", reason)
            if reason != "start", reason != "watch-ok" {
                AppRunLog.shared.append("keepalive · restart · \(reason)")
            }
        } catch {
            NSLog("[KeepAlive] start error: %@", error.localizedDescription)
            AppRunLog.shared.append("keepalive · error · \(error.localizedDescription)")
        }
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(
            nc.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { [weak self] note in
                self?.queue.async {
                    guard let self else { return }
                    let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                        .flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
                    if type == .ended {
                        self.rebuildPlayer(reason: "interruption-ended")
                    } else if type == .began {
                        // 打断中：标记需重建；ended 时再开
                        self.player = nil
                    }
                }
            }
        )
        observers.append(
            nc.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.rebuildPlayer(reason: "media-reset") }
            }
        )
    }

    private func startWatchIfNeeded() {
        if watchTimer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if let player = self.player, player.isPlaying { return }
            self.rebuildPlayer(reason: "watch-not-playing")
        }
        t.resume()
        watchTimer = t
    }

    /// 约 0.1s 静音 PCM WAV（44100Hz mono 16-bit）
    private static let silentWav: Data = {
        let sampleRate: UInt32 = 44100
        let numSamples: UInt32 = 4410
        let dataSize = numSamples * 2
        var d = Data()
        d.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        d.append(UInt32(36 + dataSize).leData)
        d.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        d.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt
        d.append(UInt32(16).leData)
        d.append(UInt16(1).leData) // PCM
        d.append(UInt16(1).leData) // mono
        d.append(sampleRate.leData)
        d.append(UInt32(sampleRate * 2).leData)
        d.append(UInt16(2).leData)
        d.append(UInt16(16).leData)
        d.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        d.append(dataSize.leData)
        d.append(Data(count: Int(dataSize)))
        return d
    }()
}

private extension UInt16 {
    var leData: Data {
        var v = self.littleEndian
        return Data(bytes: &v, count: 2)
    }
}

private extension UInt32 {
    var leData: Data {
        var v = self.littleEndian
        return Data(bytes: &v, count: 4)
    }
}
