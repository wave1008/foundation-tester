import SwiftUI

struct HomeScreen: View {
    let onNavigate: (Screen) -> Void

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.homeMarker, text: "E2E ホーム")
            TaggedButton(tag: Tags.navSelector, label: "セレクタ", fillWidth: true) { onNavigate(.selector) }
            TaggedButton(tag: Tags.navInput, label: "テキスト入力", fillWidth: true) { onNavigate(.input) }
            TaggedButton(tag: Tags.navGesture, label: "ジェスチャ", fillWidth: true) { onNavigate(.gesture) }
            TaggedButton(tag: Tags.navScroll, label: "スクロール", fillWidth: true) { onNavigate(.scroll) }
            TaggedButton(tag: Tags.navAsync, label: "非同期表示", fillWidth: true) { onNavigate(.async) }
            TaggedButton(tag: Tags.navDialog, label: "ダイアログ", fillWidth: true) { onNavigate(.dialog) }
            TaggedButton(tag: Tags.navLifecycle, label: "ライフサイクル", fillWidth: true) { onNavigate(.lifecycle) }
            TaggedButton(tag: Tags.navHeal, label: "自己修復", fillWidth: true) { onNavigate(.heal) }
            TaggedButton(tag: Tags.navDiagnostics, label: "診断", fillWidth: true) { onNavigate(.diagnostics) }
        }
    }
}

struct AboutScreen: View {
    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtAboutMarker, text: "E2E について")
            TaggedText(tag: Tags.txtAboutApp, text: "app=\(AppInfo.appID)")
            TaggedText(tag: Tags.txtAboutVersion, text: "version=\(AppInfo.version)")
        }
    }
}
