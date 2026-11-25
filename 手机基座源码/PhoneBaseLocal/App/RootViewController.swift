import UIKit

final class RootViewController: UIViewController {
    private let gateway: ServiceGateway
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    private let heroCard = BaseChrome.card()
    private let statusDot = UIView()
    private let statusTitle = UILabel()
    private let statusDetail = UILabel()
    private let connectCaption = UILabel()
    private let connectValue = UILabel()

    private let toggleButton = UIButton(type: .system)
    private let updateButton = UIButton(type: .system)
    private let runLogButton = UIButton(type: .system)
    private let selfTestButton = UIButton(type: .system)

    private let updateHint = UILabel()
    private let deviceCard = BaseChrome.card()
    private let deviceStack = UIStackView()
    private var pendingManifest: TipaSelfUpdate.Manifest?
    private var didAutoCheckUpdate = false
    private var statusPoll: Timer?

    init(gateway: ServiceGateway) {
        self.gateway = gateway
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BaseChrome.bg

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.layer.cornerRadius = 5
        statusDot.backgroundColor = BaseChrome.textMuted

        statusTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        statusTitle.textColor = BaseChrome.textPrimary

        statusDetail.font = .systemFont(ofSize: 14, weight: .regular)
        statusDetail.textColor = BaseChrome.textSecondary
        statusDetail.numberOfLines = 0

        connectCaption.text = "电脑添加地址"
        connectCaption.font = .systemFont(ofSize: 12, weight: .semibold)
        connectCaption.textColor = BaseChrome.textMuted

        connectValue.font = .monospacedSystemFont(ofSize: 20, weight: .medium)
        connectValue.textColor = BaseChrome.textPrimary
        connectValue.numberOfLines = 2
        connectValue.adjustsFontSizeToFitWidth = true
        connectValue.minimumScaleFactor = 0.7

        BaseChrome.applyFilled(toggleButton, title: gateway.isRunning ? "停止服务" : "启动服务")
        toggleButton.addTarget(self, action: #selector(toggle), for: .touchUpInside)

        BaseChrome.applyAction(updateButton, title: "检查更新", color: BaseChrome.actionUpdate)
        updateButton.addTarget(self, action: #selector(onUpdateButton), for: .touchUpInside)

        BaseChrome.applyAction(runLogButton, title: "运行日志", color: BaseChrome.actionLog)
        runLogButton.addTarget(self, action: #selector(openRunLog), for: .touchUpInside)

        BaseChrome.applyAction(selfTestButton, title: "本机自检", color: BaseChrome.actionTest)
        selfTestButton.addTarget(self, action: #selector(onSelfTestTap), for: .touchUpInside)

        updateHint.font = .systemFont(ofSize: 12, weight: .regular)
        updateHint.textColor = BaseChrome.textMuted
        updateHint.numberOfLines = 0
        updateHint.textAlignment = .center
        updateHint.text = "当前版本 \(TipaSelfUpdate.localVersion)"

        deviceStack.axis = .vertical
        deviceStack.spacing = 10
        deviceStack.translatesAutoresizingMaskIntoConstraints = false

        buildLayout()
        wireGateway()
        refreshIP()
        refreshDeviceInfo()
        refreshHero()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAppActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        statusPoll = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.gateway.refreshStatus { [weak self] in
                self?.refreshHero()
                self?.refreshDeviceInfo(light: true)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.runSelfTest(silent: true)
        }
    }

    deinit {
        statusPoll?.invalidate()
    }

    @objc private func onSelfTestTap() {
        runSelfTest(silent: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshDeviceInfo()
        if !didAutoCheckUpdate {
            didAutoCheckUpdate = true
            checkUpdate(silent: true)
        }
    }

    private func buildLayout() {
        let statusRow = UIStackView(arrangedSubviews: [statusDot, statusTitle])
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 10
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        statusTitle.textAlignment = .center
        statusDetail.textAlignment = .center
        connectCaption.textAlignment = .center
        connectValue.textAlignment = .center

        let heroInner = UIStackView(arrangedSubviews: [
            statusRow, statusDetail, connectCaption, connectValue, updateHint,
        ])
        heroInner.axis = .vertical
        heroInner.spacing = 8
        heroInner.alignment = .center
        heroInner.setCustomSpacing(16, after: statusDetail)
        heroInner.setCustomSpacing(4, after: connectCaption)
        heroInner.setCustomSpacing(14, after: connectValue)
        statusDetail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        connectValue.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updateHint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heroInner.translatesAutoresizingMaskIntoConstraints = false
        heroCard.addSubview(heroInner)

        let actionsTop = UIStackView(arrangedSubviews: [toggleButton, updateButton])
        actionsTop.axis = .horizontal
        actionsTop.spacing = 10
        actionsTop.distribution = .fillEqually

        let actionsBottom = UIStackView(arrangedSubviews: [runLogButton, selfTestButton])
        actionsBottom.axis = .horizontal
        actionsBottom.spacing = 10
        actionsBottom.distribution = .fillEqually

        let actions = UIStackView(arrangedSubviews: [actionsTop, actionsBottom])
        actions.axis = .vertical
        actions.spacing = 10
        actions.distribution = .fillEqually

        let deviceTitle = BaseChrome.sectionLabel("设备")
        deviceCard.addSubview(deviceStack)

        let root = UIStackView(arrangedSubviews: [
            heroCard,
            actions,
            deviceTitle,
            deviceCard,
        ])
        root.axis = .vertical
        root.spacing = 16
        root.alignment = .fill
        root.setCustomSpacing(20, after: heroCard)
        root.setCustomSpacing(24, after: actions)
        root.setCustomSpacing(8, after: deviceTitle)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

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

            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -32),

            heroInner.topAnchor.constraint(equalTo: heroCard.topAnchor, constant: 18),
            heroInner.leadingAnchor.constraint(equalTo: heroCard.leadingAnchor, constant: 18),
            heroInner.trailingAnchor.constraint(equalTo: heroCard.trailingAnchor, constant: -18),
            heroInner.bottomAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: -18),
            statusDetail.widthAnchor.constraint(equalTo: heroInner.widthAnchor),
            connectCaption.widthAnchor.constraint(equalTo: heroInner.widthAnchor),
            connectValue.widthAnchor.constraint(equalTo: heroInner.widthAnchor),
            updateHint.widthAnchor.constraint(equalTo: heroInner.widthAnchor),

            deviceStack.topAnchor.constraint(equalTo: deviceCard.topAnchor, constant: 14),
            deviceStack.leadingAnchor.constraint(equalTo: deviceCard.leadingAnchor, constant: 16),
            deviceStack.trailingAnchor.constraint(equalTo: deviceCard.trailingAnchor, constant: -16),
            deviceStack.bottomAnchor.constraint(equalTo: deviceCard.bottomAnchor, constant: -14),

            toggleButton.heightAnchor.constraint(equalToConstant: 48),
            updateButton.heightAnchor.constraint(equalTo: toggleButton.heightAnchor),
            runLogButton.heightAnchor.constraint(equalTo: toggleButton.heightAnchor),
            selfTestButton.heightAnchor.constraint(equalTo: toggleButton.heightAnchor),
        ])
    }

    private func wireGateway() {
        gateway.onStatus = { [weak self] text in
            DispatchQueue.main.async {
                self?.statusDetail.text = text
                self?.refreshHero()
                self?.refreshDeviceInfo(light: true)
            }
        }
        gateway.refreshStatus { [weak self] in
            self?.refreshHero()
        }
    }

    @objc private func onAppActive() {
        refreshIP()
        gateway.refreshStatus { [weak self] in
            self?.refreshDeviceInfo()
            self?.refreshHero()
        }
    }

    @objc private func openRunLog() {
        let vc = RunLogViewController()
        let nav = UINavigationController(rootViewController: vc)
        nav.navigationBar.prefersLargeTitles = false
        nav.modalPresentationStyle = .fullScreen
        nav.modalTransitionStyle = .coverVertical
        present(nav, animated: true)
    }

    private func refreshHero() {
        let running = gateway.isRunning
        statusDot.backgroundColor = running ? BaseChrome.accent : BaseChrome.textMuted
        statusTitle.text = running ? "运行中" : "已停止"
        BaseChrome.applyFilled(
            toggleButton,
            title: running ? "停止服务" : "启动服务",
            color: running ? BaseChrome.danger : BaseChrome.accent,
            ink: running ? .white : BaseChrome.accentInk
        )
        if statusDetail.text?.isEmpty != false {
            statusDetail.text = running ? "电脑可连接本机投屏" : "点「启动服务」后电脑可连接"
        }
    }

    private func refreshDeviceInfo(light: Bool = false) {
        _ = light
        let rows = DeviceStatusInfo.rows(runtimeRunning: gateway.isRunning)
        deviceStack.arrangedSubviews.forEach {
            deviceStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        deviceStack.spacing = 12
        for (i, r) in rows.enumerated() {
            switch r.kind {
            case .status:
                deviceStack.addArrangedSubview(
                    BaseChrome.statusRow(title: r.title, value: r.value, on: r.statusOn)
                )
            case .meter:
                deviceStack.addArrangedSubview(
                    BaseChrome.meterRow(title: r.title, value: r.value, fraction: r.fraction)
                )
            case .plain:
                deviceStack.addArrangedSubview(BaseChrome.kvRow(title: r.title, value: r.value))
            }
            if i < rows.count - 1 {
                deviceStack.addArrangedSubview(BaseChrome.divider())
            }
        }
    }

    @objc private func onUpdateButton() {
        if let m = pendingManifest {
            let guide = TipaInstallGuideViewController(manifest: m)
            guide.modalPresentationStyle = .fullScreen
            present(guide, animated: true)
            updateHint.text = "正在打开巨魔安装 \(m.version)…"
            return
        }
        checkUpdate(silent: false)
    }

    private func checkUpdate(silent: Bool) {
        if !silent {
            updateButton.isEnabled = false
            updateHint.text = "正在检查更新…"
            AppRunLog.shared.append("开始检查更新")
        }
        TipaSelfUpdate.check { [weak self] result in
            guard let self else { return }
            self.updateButton.isEnabled = true
            switch result {
            case let .upToDate(local, remote):
                self.pendingManifest = nil
                BaseChrome.applyAction(self.updateButton, title: "检查更新", color: BaseChrome.actionUpdate)
                self.updateHint.text = "已是最新 · 本机 \(local) · 线上 \(remote)"
                AppRunLog.shared.append("已是最新 local=\(local) remote=\(remote)")
            case let .available(local, manifest):
                self.pendingManifest = manifest
                BaseChrome.applyAction(
                    self.updateButton,
                    title: "去安装 \(manifest.version)",
                    color: BaseChrome.warn
                )
                var text = "有新版 \(manifest.version)（本机 \(local)）"
                if !manifest.notes.isEmpty { text += "\n\(manifest.notes)" }
                text += "\n点上方按钮用巨魔安装"
                self.updateHint.text = text
                AppRunLog.shared.append("发现新版 \(manifest.version)（本机 \(local)）")
            case let .failed(msg):
                if silent {
                    self.updateHint.text = "当前版本 \(TipaSelfUpdate.localVersion)\n检查失败：\(msg)"
                } else {
                    self.updateHint.text = "检查失败：\(msg)\n可稍后重试"
                }
                AppRunLog.shared.append("检查更新失败：\(msg)")
            }
        }
    }

    private func refreshIP() {
        let ips = LanAddress.ipv4List()
        let first = ips.first ?? ""
        if first.isEmpty {
            connectValue.text = "等待 Wi‑Fi 地址…"
            connectValue.textColor = BaseChrome.textMuted
        } else {
            connectValue.text = "\(first):\(gateway.port)"
            connectValue.textColor = BaseChrome.textPrimary
        }
    }

    @objc private func toggle() {
        if gateway.isRunning {
            gateway.stop()
            refreshIP()
            refreshDeviceInfo()
            refreshHero()
            // 停止也在后台；多刷几次状态
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.gateway.refreshStatus {
                    self?.refreshDeviceInfo()
                    self?.refreshHero()
                }
            }
        } else {
            statusDetail.text = "正在启动服务…"
            _ = gateway.start()
            // Helper 探活可能数秒，回退主进程也要等；分次刷新
            for delay in [1.5, 4.0, 9.0, 14.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.refreshIP()
                    self?.gateway.refreshStatus {
                        self?.refreshDeviceInfo()
                        self?.refreshHero()
                    }
                }
            }
        }
    }

    private func runSelfTest(silent: Bool) {
        selfTestButton.isEnabled = false
        let port = gateway.port
        let lan = LanAddress.ipv4List().first
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.gateway.refreshStatus()
            let oursRunning = self?.gateway.isRunning ?? false
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
                    "自检\n127.0.0.1 → \(local)\nLAN → \(lanResult)\(warn)"
                AppRunLog.shared.append(summary)
                if !silent {
                    self?.statusDetail.text = warn.isEmpty
                        ? "自检完成，详情见运行日志"
                        : "自检发现问题，详情见运行日志"
                }
                self?.selfTestButton.isEnabled = true
                self?.gateway.refreshStatus {
                    self?.refreshHero()
                }
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
            return "\n\n11019 被其它 PhoneBase/Direct 占用\n请到 TrollStore 卸载 Direct / 旧基座后重开"
        }
        if !oursRunning, lower.contains("http 200") {
            return "\n\n11019 被 Direct 助手占用\n请到 TrollStore 卸载 Direct 后重开本应用"
        }
        return ""
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
