// RetentionPolicy.swift
// ログ・録画・レポート・デバイス由来の添付の保持容量。
//
// **既定値の定義元はこの型だけ**(他所へ散らさない。CLI も拡張も `fleetest api retention` が
// 返す実効値を読む)。欄を足したら `effective…` アクセサと `defaults` の出力も揃える ——
// 片方だけだと「設定したのに黙って効かない」形になる。
//
// 値の意味は**そのカテゴリ全体で保持してよい上限バイト数**で、run 単位でも日単位でもない。
// 新しい順に積んで上限を超えたところから消える(規則は RetentionSweep)。

import Foundation

public struct RetentionPolicy: Codable, Sendable, Equatable {
    /// シミュレータの testmanagerd 添付(Attachments/)の上限。nil = 既定
    public var deviceCapturesMaxBytes: Int64?
    /// results/runs/<月>/<runID>/recordings/ の上限。nil = 既定
    public var recordingsMaxBytes: Int64?
    /// TestProjects/<project>/reports/ の .md と .png の上限。nil = 既定
    public var reportsMaxBytes: Int64?
    /// <repoRoot>/.fleetest/*.log の上限。nil = 既定
    public var logsMaxBytes: Int64?
    /// run の完了時に自動で掃除するか。nil = 既定
    public var sweepAfterRun: Bool?

    public init(deviceCapturesMaxBytes: Int64? = nil,
                recordingsMaxBytes: Int64? = nil,
                reportsMaxBytes: Int64? = nil,
                logsMaxBytes: Int64? = nil,
                sweepAfterRun: Bool? = nil) {
        self.deviceCapturesMaxBytes = deviceCapturesMaxBytes
        self.recordingsMaxBytes = recordingsMaxBytes
        self.reportsMaxBytes = reportsMaxBytes
        self.logsMaxBytes = logsMaxBytes
        self.sweepAfterRun = sweepAfterRun
    }

    /// 全欄が未設定か(`api retention --import` が既定へ戻したとき、LocalConfig から欄ごと消すため)
    public var isEmpty: Bool {
        deviceCapturesMaxBytes == nil && recordingsMaxBytes == nil && reportsMaxBytes == nil
            && logsMaxBytes == nil && sweepAfterRun == nil
    }

    // MARK: - 既定値(単位: バイト。1 GiB = 1_073_741_824 / 1 MiB = 1_048_576)

    /// 20 GiB。XCUITest の添付は1シナリオごとに積まれ、放っておくと際限なく育つ
    /// (この Mac で 870 GB まで育った実測がこの機構の発端)。20 GiB は**フル E2E 数周ぶん**が
    /// 残る量 —— 事後の切り分けに要るのは直近の run の添付だけなので、これ以上は保持しない。
    /// 尽きたら**古い run の添付から**消える(進行中のブリッジのぶんは消さない)
    public static let defaultDeviceCapturesMaxBytes: Int64 = 20 * 1_073_741_824

    /// 100 GiB。1クリップ数十 MB × シナリオ本数で、フル E2E 1周が数 GB。**10周ぶん**残る量。
    /// 尽きたら古い run から run 単位で消える(結果 JSON は消さないので run 自体は残る)
    public static let defaultRecordingsMaxBytes: Int64 = 100 * 1_073_741_824

    /// 1000 MiB。レポートは Markdown + 失敗時のスクリーンショット PNG で、1 run 数十 MB。
    /// 尽きたら古い run のぶんから消える
    public static let defaultReportsMaxBytes: Int64 = 1000 * 1_048_576

    /// 500 MiB。ブリッジ1本のログが長い run で数十 MB になる。
    /// 尽きたら古いログファイルから消える(生きているブリッジのログは消さない)
    public static let defaultLogsMaxBytes: Int64 = 500 * 1_048_576

    /// 既定で run の完了時に掃除する。**掃除は run の壁時計に乗る**ので、時間予算
    /// (`RetentionSweeper.defaultBudgetSeconds`)で頭を抑える
    public static let defaultSweepAfterRun = true

    // MARK: - 実効値

    public var effectiveDeviceCapturesMaxBytes: Int64 {
        Self.effective(deviceCapturesMaxBytes, default: Self.defaultDeviceCapturesMaxBytes)
    }
    public var effectiveRecordingsMaxBytes: Int64 {
        Self.effective(recordingsMaxBytes, default: Self.defaultRecordingsMaxBytes)
    }
    public var effectiveReportsMaxBytes: Int64 {
        Self.effective(reportsMaxBytes, default: Self.defaultReportsMaxBytes)
    }
    public var effectiveLogsMaxBytes: Int64 {
        Self.effective(logsMaxBytes, default: Self.defaultLogsMaxBytes)
    }
    public var effectiveSweepAfterRun: Bool { sweepAfterRun ?? Self.defaultSweepAfterRun }

    /// 実効値に nil は無い。**0 と負を混ぜない** —— 0 は「保持しない」という有効な指定で、
    /// 負だけが無効(既定へ倒す)
    static func effective(_ value: Int64?, default fallback: Int64) -> Int64 {
        guard let value, value >= 0 else { return fallback }
        return value
    }

    /// nil を既定で埋めた姿(`api retention` の `policy` 欄。拡張はこれを表示する)
    public var resolved: RetentionPolicy {
        RetentionPolicy(deviceCapturesMaxBytes: effectiveDeviceCapturesMaxBytes,
                        recordingsMaxBytes: effectiveRecordingsMaxBytes,
                        reportsMaxBytes: effectiveReportsMaxBytes,
                        logsMaxBytes: effectiveLogsMaxBytes,
                        sweepAfterRun: effectiveSweepAfterRun)
    }

    /// 全欄が既定の姿(`api retention` の `defaults` 欄)
    public static let defaults = RetentionPolicy().resolved
}
