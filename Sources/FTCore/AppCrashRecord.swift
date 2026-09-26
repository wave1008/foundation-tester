// AppCrashRecord.swift
// アプリのクラッシュ検出(ScenarioRunRecord.appCrash)。検出した箇所からだけ渡す —— 失敗文言の
// 検索や自由文の後解析はしない(docs/results-json.md「アプリのクラッシュ」参照)。
// 検出箇所:
//   iOS(in-app エンジン)= InAppDriver.crashAnnotated / InAppLauncher.crashAnnotated が
//     SimulatorCrashReport.findRecent で見つけた直近の .ips
//   Android = ScenarioRunnerMain の appProcessEvidence 経由で AndroidAppProcessEvidenceQuery が
//     crash バッファの FATAL EXCEPTION を見つけた
// **1 プロセス = 1 シナリオ**(fleetest-scenarios)なので、検出箇所が LastAppCrash.shared へ書き、
// ScenarioRunnerMain が scenarioFinished を送る直前に1回だけ読む(プロセス内シングルトンで足りる。
// 次のシナリオは別プロセスなので値が漏れない)。

import Foundation

/// AppCrashRecord.evidence の値の集合(型から決める。文字列の後解析はしない)
public enum AppCrashEvidence: String, Codable, Sendable {
    /// iOS: SimulatorCrashReport が .ips を見つけた
    case crashReport
    /// Android: crash バッファの FATAL EXCEPTION を見つけた
    case fatalException
}

public struct AppCrashRecord: Codable, Sendable, Equatable {
    public var evidence: String
    /// iOS: 見つかった .ips のパス
    public var path: String?
    /// iOS: クラッシュ理由の1行 / Android: FATAL EXCEPTION ブロックの先頭行
    public var summary: String?

    public init(evidence: AppCrashEvidence, path: String? = nil, summary: String? = nil) {
        self.evidence = evidence.rawValue
        self.path = path
        self.summary = summary
    }
}

/// このプロセス(1 シナリオ)で見つかった最新のクラッシュ証跡を持つ、プロセス内シングルトン。
/// 検出箇所が `record(_:)` で書き、ScenarioRunnerMain が scenarioFinished の直前に
/// `snapshot()` で1回読む
public final class LastAppCrash: @unchecked Sendable {
    public static let shared = LastAppCrash()

    private let lock = NSLock()
    private var value: AppCrashRecord?

    private init() {}

    public func record(_ record: AppCrashRecord) {
        lock.lock()
        value = record
        lock.unlock()
    }

    public func snapshot() -> AppCrashRecord? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
