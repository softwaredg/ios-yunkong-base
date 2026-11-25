import Foundation
import UIKit

/// 手机端自检 tipa 更新：拉清单 → 样板式 apple-magnifier:// 直跳巨魔（workspace + UIApplication）。
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

    /// 对齐样板：LSApplicationWorkspace openSensitiveURL，再补 UIApplication.open。
    /// 不走 DocumentInteraction，避免弹「打开方式」菜单。
    static func openTrollStoreInstall(tipaHttpsURL: String, completion: ((Bool) -> Void)? = nil) {
        guard let url = trollInstallURL(tipaHttpsURL: tipaHttpsURL) else {
            DispatchQueue.main.async { completion?(false) }
            return
        }
        openTrollStore(url: url, completion: completion)
    }

    /// 打开已有的 apple-magnifier:// 或 phonebase://（控制通道复用）。
    static func openTrollStore(url: URL, completion: ((Bool) -> Void)? = nil) {
        let run: () -> Void = {
            // 样板先走 workspace；UIApplication 结果为准。
            // workspace 已调用且 canOpenURL 为真时，允许 ui 回调 false 仍算成功（部分机型握手如此）。
            let workspaceOk = openSensitiveURL(url)
            let canOpen = UIApplication.shared.canOpenURL(url)
            UIApplication.shared.open(url, options: [:]) { uiOk in
                let ok = uiOk || (workspaceOk && canOpen)
                if ok {
                    AppRunLog.shared.append(
                        "打开巨魔 ok workspace=\(workspaceOk ? 1 : 0) ui=\(uiOk ? 1 : 0) can=\(canOpen ? 1 : 0) scheme=\(url.scheme ?? "?")"
                    )
                } else {
                    AppRunLog.shared.append(
                        "打开巨魔失败 workspace=\(workspaceOk ? 1 : 0) ui=\(uiOk ? 1 : 0) can=\(canOpen ? 1 : 0) scheme=\(url.scheme ?? "?")"
                    )
                }
                completion?(ok)
            }
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    /// 样板同款：defaultWorkspace openSensitiveURL:withOptions:
    @discardableResult
    static func openSensitiveURL(_ url: URL) -> Bool {
        guard let workspace = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return false
        }
        let selDefault = NSSelectorFromString("defaultWorkspace")
        guard workspace.responds(to: selDefault),
              let ws = workspace.perform(selDefault)?.takeUnretainedValue() as? NSObject
        else { return false }
        let sel = NSSelectorFromString("openSensitiveURL:withOptions:")
        guard ws.responds(to: sel) else { return false }
        _ = ws.perform(sel, with: url, with: nil)
        return true
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

    /// 兼容旧调用：武装后样板式直跳巨魔。
    @discardableResult
    static func openInstall(manifest: Manifest, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard trollInstallURL(tipaHttpsURL: manifest.url) != nil else {
            completion?(false)
            return false
        }
        let ver = manifest.version
        let tipaURL = manifest.url
        DispatchQueue.global(qos: .userInitiated).async {
            HelperLauncher.armPostUpdate(expectVersion: ver)
            openTrollStoreInstall(tipaHttpsURL: tipaURL, completion: completion)
        }
        return true
    }
}
