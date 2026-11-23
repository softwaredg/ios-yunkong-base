import UIKit

/// Shared dark “instrument desk” chrome for tipa screens.
enum BaseChrome {
    static let bg = UIColor(red: 0.06, green: 0.07, blue: 0.08, alpha: 1)
    static let surface = UIColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
    static let surfaceRaised = UIColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1)
    static let hairline = UIColor(white: 1, alpha: 0.08)
    static let textPrimary = UIColor(white: 0.96, alpha: 1)
    static let textSecondary = UIColor(white: 0.62, alpha: 1)
    static let textMuted = UIColor(white: 0.42, alpha: 1)
    /// One accent — live / go.
    static let accent = UIColor(red: 0.22, green: 0.78, blue: 0.58, alpha: 1)
    static let accentInk = UIColor(red: 0.04, green: 0.14, blue: 0.10, alpha: 1)
    static let warn = UIColor(red: 0.92, green: 0.62, blue: 0.22, alpha: 1)
    static let danger = UIColor(red: 0.86, green: 0.32, blue: 0.28, alpha: 1)
    /// 2×2 action chips — distinct but quiet.
    static let actionUpdate = UIColor(red: 0.27, green: 0.48, blue: 0.90, alpha: 1)
    static let actionLog = UIColor(red: 0.40, green: 0.46, blue: 0.58, alpha: 1)
    static let actionTest = UIColor(red: 0.16, green: 0.62, blue: 0.64, alpha: 1)

    static func card() -> UIView {
        let v = UIView()
        v.backgroundColor = surface
        v.layer.cornerRadius = 14
        v.layer.cornerCurve = .continuous
        v.layer.borderWidth = 1 / UIScreen.main.scale
        v.layer.borderColor = hairline.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    static func sectionLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = textMuted
        return l
    }

    // iOS 14: classic title/background/inset (no iOS15 button config API).
    private static func styleButton(
        _ button: UIButton,
        title: String,
        titleColor: UIColor,
        background: UIColor?,
        font: UIFont,
        insets: UIEdgeInsets,
        border: Bool = false
    ) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(titleColor, for: .normal)
        button.titleLabel?.font = font
        button.backgroundColor = background
        button.contentEdgeInsets = insets
        button.layer.cornerRadius = 10
        button.layer.cornerCurve = .continuous
        button.clipsToBounds = true
        if border {
            button.layer.borderWidth = 1
            button.layer.borderColor = hairline.cgColor
        } else {
            button.layer.borderWidth = 0
            button.layer.borderColor = nil
        }
    }

    static func applyFilled(_ button: UIButton, title: String, color: UIColor = accent, ink: UIColor = accentInk) {
        styleButton(
            button,
            title: title,
            titleColor: ink,
            background: color,
            font: .systemFont(ofSize: 17, weight: .semibold),
            insets: UIEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        )
    }

    static func applyBordered(_ button: UIButton, title: String) {
        styleButton(
            button,
            title: title,
            titleColor: textPrimary,
            background: surfaceRaised,
            font: .systemFont(ofSize: 15, weight: .semibold),
            insets: UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14),
            border: true
        )
    }

    /// Colored chip for the 2×2 action grid (white label on solid tint).
    static func applyAction(_ button: UIButton, title: String, color: UIColor) {
        styleButton(
            button,
            title: title,
            titleColor: .white,
            background: color,
            font: .systemFont(ofSize: 15, weight: .semibold),
            insets: UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        )
    }

    static func applyPlain(_ button: UIButton, title: String, color: UIColor = textSecondary) {
        styleButton(
            button,
            title: title,
            titleColor: color,
            background: nil,
            font: .systemFont(ofSize: 15, weight: .medium),
            insets: UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        )
    }

    static func kvRow(title: String, value: String) -> UIStackView {
        let t = UILabel()
        t.text = title
        t.font = .systemFont(ofSize: 14, weight: .regular)
        t.textColor = textSecondary
        t.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let v = UILabel()
        v.text = value
        v.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        v.textColor = textPrimary
        v.textAlignment = .right
        v.numberOfLines = 2
        v.lineBreakMode = .byTruncatingMiddle

        let row = UIStackView(arrangedSubviews: [t, v])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        row.distribution = .fill
        return row
    }

    static func statusRow(title: String, value: String, on: Bool) -> UIView {
        let t = UILabel()
        t.text = title
        t.font = .systemFont(ofSize: 14, weight: .regular)
        t.textColor = textSecondary

        let pill = UILabel()
        pill.text = "  \(value)  "
        pill.font = .systemFont(ofSize: 12, weight: .semibold)
        pill.textColor = on ? accentInk : textPrimary
        pill.backgroundColor = on ? accent.withAlphaComponent(0.92) : surfaceRaised
        pill.layer.cornerRadius = 8
        pill.layer.cornerCurve = .continuous
        pill.clipsToBounds = true
        pill.textAlignment = .center
        pill.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [t, UIView(), pill])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        return row
    }

    static func meterRow(title: String, value: String, fraction: Double) -> UIView {
        let t = UILabel()
        t.text = title
        t.font = .systemFont(ofSize: 14, weight: .regular)
        t.textColor = textSecondary

        let pct = UILabel()
        pct.text = "\(Int((fraction * 100).rounded()))%"
        pct.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        pct.textColor = textPrimary
        pct.setContentHuggingPriority(.required, for: .horizontal)

        let head = UIStackView(arrangedSubviews: [t, UIView(), pct])
        head.axis = .horizontal
        head.alignment = .center

        let track = UIView()
        track.backgroundColor = UIColor(white: 1, alpha: 0.08)
        track.layer.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false
        track.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let fill = UIView()
        fill.backgroundColor = meterColor(fraction)
        fill.layer.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        let fillW = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(0.02, min(1, fraction)))
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillW,
        ])

        let detail = UILabel()
        detail.text = value
        detail.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detail.textColor = textMuted
        detail.numberOfLines = 1

        let col = UIStackView(arrangedSubviews: [head, track, detail])
        col.axis = .vertical
        col.spacing = 8
        col.alignment = .fill
        return col
    }

    private static func meterColor(_ fraction: Double) -> UIColor {
        if fraction >= 0.9 { return danger }
        if fraction >= 0.75 { return warn }
        return accent
    }

    static func divider() -> UIView {
        let line = UIView()
        line.backgroundColor = hairline
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return line
    }
}
