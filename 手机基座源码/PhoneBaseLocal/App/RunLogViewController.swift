import UIKit

final class RunLogViewController: UIViewController {
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BaseChrome.bg
        title = "运行日志"

        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = BaseChrome.surface
        appearance.titleTextAttributes = [
            .foregroundColor: BaseChrome.textPrimary,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
        ]
        appearance.shadowColor = BaseChrome.hairline
        navigationController?.navigationBar.standardAppearance = appearance
        navigationController?.navigationBar.scrollEdgeAppearance = appearance
        navigationController?.navigationBar.compactAppearance = appearance
        navigationController?.navigationBar.tintColor = BaseChrome.accent
        navigationController?.navigationBar.isTranslucent = false
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "关闭",
            style: .plain,
            target: self,
            action: #selector(close)
        )
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "清空", style: .plain, target: self, action: #selector(clearLog)),
            UIBarButtonItem(title: "复制", style: .plain, target: self, action: #selector(copyLog)),
        ]

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = BaseChrome.surface
        textView.textColor = BaseChrome.textPrimary
        textView.tintColor = BaseChrome.accent
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        textView.layer.cornerRadius = 12
        textView.layer.cornerCurve = .continuous
        textView.clipsToBounds = true
        textView.alwaysBounceVertical = true
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        let text = AppRunLog.shared.snapshot()
        textView.text = text.isEmpty ? "暂无日志" : text
        if !text.isEmpty {
            let end = NSRange(location: max(0, textView.text.count - 1), length: 0)
            textView.scrollRangeToVisible(end)
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func copyLog() {
        UIPasteboard.general.string = AppRunLog.shared.snapshot()
        navigationItem.prompt = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.navigationItem.prompt = nil
        }
    }

    @objc private func clearLog() {
        AppRunLog.shared.clear()
        reload()
    }
}
