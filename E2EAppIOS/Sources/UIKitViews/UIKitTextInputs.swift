import SwiftUI
import UIKit

// テキスト入力画面は **UIKit の UITextField / UITextView** を使う(SwiftUI TextField ではない)。
// 狙いは型語彙のカバレッジ: SwiftUI の TextField と UIKit の生 UITextField は
// アクセシビリティツリー上の見え方(型・value・placeholder の出方)が異なるため、
// ftester の type/valueIs をネイティブ資産に近い形で検証できる。

struct UIKitTextField: UIViewRepresentable {
    let tag: String
    let placeholder: String
    var isSecure: Bool = false
    @Binding var text: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.accessibilityIdentifier = tag
        field.placeholder = placeholder
        field.isSecureTextEntry = isSecure
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        // ASCII 直接入力を前提にする(IME を介す type は契約外。ui-contract.md §全体規約)。
        field.keyboardType = .asciiCapable
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.text = $text
        if uiView.text != text { uiView.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        @objc func changed(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}

struct UIKitTextView: UIViewRepresentable {
    let tag: String
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.accessibilityIdentifier = tag
        view.font = .preferredFont(forTextStyle: .body)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.keyboardType = .asciiCapable
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.separator.cgColor
        view.layer.cornerRadius = 6
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.text = $text
        if uiView.text != text { uiView.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text ?? ""
        }
    }
}
