import Foundation
import FoundationModels

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
                    + "\n   エラー: \(String("\(error)".prefix(300)))")
        }
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
