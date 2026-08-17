// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import UIKit

final class CandidateBarView: UIStackView {
    var onSelect: ((Int) -> Void)?
    private var buttons: [UIButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .horizontal
        distribution = .fillEqually
        alignment = .fill
        spacing = 1
        backgroundColor = .separator
        accessibilityIdentifier = "candidateBar"
        for index in 0..<4 {
            let button = UIButton(type: .system)
            button.tag = index
            button.titleLabel?.font = .systemFont(ofSize: 16)
            button.backgroundColor = .secondarySystemBackground
            button.addTarget(self, action: #selector(selectCandidate(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = "candidate\(index)"
            buttons.append(button)
            addArrangedSubview(button)
        }
        setCandidates([])
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCandidates(_ candidates: [String]) {
        for (index, button) in buttons.enumerated() {
            let title = candidates.indices.contains(index) ? candidates[index] : ""
            button.setTitle(title, for: .normal)
            button.isEnabled = !title.isEmpty
            button.accessibilityValue = title
        }
    }

    func setStatus(_ status: String) {
        for (index, button) in buttons.enumerated() {
            let title = index == 0 ? status : ""
            button.setTitle(title, for: .normal)
            button.isEnabled = false
            button.accessibilityValue = title
        }
    }

    @objc private func selectCandidate(_ sender: UIButton) { onSelect?(sender.tag) }
}
