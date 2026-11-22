import UIKit

/// 点击「去安装」后先展示引导页，再跳转巨魔，避免 open URL 无反馈。
final class TipaInstallGuideViewController: UIViewController {
    private let manifest: TipaSelfUpdate.Manifest
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let statusLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var didAutoOpen = false

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
            ? "将打开巨魔（TrollStore）安装最新 tipa。\n在巨魔里点「安装」，装完再回到本应用。"
            : "\(manifest.notes)\n\n将打开巨魔安装。装完后回到本应用即可。"
        detailLabel.font = .systemFont(ofSize: 15, weight: .regular)
        detailLabel.textColor = BaseChrome.textSecondary
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        statusLabel.text = "准备打开巨魔…"
        statusLabel.font = .systemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = BaseChrome.textMuted
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        BaseChrome.applyFilled(openButton, title: "打开巨魔安装", color: BaseChrome.warn, ink: UIColor(red: 0.18, green: 0.10, blue: 0.02, alpha: 1))
        openButton.addTarget(self, action: #selector(openTroll), for: .touchUpInside)

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
        if !didAutoOpen {
            didAutoOpen = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.openTroll()
            }
        }
    }

    @objc private func openTroll() {
        statusLabel.text = "正在打开巨魔…"
        openButton.isEnabled = false
        guard let url = TipaSelfUpdate.trollInstallURL(tipaHttpsURL: manifest.url) else {
            statusLabel.text = "安装链接无效"
            openButton.isEnabled = true
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] ok in
            DispatchQueue.main.async {
                self?.openButton.isEnabled = true
                if ok {
                    self?.statusLabel.text = "已跳转巨魔。请在巨魔中点「安装」，完成后回到本应用。"
                    AppRunLog.shared.append("打开巨魔安装 \(self?.manifest.version ?? "")")
                } else {
                    self?.statusLabel.text = "无法打开巨魔。请确认已安装 TrollStore，或稍后重试。"
                    AppRunLog.shared.append("打开巨魔失败 \(self?.manifest.version ?? "")")
                }
            }
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
