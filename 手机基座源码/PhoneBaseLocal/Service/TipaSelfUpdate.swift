import Foundation
import UIKit

/// 手机端自检 tipa 更新：拉清单 → apple-magnifier:// 直跳巨魔（失败再下载 + DocumentInteraction）。
enum TipaSelfUpdate {
    static let manifestURL = URL(string: "https://touping.facaishu.vip/api/tipa/update")!

    struct Manifest {
        let version: String
        let url: String
        let notes: String
    }

    enum CheckResult {
        case upToDate(local: String, remote: String)
        case available(local: String, manifest: Manifest)
        case failed(String)
    }

    static var localVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func cmpVer(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let d = (i < pa.count ? pa[i] : 0) - (i < pb.count ? pb[i] : 0)
            if d != 0 { return d }
        }
        return 0
    }

    static func trollInstallURL(tipaHttpsURL: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        let encoded = tipaHttpsURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? tipaHttpsURL
        return URL(string: "apple-magnifier://install?url=\(encoded)")
    }

    static func check(completion: @escaping (CheckResult) -> Void) {
        var req = URLRequest(url: manifestURL, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let local = localVersion
            if let err {
                DispatchQueue.main.async { completion(.failed(err.localizedDescription)) }
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data, !data.isEmpty else {
                DispatchQueue.main.async { completion(.failed("HTTP \(code)")) }
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(.failed("清单解析失败")) }
                return
            }
            func str(_ key: String) -> String {
                if let s = obj[key] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let n = obj[key] as? NSNumber { return n.stringValue }
                return ""
            }
            let version = str("version")
            let url = str("url")
            let notes = str("notes")
            guard !version.isEmpty, url.hasPrefix("https://") else {
                DispatchQueue.main.async { completion(.failed("清单无效")) }
                return
            }
            let m = Manifest(version: version, url: url, notes: notes)
            DispatchQueue.main.async {
                if cmpVer(version, local) > 0 {
                    completion(.available(local: local, manifest: m))
                } else {
                    completion(.upToDate(local: local, remote: version))
                }
            }
        }.resume()
    }

    /// 下载 tipa 到 Documents，供 DocumentInteraction 打开。
    static func downloadTipa(manifest: Manifest, progress: ((Double) -> Void)? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let remote = URL(string: manifest.url) else {
            completion(.failure(NSError(domain: "TipaSelfUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "坏 URL"])))
            return
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dest = docs.appendingPathComponent("PhoneBase_\(manifest.version).tipa")
        try? FileManager.default.removeItem(at: dest)

        let task = URLSession.shared.downloadTask(with: remote) { tmp, resp, err in
            if let err {
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let tmp else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "TipaSelfUpdate", code: code, userInfo: [NSLocalizedDescriptionKey: "下载失败 HTTP \(code)"])))
                }
                return
            }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tmp, to: dest)
                DispatchQueue.main.async { completion(.success(dest)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
        task.resume()
    }

    /// 启动时：确认装后版本；仅在本机已相对装前 baseline 升高且达到 expect 时清标记。
    static func resumeInstalledUpdateIfNeeded() {
        guard UpdateMarker.exists else { return }
        let expect = UpdateMarker.readVersion() ?? ""
        let baseline = UpdateMarker.readBaseline() ?? ""
        let local = localVersion
        let upgraded = baseline.isEmpty || cmpVer(local, baseline) > 0
        let expectMet: Bool = {
            if expect.isEmpty || expect == "pending" { return upgraded }
            return cmpVer(local, expect) >= 0
        }()
        if upgraded && expectMet {
            AppRunLog.shared.append("装后续上完成 local=\(local) expect=\(expect) baseline=\(baseline)")
            UpdateMarker.clear()
        } else {
            AppRunLog.shared.append("装后续上：local=\(local) expect=\(expect) baseline=\(baseline)，保留标记")
        }
    }

    /// 从 apple-magnifier://install?url=… 或 tipa HTTPS URL 解析版本号。
    static func versionFromInstallURL(_ url: URL) -> String? {
        var tipaURL = url
        if (url.scheme ?? "").lowercased() == "apple-magnifier" {
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let raw = items.first(where: { $0.name.lowercased() == "url" })?.value,
                  let nested = URL(string: raw)
            else { return nil }
            tipaURL = nested
        }
        let name = tipaURL.lastPathComponent
        // IOS投屏-0.2.61.tipa / PhoneBase_0.2.61.tipa / …-0.2.61.ipa
        let pattern = #"(\d+\.\d+(?:\.\d+)?)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = re.firstMatch(in: name, range: range),
              let r = Range(match.range(at: 1), in: name)
        else { return nil }
        return String(name[r])
    }

    /// 兼容旧调用：直接 magnifier（无下载）。
    @discardableResult
    static func openInstall(manifest: Manifest, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard let u = trollInstallURL(tipaHttpsURL: manifest.url) else {
            completion?(false)
            return false
        }
        let ver = manifest.version
        DispatchQueue.global(qos: .userInitiated).async {
            HelperLauncher.armPostUpdate(expectVersion: ver)
            DispatchQueue.main.async {
                UIApplication.shared.open(u, options: [:]) { ok in
                    completion?(ok)
                }
            }
        }
        return true
    }
}

/// 持有 DocumentInteraction，避免早释放。
final class TipaDocumentHandoff: NSObject, UIDocumentInteractionControllerDelegate {
    static let shared = TipaDocumentHandoff()
    private var doc: UIDocumentInteractionController?
    private weak var presenter: UIViewController?

    func present(fileURL: URL, from vc: UIViewController, anchor: UIView) -> Bool {
        presenter = vc
        let c = UIDocumentInteractionController(url: fileURL)
        c.delegate = self
        // 不强制 UTI，便于系统列出巨魔（.tipa / .ipa）
        doc = c
        let ok = c.presentOpenInMenu(from: anchor.bounds, in: anchor, animated: true)
        if !ok {
            // 再试 options menu
            return c.presentOptionsMenu(from: anchor.bounds, in: anchor, animated: true)
        }
        return ok
    }

    func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
        // keep doc until next handoff
    }

    func documentInteractionController(_ controller: UIDocumentInteractionController, didEndSendingToApplication application: String?) {
        AppRunLog.shared.append("已交给应用打开 tipa：\(application ?? "?")")
    }
}
