import SwiftUI

// 全画面で共有する最小ウィジェット。シグネチャ変更は全画面に波及する。

struct TaggedButton: View {
    let tag: String
    let label: String
    var fillWidth: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .frame(maxWidth: fillWidth ? .infinity : nil, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(tag)
    }
}

struct TaggedText: View {
    let tag: String
    let text: String

    var body: some View {
        Text(text).accessibilityIdentifier(tag)
    }
}

/// 画面本体の共通コンテナ。scrollable=false はソフトキーボード対策(入力画面)。
struct ScreenColumn<Content: View>: View {
    var scrollable: Bool = true
    @ViewBuilder let content: Content

    var body: some View {
        let column = VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        if scrollable {
            ScrollView { column }
        } else {
            VStack(spacing: 0) {
                column
                Spacer(minLength: 0)
            }
        }
    }
}
