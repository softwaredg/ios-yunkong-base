import UIKit

final class RunLogViewController: UIViewController {
    private let textView = UITextView()
    private var copyItem: UIBarButtonItem?

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
        let copy = UIBarButtonItem(title: "复制", style: .plain, target: self, action: #selector(copyLog))
        copyItem = copy
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "清空", style: .plain, target: self, action: #selector(clearLog)),
            copy,
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
            let end = NSRange(location: max(0, (textView.text as NSString).length - 1), length: 0)
            textView.scrollRangeToVisible(end)
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func copyLog() {
        let text = AppRunLog.shared.snapshot()
        guard !text.isEmpty else {
            flashCopyTitle("无内容")
            return
        }
        // 只用 string；再 setItems 在部分系统上会把剪贴板写空
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        flashCopyTitle("已复制")
        let tip = UIAlertController(
            title: nil,
            message: "已复制 \(text.count) 字到剪贴板",
            preferredStyle: .alert
        )
        present(tip, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self, weak tip] in
            tip?.dismiss(animated: true)
            // 防止快速连点叠多个 alert
            _ = self
        }
    }

    private func flashCopyTitle(_ title: String) {
        copyItem?.title = title
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyItem?.title = "复制"
        }
    }

    @objc private func clearLog() {
        AppRunLog.shared.clear()
        reload()
    }
}
