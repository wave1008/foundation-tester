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
            return Report(available: true, detail: "オンデバイスモデル: 利用可能")
        case .unavailable(let reason):
            return Report(available: false, detail: "オンデバイスモデル: 利用不可 (\(describe(reason)))")
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
                to: "OK とだけ答えてください。",
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 8))
            return Report(available: true, detail: "オンデバイスモデル: 利用可能(実呼び出しで確認)")
        } catch {
            return Report(
                available: false,
                detail: "オンデバイスモデル: 実呼び出しに失敗しました"
                    + "(availability は available。モデル資産や Apple Intelligence の状態を確認してください)"
                    // 入れ子を畳んでから出す。LanguageModelError の最上位は常に
                    // `Code=-1 "The operation couldn't be completed."` で、真因は入れ子の中にしかない
                    + "\n   エラー: \(FMHealth.describe(error))")
        }
    }

    /// 画像入力(Attachment)の可否。FM 本体が使えても macOS 26 では視覚系
    /// (occlusion-guard / screenIs)だけが無効になるため、テキスト系とは別に報告する。
    public static var visionReport: Report {
        FMVisionSupport.isSupported
            ? Report(available: true, detail: "FM の視覚検証(画像入力): 利用可能")
            : Report(available: false,
                     detail: "FM の視覚検証(画像入力): 利用不可(\(FMVisionSupport.requirement))"
                         + "。occlusion-guard(偽陽性チェック)と screenIs は無効です"
                         + "(heal・トリアージ・シナリオ命名はテキストのみで動作します)")
    }

    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "このデバイスは対象外です"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence が無効です。システム設定から有効にしてください"
        case .modelNotReady:
            return "モデルのダウンロード中です。しばらく待って再実行してください"
        @unknown default:
            return "不明な理由: \(reason)"
        }
    }
}
