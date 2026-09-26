// 見るのは `SystemLanguageModel`(オンデバイス)だけ。**PCC の可否を足さない** ——
// 禁止しているものの状態を報告すると「使える」と読まれ、型名がソースに入ると門が落ちる
// (禁止の理由と門は FTCore/FMGate.swift 冒頭)。

import Foundation
import FoundationModels
import FTCore

public enum FMDoctor {

    public struct Report {
        public let available: Bool
        public let detail: String
    }

    /// availability だけを見る安価な同期ゲート。ホットパス(シナリオ毎の前提確認・
    /// LazyFMDelegate の初期化判定)専用で、**これは「本当に呼べるか」を保証しない**。
    /// 可否を人へ報告する場所では checkLive() を使うこと。
    public static func check() -> Report {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return Report(available: true, detail: "On-device model: available")
        case .unavailable(let reason):
            return Report(available: false, detail: "On-device model: unavailable (\(describe(reason)))")
        }
    }

    /// 実際に1回推論して可否を判定する。availability は「端末が対応しているか」しか見ておらず、
    /// モデル資産側の理由で全呼び出しが失敗していても .available を返す(実測:
    /// availability=available / isAvailable=true のまま ModelManagerError 1001 で全滅した)。
    /// availability を信じて緑を出すと、occlusion-guard が黙って無効なまま「正常」と報告される。
    ///
    /// **実呼び出しは FMLivenessProbe に委ねる** —— ここで直接呼ぶと、doctor で確かめた事実が
    /// 機械グローバルな台帳(FMLiveness)に残らず、モニターも run の開始前警告も同じことを
    /// もう一度払うことになる(判定と観測の置き場を1つにする)
    public static func checkLive() async -> Report {
        let base = check()
        guard base.available else { return base }
        let verdict = await FMLivenessProbe.probeOnce(path: .text)
        guard verdict.state == .dead else {
            return Report(available: true, detail: "On-device model: available (confirmed by a live call)")
        }
        return Report(
            available: false,
            detail: "On-device model: a live call failed"
                + " (availability reports available — check the model assets and the state of Apple Intelligence)"
                // 入れ子を畳んでから出す。LanguageModelError の最上位は常に
                // `Code=-1 "The operation couldn't be completed."` で、真因は入れ子の中にしかない
                + "\n   Error: \(verdict.error ?? "unknown")")
    }

    /// 画像入力(vision)経路を**実際に1回呼んで**確かめる。`visionReport` は OS の能力しか
    /// 見ておらず、**text と vision は独立に死ぬ**(実測)ので、能力があることは可否を意味しない。
    /// 対応 OS でないときは visionReport をそのまま返す(それは死ではなく能力の話)
    public static func visionCheckLive() async -> Report {
        guard FMVisionSupport.isSupported else { return visionReport }
        let verdict = await FMLivenessProbe.probeOnce(path: .vision)
        guard verdict.state == .dead else {
            return Report(available: true,
                          detail: "FM visual verification (image input): available"
                              + " (confirmed by a live call)")
        }
        return Report(
            available: false,
            detail: "FM visual verification (image input): a live call failed."
                + " occlusion-guard (the default requireVisible of exist) and screenLooksLike are"
                + " disabled — scenario drafting and naming keep working (they are text-only)"
                + "\n   Error: \(verdict.error ?? "unknown")")
    }

    /// 画像入力(Attachment)の可否。FM 本体が使えても macOS 26 では視覚系
    /// (occlusion-guard / screenLooksLike)だけが無効になるため、テキスト系とは別に報告する。
    public static var visionReport: Report {
        FMVisionSupport.isSupported
            ? Report(available: true, detail: "FM visual verification (image input): available")
            : Report(available: false,
                     detail: "FM visual verification (image input): unavailable (\(FMVisionSupport.requirement))"
                         + ". screenLooksLike is disabled, and the occlusion-guard (text visual verification)"
                         + " judges from on-device OCR alone — text OCR cannot judge passes unchecked"
                         + " (scenario drafting and naming keep working — they are text-only)")
    }

    /// FM 本体が使えないときに**何が止まり、代わりに何を書くか**。
    /// 「unavailable」だけでは、シナリオの書き方をどう変えればよいか分からない
    /// (外部フィードバック)。visionReport が視覚系について同じことをしている。
    public static let unavailableImpact =
        "Disabled: screenLooksLike and FM-based scenario drafting and naming. The occlusion-guard"
        + " (the requireVisible check of exist) judges from on-device OCR alone — text OCR cannot judge"
        + " passes unchecked. Everything deterministic keeps working (self-healing"
        + " by locator fingerprint does not use FM) — write textIs / valueIs / exist assertions instead"
        + " of screenLooksLike."

    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "this device is not eligible"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off — enable it in System Settings"
        case .modelNotReady:
            return "the model is still downloading — wait a moment and retry"
        @unknown default:
            return "unknown reason: \(reason)"
        }
    }
}
