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
    /// モデル資産側の理由で全呼び出しが失敗していても .available を返す(実測 2026-07-22:
    /// availability=available / isAvailable=true のまま ModelManagerError 1001 で全滅した)。
    /// availability を信じて緑を出すと、occlusion-guard が黙って無効なまま「正常」と報告される。
    public static func checkLive() async -> Report {
        let base = check()
        guard base.available else { return base }
        do {
            _ = try await LanguageModelSession().respond(
                to: "Answer with just OK.",
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 8))
            return Report(available: true, detail: "On-device model: available (confirmed by a live call)")
        } catch {
            return Report(
                available: false,
                detail: "On-device model: a live call failed"
                    + " (availability reports available — check the model assets and the state of Apple Intelligence)"
                    // 入れ子を畳んでから出す。LanguageModelError の最上位は常に
                    // `Code=-1 "The operation couldn't be completed."` で、真因は入れ子の中にしかない
                    + "\n   Error: \(FMHealth.describe(error))")
        }
    }

    /// 画像入力(Attachment)の可否。FM 本体が使えても macOS 26 では視覚系
    /// (occlusion-guard / screenIs)だけが無効になるため、テキスト系とは別に報告する。
    public static var visionReport: Report {
        FMVisionSupport.isSupported
            ? Report(available: true, detail: "FM visual verification (image input): available")
            : Report(available: false,
                     detail: "FM visual verification (image input): unavailable (\(FMVisionSupport.requirement))"
                         + ". occlusion-guard (false-positive check) and screenIs are disabled"
                         + " (heal, triage and scenario naming keep working — they are text-only)")
    }

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
