import Foundation
import UIKit

/// 手机端自检 tipa 更新：拉公开清单，比版本，跳转巨魔安装。
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

    /// 段式数字比较，与 agent `cmpVer` 一致：a>b → 正，a<b → 负。
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
        // 对齐 JS encodeURIComponent：整段 tipa https URL 作为 query 值
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
            guard
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
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

    @discardableResult
    static func openInstall(manifest: Manifest, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard let u = trollInstallURL(tipaHttpsURL: manifest.url) else {
            completion?(false)
            return false
        }
        // 巨魔装完不会自己回跳；武装看门狗在覆盖杀进程后延迟拉起
        ProcessWatchdog.prepareForSelfUpdate(expectVersion: manifest.version)
        UIApplication.shared.open(u, options: [:]) { ok in
            DispatchQueue.main.async { completion?(ok) }
        }
        return true
    }
}
