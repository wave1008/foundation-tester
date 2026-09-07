import Photos
import SwiftUI

struct DiagnosticsScreen: View {
    @State private var confirmOpen = false
    @State private var photosResult = "photos=none"

    var body: some View {
        ScreenColumn {
            TaggedText(tag: Tags.txtBuildInfo, text: "build=\(AppInfo.version)")
            TaggedText(tag: Tags.txtDiagNote, text: "診断メニュー")
            // 背景は system の外観設定に関わらず固定(dark mode だと gray220/白地の
            // コントラストが反転し witness が壊れる)。値は Tags.txtOcrFaint のコメント参照
            Text("ocr=readable")
                .font(.system(size: 17))
                .foregroundColor(Color(white: 220.0 / 255.0))
                .frame(width: 160, height: 44)
                .background(Color.white)
                .accessibilityIdentifier(Tags.txtOcrFaint)
            // **OS のアラートが被さる witness**(iOS SUT だけが持つ)。SpringBoard が別プロセスで
            // 出すので in-app の木には載らず、in-app の注入は OS のイベント経路を通らないため
            // 「人手では不可能な操作」が通ってしまう形の対照になる。
            // 何度でも出せる: xcrun simctl privacy <udid> reset photos com.ftester.e2e.ios
            TaggedText(tag: Tags.txtPhotosResult, text: photosResult)
            TaggedButton(tag: Tags.btnRequestPhotos, label: "写真へのアクセスを要求") {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    DispatchQueue.main.async { photosResult = "photos=\(Self.name(status))" }
                }
            }
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

    private static func name(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }
}
