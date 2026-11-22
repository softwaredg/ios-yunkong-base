import UIKit

final class RootViewController: UIViewController {
    private let runtime: BaseRuntime
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let ipLabel = UILabel()
    private let selfTestLabel = UILabel()
    private let updateLabel = UILabel()
    private let deviceInfoLabel = UILabel()
    private let toggleButton = UIButton(type: .system)
    private let freePortButton = UIButton(type: .system)
    private let selfTestButton = UIButton(type: .system)
    private let updateButton = UIButton(type: .system)
    private let runLogButton = UIButton(type: .system)
    private var pendingManifest: TipaSelfUpdate.Manifest?
    private var didAutoCheckUpdate = false

    init(runtime: BaseRuntime) {
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.11, alpha: 1)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        titleLabel.text = "本地基座"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .white

        statusLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        statusLabel.textColor = UIColor(white: 0.75, alpha: 1)
        statusLabel.numberOfLines = 0

        ipLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        ipLabel.textColor = UIColor(white: 0.55, alpha: 1)
        ipLabel.numberOfLines = 0

        selfTestLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        selfTestLabel.textColor = UIColor(red: 0.85, green: 0.75, blue: 0.35, alpha: 1)
        selfTestLabel.numberOfLines = 0
        selfTestLabel.text = "若启动失败 bind(48)：向下滑，点「释放端口占用」"

        // 按钮放上面，避免被超长自检日志顶出屏幕
        freePortButton.setTitle("释放端口占用", for: .normal)
        stylePrimary(freePortButton, color: UIColor(red: 0.85, green: 0.45, blue: 0.15, alpha: 1))
        freePortButton.addTarget(self, action: #selector(freePort), for: .touchUpInside)

        toggleButton.setTitle(runtime.isRunning ? "停止服务" : "启动服务", for: .normal)
        stylePrimary(toggleButton, color: UIColor(red: 0.18, green: 0.62, blue: 0.48, alpha: 1))
        toggleButton.addTarget(self, action: #selector(toggle), for: .touchUpInside)

        selfTestButton.setTitle("本机自检", for: .normal)
        stylePrimary(selfTestButton, color: UIColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 1))
        selfTestButton.addTarget(self, action: #selector(runSelfTest), for: .touchUpInside)

        updateButton.setTitle("检查更新", for: .normal)
        stylePrimary(updateButton, color: UIColor(red: 0.45, green: 0.35, blue: 0.85, alpha: 1))
        updateButton.addTarget(self, action: #selector(onUpdateButton), for: .touchUpInside)

        updateLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        updateLabel.textColor = UIColor(white: 0.65, alpha: 1)
        updateLabel.numberOfLines = 0
        updateLabel.text = "当前版本 \(TipaSelfUpdate.localVersion)"

        runLogButton.setTitle("运行日志", for: .normal)
        stylePrimary(runLogButton, color: UIColor(red: 0.35, green: 0.40, blue: 0.48, alpha: 1))
        runLogButton.addTarget(self, action: #selector(openRunLog), for: .touchUpInside)

        deviceInfoLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        deviceInfoLabel.textColor = UIColor(white: 0.78, alpha: 1)
        deviceInfoLabel.numberOfLines = 0
        deviceInfoLabel.backgroundColor = UIColor(white: 0.12, alpha: 1)
        deviceInfoLabel.layer.cornerRadius = 10
        deviceInfoLabel.clipsToBounds = true
        deviceInfoLabel.textAlignment = .left

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            freePortButton,
            toggleButton,
            selfTestButton,
            updateButton,
            updateLabel,
            runLogButton,
            deviceInfoLabel,
            statusLabel,
            ipLabel,
            selfTestLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40),
        ])

        runtime.onStatus = { [weak self] text in
            DispatchQueue.main.async {
                self?.statusLabel.text = text
                self?.toggleButton.setTitle(self?.runtime.isRunning == true ? "停止服务" : "启动服务", for: .normal)
                // 不在每次状态回调里重扫序列号/磁盘，只刷新运行状态行
                self?.refreshDeviceInfo(light: true)
            }
        }
        refreshIP()
        refreshDeviceInfo()
        // 勿用 3s 主线程轮询：和 CADisplayLink 抢主线程 → 投屏周期性卡一下
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAppActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.runSelfTest()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshDeviceInfo()
        if !didAutoCheckUpdate {
            didAutoCheckUpdate = true
            checkUpdate(silent: true)
        }
    }

