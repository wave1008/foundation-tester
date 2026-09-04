import SwiftUI
import UIKit

/// **キーボードぶん縮まないスクロール容器**(UIKit の素の UIScrollView)。
///
/// SwiftUI の ScrollView はキーボードが立つと容器そのものを縮めるので、その下の入力欄は
/// 「容器の外」になり、既存の復帰(容器外の再解決)が働いてしまう。受け手の実アプリ
/// (Compose)で起きたのは**容器の中だが覆われている**形で、そこでは既存の復帰は働かない。
/// witness にはその形が要るため、縮まない容器をここで用意する。
struct KeyboardCoverScroll: UIViewRepresentable {
    /// 下の欄の下端を容器の下端からどれだけ上に置くか。**キーボードの内側に必ず入る値**
    /// (実測の最小キーボードは 375x667 で 233pt なので、40pt は十分内側)
    static let underFieldBottomInset: CGFloat = 40

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
        // **下の欄は容器の下端から測って置く**(行数で決めない)。行数で決めると、画面の高さが
        // 変わったときに「キーボードより上」へ出たり容器からはみ出したりして、覆われている
        // という witness の前提そのものが崩れる(2026-09-05: 375x667 で上の欄が消えた回の同型)。
        // 下端から 40pt = どの端末でもキーボードの内側(最小のキーボードでも 233pt ある)
        let filler = UIView()
        stack.addArrangedSubview(filler)

        stack.addArrangedSubview(context.coordinator.makeField(
            tag: Tags.fieldUnderKeyboard, placeholder: "下の欄", isAbove: false))
        // 送る余地(これが無ければ送っても外れない)
        let spacer = UIView()
        // **送る余地**。容器(約700pt)に対して 220pt では足りず、1回送った時点で末尾に
        // 着いて対象がキーボードの内側に残った(2026-08-27 実測)
        spacer.heightAnchor.constraint(equalToConstant: 500).isActive = true
        stack.addArrangedSubview(spacer)

        scroll.addSubview(stack)
        // **frameLayoutGuide を参照する制約は階層へ入れたあとで張る**。先に活性化すると
        // 共通の祖先がまだ無く `NSLayoutConstraint` が例外を投げてアプリごと落ちる
        // (2026-09-05 に実際に落とした。SIGABRT / CoreAutoLayout _setActive)
        let fillerHeight = filler.heightAnchor.constraint(
            equalTo: scroll.frameLayoutGuide.heightAnchor,
            constant: -(Self.underFieldBottomInset + 104 + 52 * CGFloat(rowCount)))
        fillerHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            fillerHeight,
            // 容器が極端に低いときでも潰れるだけで壊れない
            filler.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
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
