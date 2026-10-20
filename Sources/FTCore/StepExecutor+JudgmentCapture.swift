// 画像判定の絵を撮る唯一の口(撮り分けの判定は FTCore.JudgmentCapture)。
// 使う側: テキストの可視性検証(guardScreenshot)・findImage / existImage / imageIs・分類器・screenLooksLike / screenIs。
// **使わない側**: 打鍵の読み返しと linkText の OCR(入った文字・位置を読むのが目的で、覆いの有無を問わない)・
// 描画崩壊の判定(アプリ自身の描画を見る)・凍結フレームの基準(Android だけ)。

import Foundation

extension StepExecutor {

    /// 画像判定の絵。keyboardShown は判定に使う木の `KeyboardWait.isShown`。
    /// 呼び手が撮影を計時するなら、照会の時間を二重に数えないよう `judgmentUsesWholeScreen` → `judgmentCapture` に分けて呼ぶ
    func judgmentScreenshot(keyboardShown: Bool, alwaysWholeScreen: Bool = false,
                            phase: inout PhaseAccumulator) async throws -> Data {
        let wholeScreen = await judgmentUsesWholeScreen(keyboardShown: keyboardShown,
                                                        alwaysWholeScreen: alwaysWholeScreen, phase: &phase)
        return try await judgmentCapture(wholeScreen: wholeScreen).data
    }

    /// 画面全体の絵で撮るか。フェーズでまだ聞いていなければ、ここで1回だけ SpringBoard に聞く
    func judgmentUsesWholeScreen(keyboardShown: Bool, alwaysWholeScreen: Bool,
                                 phase: inout PhaseAccumulator) async -> Bool {
        var source = JudgmentCapture.source(
            primaryOmitsSystemUI: primaryCaptureOmitsSystemUI, hasWholeScreen: fallbackDriver != nil,
            alwaysWholeScreen: alwaysWholeScreen, keyboardShown: keyboardShown, alertCovering: judgmentAlertCovering)
        if source == .probeSystemAlert, let fb = fallbackDriver {
            let probe = await probeSystemAlert(fb, phase: &phase)
            // 照会が落ちたら「無い」とは言えないが、毎回聞き直すと判定のたびに往復を払う。
            // 落ちた事実は probeSystemAlert が注記に残すので、このフェーズは主ドライバの絵に倒す
            let covered = SystemUIGate.isCovered(probe)
            judgmentAlertCovering = covered
            if covered { noteCodesThisStep.insert(.systemAlertPresent) }
            source = covered ? .wholeScreen : .primary
        }
        return source == .wholeScreen
    }

    /// 画面全体の絵が撮れなければ主ドライバへ落ちる(`FTDriveCore.performScreenshot` と同じ順)。
    /// 戻り値の wholeScreen は実際に撮れた側
    func judgmentCapture(wholeScreen: Bool) async throws -> (data: Data, wholeScreen: Bool) {
        if wholeScreen, let fb = fallbackDriver, let shot = try? await fb.screenshot() {
            return (shot, true)
        }
        return (try await driver.screenshot(), false)
    }
}
