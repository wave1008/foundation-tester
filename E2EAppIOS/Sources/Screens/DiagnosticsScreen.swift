import SwiftUI

struct DiagnosticsScreen: View {
    @State private var confirmOpen = false

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtBuildInfo, text: "build=\(AppInfo.version)")
            TaggedText(tag: Tags.txtDiagNote, text: "診断メニュー")
            TaggedButton(tag: Tags.btnFreeze3s, label: "3秒フリーズ") {
                // ブリッジのタイムアウト挙動検証用にメインスレッドを 3 秒ブロックする。
                Thread.sleep(forTimeInterval: 3)
            }
            TaggedButton(tag: Tags.btnCrash, label: "クラッシュさせる") { confirmOpen = true }
        }
        .alert("クラッシュ確認", isPresented: $confirmOpen) {
            // 押すと即プロセス異常終了する。クラッシュレポート添付・ブリッジ切断の検証専用。
            Button("本当にクラッシュ", role: .destructive) {
                fatalError("FT_E2E intentional crash")
            }
            .accessibilityIdentifier(Tags.btnCrashConfirm)
            Button("やめる", role: .cancel) { }
                .accessibilityIdentifier(Tags.btnCrashCancel)
        }
    }
}