    @objc private func onAppActive() {
        refreshIP()
        refreshDeviceInfo()
    }

    @objc private func openRunLog() {
        let vc = RunLogViewController()
        let nav = UINavigationController(rootViewController: vc)
        nav.navigationBar.prefersLargeTitles = false
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    private func refreshDeviceInfo(light: Bool = false) {
        // light：连接状态频繁回调时仍走同一快照（型号/序列号已缓存，存储/内存轻量）
        _ = light
        let rows = DeviceStatusInfo.rows(runtimeRunning: runtime.isRunning)
        var lines: [String] = ["设备信息"]
        for r in rows {
            let mark = r.title == "运行状态" && runtime.isRunning ? "● " : "  "
            lines.append("\(mark)\(r.title)：\(r.value)")
        }
        // 左右内边距用空格近似（UILabel 无 contentInset）
        deviceInfoLabel.text = "\n  " + lines.joined(separator: "\n  ") + "\n"
    }

    @objc private func onUpdateButton() {
        if let m = pendingManifest {
            _ = TipaSelfUpdate.openInstall(manifest: m)
            updateLabel.text = "已打开巨魔安装 \(m.version)\n装完回到本应用即可"
            AppRunLog.shared.append("打开巨魔安装 \(m.version)")
            return
        }
        checkUpdate(silent: false)
    }

    private func checkUpdate(silent: Bool) {
        if !silent {
            updateButton.isEnabled = false
            updateLabel.text = "正在检查更新…"
            AppRunLog.shared.append("开始检查更新")
        }
        TipaSelfUpdate.check { [weak self] result in
            guard let self else { return }
            self.updateButton.isEnabled = true
            switch result {
            case let .upToDate(local, remote):
                self.pendingManifest = nil
                self.updateButton.setTitle("检查更新", for: .normal)
                self.updateLabel.text = "已是最新 · 本机 \(local) · 线上 \(remote)"
                AppRunLog.shared.append("已是最新 local=\(local) remote=\(remote)")
            case let .available(local, manifest):
                self.pendingManifest = manifest
                self.updateButton.setTitle("去安装 \(manifest.version)", for: .normal)
                var text = "有新版 \(manifest.version)（本机 \(local)）"
                if !manifest.notes.isEmpty { text += "\n\(manifest.notes)" }
                text += "\n点上方按钮用巨魔安装"
                self.updateLabel.text = text
                AppRunLog.shared.append("发现新版 \(manifest.version)（本机 \(local)）")
            case let .failed(msg):
                if silent {
                    self.updateLabel.text = "当前版本 \(TipaSelfUpdate.localVersion)\n检查失败：\(msg)"
                } else {
                    self.updateLabel.text = "检查失败：\(msg)\n可稍后重试"
                }
                AppRunLog.shared.append("检查更新失败：\(msg)")
            }
        }
    }

    private func stylePrimary(_ button: UIButton, color: UIColor) {
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = color
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
    }

    private func refreshIP() {
        let ips = LanAddress.ipv4List().joined(separator: "\n")
        let tip = ips.isEmpty
            ? "等待局域网地址…\n请确认手机已连 Wi‑Fi（勿用访客网络）"
            : "电脑端「手动添加」填：\n\(ips.split(separator: "\n").first ?? "")\n端口 \(runtime.port)"
        ipLabel.text = "端口 \(runtime.port)\n\(ips.isEmpty ? "无局域网 IP" : ips)\n\n\(tip)"
    }

    @objc private func toggle() {
        if runtime.isRunning {
            AppRunLog.shared.append("用户停止服务")
            runtime.stop()
            toggleButton.setTitle("启动服务", for: .normal)
        } else {
            AppRunLog.shared.append("用户启动服务")
            runtime.start()
            toggleButton.setTitle(runtime.isRunning ? "停止服务" : "启动服务", for: .normal)
        }
        refreshIP()
        refreshDeviceInfo()
    }

    @objc private func freePort() {
        freePortButton.isEnabled = false
        statusLabel.text = "正在释放 \(runtime.port) 端口占用…"
        AppRunLog.shared.append("开始释放端口 \(runtime.port)")
        if runtime.isRunning { runtime.stop() }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = PortOccupancy.freePort(self.runtime.port)
            DispatchQueue.main.async {
                var lines: [String] = ["释放端口结果："]
                if !result.occupantHint.isEmpty {
                    lines.append(result.occupantHint)
                }
                if result.killed.isEmpty {
                    lines.append("未杀到冲突进程（可能无权限，请卸载 Direct/旧基座）")
                } else {
                    lines.append("已结束：\(result.killed.joined(separator: ", "))")
                }
                lines.append(contentsOf: result.notes)

                let ok = self.runtime.start(notifyStatus: false)
                self.toggleButton.setTitle(self.runtime.isRunning ? "停止服务" : "启动服务", for: .normal)
                if ok {
                    lines.append("已重新启动本服务 ✓")
                } else {
                    lines.append("启动仍失败：手机上的 Direct(LanCaptureHelper) 占着 11019")
                    lines.append("请到 TrollStore 卸载 Direct / PhoneBaseDirect 后重开本应用")
                }
                let joined = lines.joined(separator: "\n")
                self.statusLabel.text = joined
                AppRunLog.shared.append(joined)
                self.freePortButton.isEnabled = true
                self.refreshIP()
                self.refreshDeviceInfo()
                self.runSelfTest()
            }
        }
    }

