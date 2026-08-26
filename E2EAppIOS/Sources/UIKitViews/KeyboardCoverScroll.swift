import SwiftUI
import UIKit

/// **キーボードぶん縮まないスクロール容器**(UIKit の素の UIScrollView)。
///
/// SwiftUI の ScrollView はキーボードが立つと容器そのものを縮めるので、その下の入力欄は
/// 「容器の外」になり、既存の復帰(容器外の再解決)が働いてしまう。受け手の実アプリ
/// (Compose)で起きたのは**容器の中だが覆われている**形で、そこでは既存の復帰は働かない。
/// witness にはその形が要るため、縮まない容器をここで用意する。
struct KeyboardCoverScroll: UIViewRepresentable {
    @Binding var above: String
    @Binding var under: String
    let rowCount: Int

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.keyboardDismissMode = .none
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(context.coordinator.makeField(
            tag: Tags.fieldAboveKeyboard, placeholder: "上の欄", isAbove: true))
        for n in 1...rowCount {
            let label = UILabel()
            label.text = "行 \(n)"
            label.textAlignment = .center
            label.heightAnchor.constraint(equalToConstant: 44).isActive = true
            stack.addArrangedSubview(label)
        }
        stack.addArrangedSubview(context.coordinator.makeField(
            tag: Tags.fieldUnderKeyboard, placeholder: "下の欄", isAbove: false))
        // 送る余地(これが無ければ送っても外れない)
        let spacer = UIView()
        // **送る余地**。容器(約700pt)に対して 220pt では足りず、1回送った時点で末尾に
        // 着いて対象がキーボードの内側に残った(2026-08-27 実測)
        spacer.heightAnchor.constraint(equalToConstant: 500).isActive = true
        stack.addArrangedSubview(spacer)

        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.above = $above
        context.coordinator.under = $under
    }

    func makeCoordinator() -> Coordinator { Coordinator(above: $above, under: $under) }

    final class Coordinator: NSObject {
        var above: Binding<String>
        var under: Binding<String>

        init(above: Binding<String>, under: Binding<String>) {
            self.above = above
            self.under = under
        }

        func makeField(tag: String, placeholder: String, isAbove: Bool) -> UITextField {
            let field = UITextField()
            field.accessibilityIdentifier = tag
            field.placeholder = placeholder
            field.borderStyle = .roundedRect
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            // 契約 §全体規約: ASCII 直接入力を前提にする(IME を介す type は契約外)
            field.keyboardType = .asciiCapable
            field.heightAnchor.constraint(equalToConstant: 44).isActive = true
            field.addTarget(self, action: isAbove ? #selector(changedAbove(_:)) : #selector(changedUnder(_:)),
                            for: .editingChanged)
            return field
        }

        @objc func changedAbove(_ sender: UITextField) { above.wrappedValue = sender.text ?? "" }
        @objc func changedUnder(_ sender: UITextField) { under.wrappedValue = sender.text ?? "" }
    }
}
