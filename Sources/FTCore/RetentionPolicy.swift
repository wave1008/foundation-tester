// RetentionPolicy.swift
// ログ・録画・レポート・デバイス由来の添付・xcresult の保持容量。
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
    /// <repoRoot>/.fleetest/xcresult/ の上限(XCUITest ランナーの結果の束)。nil = 既定
    public var xcresultMaxBytes: Int64?
    /// run の完了後に背景で自動掃除するか(発動は上限の `sweepTriggerPercent`% を超えたときだけ)。nil = 既定
    public var sweepAfterRun: Bool?

    public init(deviceCapturesMaxBytes: Int64? = nil,
                recordingsMaxBytes: Int64? = nil,
                reportsMaxBytes: Int64? = nil,
                logsMaxBytes: Int64? = nil,
                xcresultMaxBytes: Int64? = nil,
                sweepAfterRun: Bool? = nil) {
        self.deviceCapturesMaxBytes = deviceCapturesMaxBytes
        self.recordingsMaxBytes = recordingsMaxBytes
        self.reportsMaxBytes = reportsMaxBytes
        self.logsMaxBytes = logsMaxBytes
        self.xcresultMaxBytes = xcresultMaxBytes
        self.sweepAfterRun = sweepAfterRun
    }

    /// 全欄が未設定か(`api retention --import` が既定へ戻したとき、LocalConfig から欄ごと消すため)
    public var isEmpty: Bool {
        deviceCapturesMaxBytes == nil && recordingsMaxBytes == nil && reportsMaxBytes == nil
            && logsMaxBytes == nil && xcresultMaxBytes == nil && sweepAfterRun == nil
    }

    // MARK: - 既定値(単位: バイト。1 GiB = 1_073_741_824 / 1 MiB = 1_048_576)

    /// 2 GiB。XCUITest の添付は1シナリオごとに積まれ、放っておくと際限なく育つ
    /// (この Mac で 870 GB まで育った実測がこの機構の発端)。ブリッジ起動時に自動記録を止めた
    /// (`BridgeLauncher.captureSettings`)ので新しくは溜まらず、残るのはそれより前に起動した
    /// ブリッジの分だけ(実測 71 MB)。尽きたら**古い run の添付から**消える(進行中のブリッジのぶんは消さない)
    public static let defaultDeviceCapturesMaxBytes: Int64 = 2 * 1_073_741_824

    /// 50 GiB。実測(保守者の Mac・run 1,451 件): 1 run 中央値 4.5 MB / 最大 62 MB、
    /// 1 日平均約 0.35 GB / 最大 0.89 GB(負荷テスト + フル E2E の日)。重い日が続いても約 2 か月残る。
    /// 尽きたら古い run から run 単位で消える(結果 JSON は消さないので run 自体は残る)
    public static let defaultRecordingsMaxBytes: Int64 = 50 * 1_073_741_824

    /// 2000 MiB。レポートは Markdown + 失敗時のスクリーンショット PNG。実測: 負荷テストの日で
    /// 1 日 60〜95 MB(1000 MiB では約 19 日で掃除が始まった)。約 1 か月残る量。
    /// 尽きたら古い日のぶんから消える
    public static let defaultReportsMaxBytes: Int64 = 2000 * 1_048_576

    /// 100 MiB。ブリッジのログはポートごとに1本で起動のたびに作り直すので、量はポート数で頭打ち
    /// (実測: 35 本で 10.3 MB・1 本最大 1.3 MB)。
    /// 尽きたら古いログファイルから消える(生きているブリッジのログは消さない)
    public static let defaultLogsMaxBytes: Int64 = 100 * 1_048_576

    /// 5 GiB。XCUITest ランナーの結果の束(xcresult)。**生きているブリッジぶんは
    /// ランナーが書き込み中で消せない**(guarded) —— 束の中身は「終わらない UI テスト」の
    /// 全操作(`XCTWaiter` / `XCTContext` の活動)を起動から継続して書く生ログで、
    /// `BridgeLauncher.captureSettings`(動画・スクショを止める設定)の対象外。
    /// 実測: 実機ブリッジ1本を 75 分立てただけで束が 324 MB(24 時間なら
    /// 1台で約 6 GB/日)、8台規模の負荷試験では全体で 733 MB/時。この上限は
    /// **保持量を抑える線ではなく、立てっぱなしに気付かせる線** —— guarded だけで
    /// 超えても掃除はできず `overCapAfterGuards` の通知が出るだけ。5 GiB は単発のブリッジなら
    /// 約 20 時間(6 GB/日)で届く量で、「一晩放置」を翌朝までに拾える。尽きたら**孤児**
    /// (生きたランナーの居ないポートの束)から消える。孤児は通常
    /// `BridgeLauncher.sweepOrphanResultBundles` が起動のたびに無条件で消すので、ここに残るのは
    /// その掃除より後に生まれた分か掃除の間隔が空いた分だけ
    public static let defaultXcresultMaxBytes: Int64 = 5 * 1_073_741_824

    // MARK: - 最小値(ユーザー決定。これより小さい上限は受け付けない)

    /// `api retention --import` はこれ未満を断る。拡張は `api retention` の `minimums` を欄の下限に使う
    public static let minDeviceCapturesMaxBytes: Int64 = 1 * 1_073_741_824   // 1 GiB
    public static let minRecordingsMaxBytes: Int64 = 2 * 1_073_741_824      // 2 GiB
    public static let minReportsMaxBytes: Int64 = 100 * 1_048_576           // 100 MiB
    public static let minLogsMaxBytes: Int64 = 10 * 1_048_576               // 10 MiB
    public static let minXcresultMaxBytes: Int64 = 1 * 1_073_741_824        // 1 GiB

    /// 既定で run の完了後に掃除する。**背景の別プロセス**で走るのでテストの実行時間には乗らない
    public static let defaultSweepAfterRun = true

    /// 掃除が発動する線(上限に対する %)。**発動の線と削除後の目標は同じ線**。
    /// 上限の 90% を超えていたら 90% まで落とす = **次の run が書く分として上限の 10% を空けておく**
    /// (ユーザー決定)。目標を上限そのものにすると、90% と 100% の間では
    /// 発動しても1バイトも消えない(毎回採取だけ払う)。手動の掃除も同じ線を使う
    public static let sweepTriggerPercent: Int64 = 90

    /// 上限 → 発動の線(バイト)。**切り捨て・桁あふれ無し**(上限を先に 100 で割る)
    public static func sweepLine(forCap cap: Int64) -> Int64 {
        guard cap > 0 else { return 0 }
        return cap / 100 * sweepTriggerPercent + cap % 100 * sweepTriggerPercent / 100
    }

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
    public var effectiveXcresultMaxBytes: Int64 {
        Self.effective(xcresultMaxBytes, default: Self.defaultXcresultMaxBytes)
    }
    public var effectiveSweepAfterRun: Bool { sweepAfterRun ?? Self.defaultSweepAfterRun }

    /// 実効値に nil は無い。**0 と負を混ぜない** —— 負だけが無効(既定へ倒す)。最小値は書き込みの
    /// 門(`api retention --import`・設定タブ)でだけ効かせ、ここでは引き上げない(掃除のテストは
    /// 小さな上限で経路を通す。手で書いた設定ファイルの値はそのまま効く)
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
                        xcresultMaxBytes: effectiveXcresultMaxBytes,
                        sweepAfterRun: effectiveSweepAfterRun)
    }

    /// 全欄が既定の姿(`api retention` の `defaults` 欄)
    public static let defaults = RetentionPolicy().resolved
}
