import AVFoundation
import Foundation

/// 锁屏/后台用静音循环播放占住 `audio` 后台模式，避免进程被挂起导致 11019 掉线。
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private var started = false

    func start() {
        guard !started else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            let player = try AVAudioPlayer(data: Self.silentWav)
            player.numberOfLoops = -1
            player.volume = 0.01
            player.prepareToPlay()
            guard player.play() else {
                NSLog("[KeepAlive] play failed")
                return
            }
            self.player = player
            started = true
            NSLog("[KeepAlive] audio keepalive on")
        } catch {
            NSLog("[KeepAlive] start error: %@", error.localizedDescription)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        started = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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
