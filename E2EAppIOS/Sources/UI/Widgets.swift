import SwiftUI

// 全画面で共有する最小ウィジェット。シグネチャ変更は全画面に波及する。

struct TaggedButton: View {
    let tag: String
    let label: String
    var fillWidth: Bool = false
    /// false でも a11y ツリーには残す(消すと isDisabled が「見つかりません」になる)
    var enabled: Bool = true
    /// **縦に詰める**。要素の多い画面が**最小サポート画面(375x667)で1画面に収まらない**と、
    /// 上端の結果表示と下端のボタンを同時に木へ載せられず、そこを対にした検証が
    /// 「小さい画面でだけ落ちる」形になる(2026-09-05 実測: セレクタ画面の
    /// `#txt_selector_result` と `#btn_selector_reset`)。**通常の高さを変えない**のは、
    /// 縁の帯・折り返しの witness が今の寸法で成立しているため
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .frame(maxWidth: fillWidth ? .infinity : nil, minHeight: compact ? 24 : 48)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!enabled)
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
