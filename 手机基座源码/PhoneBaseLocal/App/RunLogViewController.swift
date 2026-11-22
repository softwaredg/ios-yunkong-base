import UIKit

final class RunLogViewController: UIViewController {
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.11, alpha: 1)
        title = "运行日志"
        // 深色页：导航栏白字，避免系统默认黑字看不清
        navigationController?.navigationBar.barStyle = .black
        navigationController?.navigationBar.tintColor = .white
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: UIColor.white]
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
        textView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        textView.textColor = UIColor(white: 0.9, alpha: 1)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        let text = AppRunLog.shared.snapshot()
        textView.text = text.isEmpty ? "（暂无日志）" : text
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
        navigationItem.prompt = "已复制到剪贴板"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.navigationItem.prompt = nil
        }
    }

    @objc private func clearLog() {
        AppRunLog.shared.clear()
        reload()
    }
}
