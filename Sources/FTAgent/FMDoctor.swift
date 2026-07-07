// FMDoctor.swift
// Foundation Models の可用性診断。`ftester doctor` から使用する。

import Foundation
import FoundationModels

public enum FMDoctor {

    public struct Report {
        public let available: Bool
        public let detail: String
    }

    public static func check() -> Report {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return Report(available: true, detail: "オンデバイスモデル: 利用可能")
        case .unavailable(let reason):
            return Report(available: false, detail: "オンデバイスモデル: 利用不可 (\(describe(reason)))")
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
