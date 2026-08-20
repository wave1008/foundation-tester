import SwiftUI
import UIKit

/// **別 UIWindow に載るモーダル**(アプリ内メッセージ SDK を模した witness)。
///
/// 受け手報告(2026-08-20): この形のモーダルが出ている間、テストは何も失敗せず**緑のまま**
/// 通っていた。in-app エンジンの木は**キーウィンドウ1枚**しか歩かず、タップは activate、
/// スクロールは contentOffset の直接書き込みで **hitTest を経由しない**ため、
/// 上に乗ったモーダルが障害物にならない。
///
/// **key にしない**のが要点: `UIAlertController` は自分の窓をキーウィンドウにするので今日でも
/// 木に載る。SDK 系のオーバーレイは `isHidden = false` で重ねるだけなので載らない。
/// ここは**載らない側**を再現する。
enum OverlayWindow {
    private static var window: UIWindow?

    /// `after` 秒後に出す(非同期に湧く実物と同じく、操作の途中で現れる形を作る)
    static func show(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { present(banner: false) }
    }

    /// **画面上部だけを覆うバナー**(SDK のもう一つの定番)。
    /// 「手前の窓だけ見せる」方式との判定を分ける witness: この形では**背面は見えていなければ
    /// ならない**(バナーの下のボタンは押せる)。全画面モーダルと同じ扱いにすると、
    /// バナー1枚でアプリ本体が丸ごと木から消える
    static func showBanner(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { present(banner: true) }
    }

    static func hide() {
        window?.isHidden = true
        window = nil
    }

    private static func present(banner: Bool) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else { return }
        let overlay = UIWindow(windowScene: scene)
        overlay.windowLevel = .alert + 1
        overlay.backgroundColor = .clear
        if banner {
            // 上端の帯だけを占める窓(下の画面はそのまま触れる)
            overlay.frame = CGRect(x: 0, y: 0, width: scene.screen.bounds.width, height: 180)
            overlay.rootViewController = UIHostingController(rootView: BannerCard())
        } else {
            overlay.rootViewController = UIHostingController(rootView: OverlayCard())
        }
        overlay.rootViewController?.view.backgroundColor = .clear
        // **makeKeyAndVisible を呼ばない** —— 呼ぶとキーウィンドウになり、今日の実装でも木に載る
        overlay.isHidden = false
        window = overlay
    }
}

private struct BannerCard: View {
    var body: some View {
        VStack(spacing: 8) {
            TaggedText(tag: Tags.txtBannerTitle, text: "お知らせバナー")
            TaggedButton(tag: Tags.btnBannerClose, label: "バナーを閉じる") {
                Prefs.setString("overlay_result", "banner_closed")
                OverlayWindow.hide()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }
}

private struct OverlayCard: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                TaggedText(tag: Tags.txtOverlayTitle, text: "アプリ内メッセージ")
                TaggedButton(tag: Tags.btnOverlayAction, label: "詳細を見る") {
                    Prefs.setString("overlay_result", "action")
                    OverlayWindow.hide()
                }
                TaggedButton(tag: Tags.btnOverlayClose, label: "閉じる") {
                    Prefs.setString("overlay_result", "closed")
                    OverlayWindow.hide()
                }
            }
            .padding(24)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .padding(24)
        }
    }
}
