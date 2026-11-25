import UIKit

/// 武装 Helper → 样板式 apple-magnifier 直跳巨魔（不弹「打开方式」）。
final class TipaInstallGuideViewController: UIViewController {
    private let manifest: TipaSelfUpdate.Manifest
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let statusLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var didAutoStart = false
    /// 用户点「稍后」后置位，丢弃在途 arm / 打开回调，避免标记被写回
    private var cancelled = false

    init(manifest: TipaSelfUpdate.Manifest) {
        self.manifest = manifest
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BaseChrome.bg

        titleLabel.text = "安装基座 \(manifest.version)"
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = BaseChrome.textPrimary
        titleLabel.textAlignment = .center

        detailLabel.text = manifest.notes.isEmpty
            ? "将自动跳转巨魔（TrollStore）安装。\n装完后 Helper 会尝试自动打开本应用；若没有请点桌面图标。"
            : "\(manifest.notes)\n\n将自动跳转巨魔安装。装完会尝试自动打开。"
        detailLabel.font = .systemFont(ofSize: 15, weight: .regular)
        detailLabel.textColor = BaseChrome.textSecondary
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        statusLabel.text = "准备跳转…"
        statusLabel.font = .systemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = BaseChrome.textMuted
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        BaseChrome.applyFilled(openButton, title: "打开巨魔安装", color: BaseChrome.warn, ink: UIColor(red: 0.18, green: 0.10, blue: 0.02, alpha: 1))
        openButton.addTarget(self, action: #selector(startInstall), for: .touchUpInside)

        BaseChrome.applyBordered(closeButton, title: "稍后")
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let card = BaseChrome.card()
        let inner = UIStackView(arrangedSubviews: [titleLabel, detailLabel, statusLabel])
        inner.axis = .vertical
        inner.spacing = 12
        inner.alignment = .fill
        inner.setCustomSpacing(16, after: titleLabel)
        inner.setCustomSpacing(20, after: detailLabel)
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)

        let stack = UIStackView(arrangedSubviews: [card, openButton, closeButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),

            openButton.heightAnchor.constraint(equalToConstant: 50),
            closeButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didAutoStart {
            didAutoStart = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.cancelled else { return }
                self.startInstall()
            }
        }
    }

    @objc private func startInstall() {
        guard !cancelled else { return }
        openButton.isEnabled = false
        statusLabel.text = "正在武装 Helper 并跳转巨魔…"
        let version = manifest.version
        let tipaURL = manifest.url
        // arm / spawn 可能干等数秒，必须离开主线程
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.cancelled else { return }
            HelperLauncher.armPostUpdate(expectVersion: version)
            if self.cancelled {
                UpdateMarker.clear()
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled else {
                    UpdateMarker.clear()
                    return
                }
                self.statusLabel.text = "正在打开巨魔…"
                TipaSelfUpdate.openTrollStoreInstall(tipaHttpsURL: tipaURL) { [weak self] ok in
                    DispatchQueue.main.async {
                        guard let self, !self.cancelled else { return }
                        self.openButton.isEnabled = true
                        BaseChrome.applyFilled(
                            self.openButton,
                            title: "再次打开巨魔",
                            color: BaseChrome.warn,
                            ink: UIColor(red: 0.18, green: 0.10, blue: 0.02, alpha: 1)
                        )
                        if ok {
                            self.statusLabel.text = "已跳转巨魔。点「安装」后将尝试自动打开；若没有请点桌面图标。"
                        } else {
                            self.statusLabel.text = "无法打开巨魔。请打开 TrollStore → 设置 → 打开 URL Scheme，再点「再次打开巨魔」。"
                        }
                    }
                }
            }
        }
    }

    @objc private func close() {
        cancelled = true
        // 用户放弃安装：清掉装后标记，避免之后普通退出被 Helper 强行拉回
        UpdateMarker.clear()
        dismiss(animated: true)
    }
}
