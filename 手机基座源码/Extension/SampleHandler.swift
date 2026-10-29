import ReplayKit
import UIKit
import CoreMedia

/// System screen capture → TVH4 (TCP 5909 + WS /video). Control stays on host app when possible.
final class SampleHandler: RPBroadcastSampleHandler {
    private var service: LocalService?
    private let tcpVideo = TcpVideoHub()
    private let encoder = H264Encoder()
    private var started = false
    private var frameCount: UInt64 = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        PortHandoff.requestHostReleasePort()

        let fallbackId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let deviceId = String(PortHandoff.loadDeviceId(fallback: fallbackId).prefix(32))
        let name = PortHandoff.loadDeviceName(fallback: "云控基座·" + UIDevice.current.name)
        let port = UInt16(11019)

        let info = LocalService.DeviceInfo(
            deviceId: deviceId,
            name: name,
            port: port,
            width: 720,
            height: 1280,
            streaming: true,
            controlAvailable: false,
            homeAvailable: false
        )
        let svc = LocalService(info: info)
        do {
            try svc.start()
            try tcpVideo.start()
        } catch {
            Thread.sleep(forTimeInterval: 0.5)
            do {
                try svc.start()
                try tcpVideo.start()
            } catch {
                finishBroadcastWithError(error)
                return
            }
        }
        service = svc
        encoder.onParameterSets = { [weak self] sps, pps in
            self?.service?.publishConfiguration(sps: sps, pps: pps)
            self?.tcpVideo.setConfiguration(TVH4.annexBConfig(sps: sps, pps: pps))
        }
        encoder.onFrame = { [weak self] avcc, key, ts in
            self?.service?.publishFrame(avcc: avcc, keyframe: key, timestampUs: ts)
            self?.tcpVideo.sendFrame(annexB: TVH4.avccToAnnexB(avcc), keyframe: key, ptsUs: ts)
        }
        started = true
    }

    override func broadcastFinished() {
        encoder.stop()
        tcpVideo.stop()
        service?.stop()
        service = nil
        started = false
        frameCount = 0
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard started, sampleBufferType == .video,
              let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = Int32(CVPixelBufferGetWidth(pixel))
        let h = Int32(CVPixelBufferGetHeight(pixel))
        service?.updateGeometry(width: Int(w), height: Int(h))
        if frameCount == 0 {
            try? encoder.start(width: w, height: h, fps: 30, bitrateBps: 4_000_000)
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let us = UInt64(max(0, pts.seconds * 1_000_000))
        encoder.encode(pixelBuffer: pixel, ptsUs: us, forceKeyframe: frameCount % 60 == 0)
        frameCount += 1
    }
}
