// InAppTapProbe.swift
// POST /tapprobe: iOS の hideKeyboard が叩く点が、**木に載らないもの**の上でないか(ホストは
// StepExecutor.executeIOSHideKeyboard)。背景かどうか(押せる部品が無いか)はホストがアクセシビリティの木で決める(ユーザー決定)。
// ここで答えるのは木では見えない3つだけで、どれかに当たれば「叩かない」:
//   - キーボード
//   - ステータスバー(叩くとスクロール容器が先頭へ戻る)
//   - キーウィンドウ以外のウィンドウが前面にある(トースト等の重ね。叩くと消える・操作が起きる)
// 認識器やタッチの上書きは見ない —— Compose・Flutter・RN・SwiftUI は画面全体を1つの面が受けて中で振り分けるので、
// OS の層では背景と押せる部品を区別できない(見ると全部「反応しうる」になる)。
// 契約(DTO)は Sources/FTCore/BridgeDTO.swift の TapProbeRequest / TapProbeResponse。

import UIKit

extension FTInAppBridge {

    func handleTapProbe(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(TapProbeRequest.self, body)
        let answer: TapProbeResponse = mainSync {
            let point = CGPoint(x: req.x, y: req.y)
            if let keyboard = Self.keyboardFrameIfVisible(), keyboard.contains(point) {
                return TapProbeResponse(background: false, receiver: nil, reason: "the point is on the keyboard")
            }
            if Self.statusBarFrames().contains(where: { $0.contains(point) }) {
                return TapProbeResponse(background: false, receiver: nil,
                                        reason: "the point is on the status bar (a tap there scrolls to the top)")
            }
            guard let (hit, window) = Self.topmostHitView(at: point) else {
                return TapProbeResponse(background: false, receiver: nil, reason: "no view in the app receives a touch there")
            }
            if !window.isKeyWindow {
                return TapProbeResponse(background: false, receiver: String(describing: type(of: window)),
                                        reason: "another window is in front there (a toast or another overlay)")
            }
            return TapProbeResponse(background: true, receiver: String(describing: type(of: hit)), reason: nil)
        }
        return .json(answer)
    }

    /// 前面のシーンのステータスバーの枠(スクリーン座標)
    private static func statusBarFrames() -> [CGRect] {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.statusBarManager?.statusBarFrame }
            .filter { !$0.isEmpty }
    }
}