    @objc private func runSelfTest() {
        selfTestLabel.text = "自检中…"
        let port = runtime.port
        let lan = LanAddress.ipv4List().first
        let oursRunning = runtime.isRunning
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 只取摘要，避免整段商业基座 JSON 撑爆界面
            let local = Self.fetchSummary("http://127.0.0.1:\(port)/api/health")
            let lanResult: String
            if let lan {
                lanResult = Self.fetchSummary("http://\(lan):\(port)/api/health")
            } else {
                lanResult = "无局域网 IP"
            }
            let warn = Self.conflictHint(localBody: local, oursRunning: oursRunning)
            DispatchQueue.main.async {
                let summary =
                    "本机自检\n127.0.0.1 → \(local)\nLAN → \(lanResult)\n\(warn)\n可向下滑动查看更多"
                self?.selfTestLabel.text = summary
                AppRunLog.shared.append("自检 127.0.0.1 → \(local)；LAN → \(lanResult)")
            }
        }
    }

    private static func conflictHint(localBody: String, oursRunning: Bool) -> String {
        let lower = localBody.lowercased()
        let foreign =
            lower.contains("phone-direct")
            || lower.contains("cloud-wss")
            || lower.contains("dtls-srtp")
            || (lower.contains("foreign") || lower.contains("其它基座"))
            || (lower.contains("\"protocol\"") && !lower.contains("lan-phonebase") && lower.contains("http 200"))
        if foreign || lower.contains("其它基座") {
            return "\n⚠️ 11019 被其它 PhoneBase/Direct 占用\n请点上方「释放端口占用」\n"
        }
        if !oursRunning, lower.contains("http 200") {
            return "\n⚠️ 11019 被 Direct 助手占用（也会回 lan-phonebase）\n先点「释放端口占用」；不行就卸载 Direct\n"
        }
        return "\n"
    }

    private static func fetchSummary(_ url: String) -> String {
        guard let u = URL(string: url) else { return "bad-url" }
        var req = URLRequest(url: u, timeoutInterval: 2.5)
        req.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var out = "timeout"
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err {
                out = "err:\(err.localizedDescription)"
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            out = summarize(code: code, body: body)
        }.resume()
        _ = sem.wait(timeout: .now() + 3)
        return out
    }

    private static func summarize(code: Int, body: String) -> String {
        guard code == 200, let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let short = body.count > 120 ? String(body.prefix(120)) + "…" : body
            return "HTTP \(code) \(short)"
        }
        let proto = String(describing: obj["protocol"] ?? "")
        let publisher = String(describing: obj["publisherType"] ?? "")
        let ok = obj["ok"] as? Bool
        if proto == "lan-phonebase" || (ok == true && publisher.isEmpty) {
            let accept = obj["accept"] ?? "-"
            return "HTTP 200 lan-phonebase accept=\(accept)"
        }
        if !publisher.isEmpty || body.contains("cloud-wss") || body.contains("phone-direct") {
            return "HTTP 200 其它基座 publisher=\(publisher.isEmpty ? "?" : publisher)"
        }
        let short = body.count > 120 ? String(body.prefix(120)) + "…" : body
        return "HTTP \(code) \(short)"
    }
}
