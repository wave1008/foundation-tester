// 再生中に呼ばれる FM フック群(画面検証・occlusion-guard。各セクションは下記 MARK 参照)。
//
// **セッションに `model:` を渡さない**(省略 = オンデバイス固定。PCC は禁止。FTCore/FMGate.swift 冒頭)。

import CoreGraphics
import Foundation
import FoundationModels
import FTCore
import ImageIO

// MARK: - @Generable 型

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

    public func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? {
        // Attachment(画像入力)は macOS 27+。26 では判定不能(nil)= screenMatches は skip。
        // 通常は StepExecutor が FMVisionSupport で手前で止めるので、ここは保険
        guard #available(macOS 27, *) else { return nil }
        guard let cgImage = Self.cgImage(fromPNG: screenshotPNG) else { return nil }
        // FM はホスト全体で直列化される資源(FMLock 参照)
        guard await FMGate.enter() else { return nil }
        defer { FMGate.leave() }
        let session = LanguageModelSession(instructions: """
        You verify screens for UI tests. Look at the screenshot and judge strictly
        whether it matches the expected state.
        """)
        let screenStartedAt = Date()
        do {
            let verdict = try await session.respond(
                generating: ScreenVerdict.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 200)
            ) {
                "Expected screen state: \(expected)\nDecide whether the screenshot below matches this state."
                Attachment(cgImage)
            }.content
            FMHealth.record(kind: "screenLooksLike", path: .vision, ms: OcclusionVerifier.elapsedMs(screenStartedAt), ok: true)
            return (verdict.pass, String(verdict.reason.prefix(200)))
        } catch {
            FMHealth.record(kind: "screenLooksLike", path: .vision, ms: OcclusionVerifier.elapsedMs(screenStartedAt),
                            ok: false, error: "screenLooksLike: \(FMHealth.describe(error))")
            return nil
        }
    }

    // MARK: Occlusion guard(PoC)

    /// FTCore(`StepExecutor.occlusionFlip`)がスクショを撮る前に呼ぶ。**生成は伴わない**ので
    /// FMGate は通さない(枠を消費しない)が、**死んでいる FM を暖め続けない**ようブレーカは見る。
    /// 効き方と置き場の理由は OcclusionPrewarm.swift の冒頭
    public func prewarmVisibilityCheck() {
        guard OcclusionVerifier.prewarmEnabled(environment: ProcessInfo.processInfo.environment),
              !FMBreaker.isOpen else { return }
        OcclusionPrewarm.prewarm(instructions: OcclusionVerifier.instructions)
    }

    public func verifyElementVisible(expectedText: String, frame: FTRect, screen: FTRect,
                                     screenshotPNG: Data) async
        -> (visible: Bool, state: String, reason: String, observedText: String)? {
        guard let r = await OcclusionVerifier().verifyCropped(
            expectedText: expectedText, frame: frame, screen: screen, screenshotPNG: screenshotPNG)
        else { return nil }
        return (r.visible, r.state, r.reason, r.observedText)
    }

    // MARK: - Helpers

    static func cgImage(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
