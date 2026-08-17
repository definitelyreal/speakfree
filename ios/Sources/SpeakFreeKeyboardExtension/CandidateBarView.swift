// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import UIKit

final class CandidateBarView: UIView {
    var onSelect: ((Int) -> Void)?

    private let stack = UIStackView()
    private let statusLabel = UILabel()
    private var buttons: [UIButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = KeyboardPalette.background
        accessibilityIdentifier = "candidateBar"

        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.72
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        let bottomBorder = UIView()
        bottomBorder.backgroundColor = KeyboardPalette.separator
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBorder)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: topAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        for index in 0..<4 {
            let button = UIButton(type: .system)
            button.tag = index
            button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
            button.setTitleColor(.label, for: .normal)
            button.backgroundColor = .clear
            button.addTarget(self, action: #selector(selectCandidate(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = "candidate\(index)"
            buttons.append(button)
            stack.addArrangedSubview(button)

            if index > 0 {
                let separator = UIView()
                separator.backgroundColor = KeyboardPalette.separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(separator)
                NSLayoutConstraint.activate([
                    separator.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                    separator.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                    separator.widthAnchor.constraint(equalToConstant: 0.5),
                    separator.heightAnchor.constraint(equalTo: button.heightAnchor, multiplier: 0.52),
                ])
            }
        }
        setCandidates([])
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCandidates(_ candidates: [String]) {
        let hasCandidates = !candidates.isEmpty
        stack.isHidden = !hasCandidates
        statusLabel.isHidden = hasCandidates
        statusLabel.text = "SpeakFree"
        for (index, button) in buttons.enumerated() {
            let title = candidates.indices.contains(index) ? candidates[index] : ""
            button.setTitle(title, for: .normal)
            button.isEnabled = !title.isEmpty
            button.accessibilityValue = title
        }
    }

    func setStatus(_ status: String) {
        stack.isHidden = true
        statusLabel.isHidden = false
        statusLabel.text = status.isEmpty ? "SpeakFree" : status
        statusLabel.accessibilityValue = statusLabel.text
        for button in buttons {
            button.setTitle("", for: .normal)
            button.isEnabled = false
            button.accessibilityValue = ""
        }
    }

    @objc private func selectCandidate(_ sender: UIButton) { onSelect?(sender.tag) }
}
