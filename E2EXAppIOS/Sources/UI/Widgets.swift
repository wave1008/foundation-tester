import SwiftUI

// 全画面で共有する最小ウィジェット。シグネチャ変更は全画面に波及する。

struct TaggedButton: View {
    let tag: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).frame(minHeight: 44)
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

/// 画面本体の共通コンテナ(縦スクロール)。
struct ScreenColumn<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }
}

extension View {
    /// 契約: `#txt_screen_title` は画面見出し文字列。iOS のシステム戻るボタンは
    /// 前画面の navigationTitle をラベルに使うため、両方をこの1箇所で揃えておく
    /// (docs/ui-contract.md §シェル)。
    func screenTitleTag(_ title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title).accessibilityIdentifier(Tags.screenTitle)
                }
            }
    }
}
