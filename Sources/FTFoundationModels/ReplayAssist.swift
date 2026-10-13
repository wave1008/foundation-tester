// 再生中に呼ばれる FM フック群(画面検証・occlusion-guard。各セクションは下記 MARK 参照)。
// FM の実呼び出しは常駐プロセス(FMServeServer)が撃つ。ここは要求を送って結果を記録するだけ。

import Foundation
import FoundationModels
import FTCore

// MARK: - @Generable 型(常駐プロセスの screenLooksLike の出力)

@Generable
struct ScreenVerdict {
    @Guide(description: "Whether the screenshot matches the expected state")
    var pass: Bool

    @Guide(description: "Reason for the verdict, in one English sentence; if it does not match, say what differs")
    var reason: String
}

// MARK: - ReplayDelegate 実装

public final class FMReplayDelegate: ReplayDelegate {

    public init() {}

    // MARK: Verifier(マルチモーダル)

    /// 判定は FM の常駐プロセスが撃つ(このプロセスは LanguageModelSession を持たない。FTCore/FMServe.swift 冒頭)。
    /// 記録の規律は `OcclusionVerifier.transcribe` と同じ(FM が答えなかった回だけ失敗・届かなかった回は skip)
    public func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? {
        // Attachment(画像入力)は macOS 27+。26 では判定不能(nil)= screenMatches は skip。
        // 通常は StepExecutor が FMVisionSupport で手前で止めるので、ここは保険
        guard #available(macOS 27, *) else { return nil }
        // FM はホスト全体で共有する資源(FMCallSlots 参照)
        guard await FMCallAdmission.enter(path: .vision) else { return nil }
        defer { FMCallAdmission.leave() }
        guard let client = FMServeClient.fromEnvironment() else {
            FMHealth.recordSkip()
            return nil
        }
        let startedAt = Date()
        let response: FMServeWire.Response
        do {
            response = try await client.send(FMServeWire.Request(kind: .screen, png: screenshotPNG, expected: expected))
        } catch {
            FMHealth.recordSkip()
            return nil
        }
        switch response.status {
        case .ok:
            guard let pass = response.pass else { break }
            FMHealth.record(kind: "screenLooksLike", path: .vision, ms: OcclusionVerifier.elapsedMs(startedAt), ok: true)
            return (pass, response.reason ?? "")
        case .failed:
            FMHealth.record(kind: "screenLooksLike", path: .vision, ms: OcclusionVerifier.elapsedMs(startedAt),
                            ok: false, error: "screenLooksLike: \(response.error ?? "no detail")")
            return nil
        case .refused, .versionMismatch:
            // 拒否は FM の死ではない(FMServeWire.Response.Status.refused)= 答えが無かった回として数える
            break
        }
        FMHealth.recordSkip()
        return nil
    }

    // MARK: Occlusion guard

    public func verifyElementVisible(expectedText: String, frame: FTRect, screen: FTRect,
                                     screenshotPNG: Data) async
        -> (visible: Bool, state: String, reason: String, observedText: String)? {
        guard let r = await OcclusionVerifier().verifyCropped(
            expectedText: expectedText, frame: frame, screen: screen, screenshotPNG: screenshotPNG)
        else { return nil }
        return (r.visible, r.state, r.reason, r.observedText)
    }

}
