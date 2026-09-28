import SwiftUI

struct InputsScreen: View {
    private enum Field: Hashable { case first, second }

    @State private var number = ""
    @State private var password = ""
    @State private var multiline = ""
    @State private var first = ""
    @State private var second = ""
    // 契約は初期値を明記しないため、他画面の "none" 規約に合わせて補完。
    @State private var focusEcho = "focus=none"
    @State private var auto = ""
    @State private var autoResult = "auto=none"
    @State private var bottom = ""
    @FocusState private var focusedField: Field?

    private let countries = ["Japan", "Jamaica", "Jordan"]

    private var filteredCountries: [String] {
        guard !auto.isEmpty else { return [] }
        return countries.filter { $0.hasPrefix(auto) }
    }

    var body: some View {
        ScreenColumn {
            TextField("数量", text: $number)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(Tags.fieldNumber)
            TaggedText(tag: Tags.txtNumberEcho, text: "number=\(number)")

            SecureField("パスワード", text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(Tags.fieldPassword)
            TaggedText(tag: Tags.txtPasswordEcho, text: "password_len=\(password.count)")

            TextField("メモ", text: $multiline, axis: .vertical)
                .lineLimit(3...)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(Tags.fieldMultiline)
            TaggedText(tag: Tags.txtMultilineEcho, text: "lines=\(multiline.isEmpty ? 0 : multiline.components(separatedBy: "\n").count)")

            TextField("姓", text: $first)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.next)
                .focused($focusedField, equals: .first)
                .accessibilityIdentifier(Tags.fieldFirst)
                .onSubmit { focusedField = .second }
            TextField("名", text: $second)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .second)
                .accessibilityIdentifier(Tags.fieldSecond)
            TaggedText(tag: Tags.txtFocusEcho, text: focusEcho)

            VStack(alignment: .leading, spacing: 4) {
                TextField("国", text: $auto)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(Tags.fieldAuto)
                ForEach(filteredCountries, id: \.self) { country in
                    Button(country) {
                        auto = country
                        autoResult = "auto=\(country)"
                    }
                    .accessibilityIdentifier(Tags.autoOpt(country))
                }
            }
            TaggedText(tag: Tags.txtAutoEcho, text: autoResult)

            Spacer(minLength: 40)
            TextField("下の欄", text: $bottom)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(Tags.fieldBottom)
            TaggedText(tag: Tags.txtBottomEcho, text: "bottom=\(bottom)")
        }
        .screenTitleTag("入力の種類")
        .onChange(of: focusedField) { newValue in
            if newValue == .second { focusEcho = "focus=second" }
        }
    }
}
