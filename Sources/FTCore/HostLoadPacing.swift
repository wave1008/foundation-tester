// ホストの CPU 負荷に応じて、操作のステップの前に短い待ちを1回入れる「ステップの減速」。
// 同じ run の中でも CPU 97% 以上で始まったステップは 90% 未満の約2倍落ちるので、高い瞬間だけ投入を遅らせて張り付きを減らす。
// **負荷が下がるまで待つのではない** —— 1ステップにつき CPU の段に応じた固定の待ちを1回だけ。
// 設定は LocalConfig.hostLoadPacing(マシン設定)。読むのは親の ScenarioHost.run だけで、子へは
// `--host-load-pacing <HostLoadPacingPlan の JSON>` で渡す(子のサンドボックスは ~/.config を読めない)。

import Foundation

public struct HostLoadPacing: Codable, Sendable, Equatable {
    public struct Tier: Codable, Sendable, Equatable {
        /// CPU 使用率(%)がこの値以上で適用。0 < p ≤ 100
        public var cpuPercentAtLeast: Double
        /// 待ち(ミリ秒)。0 以上
        public var delayMs: Int

        public init(cpuPercentAtLeast: Double, delayMs: Int) {
            self.cpuPercentAtLeast = cpuPercentAtLeast
            self.delayMs = delayMs
        }
    }

    /// true で無効。nil・false = 有効(欄ごと無い設定も有効)
    public var disabled: Bool?
    /// nil = 既定の段。`[]` = 段が無い = 待たない
    public var tiers: [Tier]?

    public init(disabled: Bool? = nil, tiers: [Tier]? = nil) {
        self.disabled = disabled
        self.tiers = tiers
    }

    /// 既定の段の唯一の定義元。根拠(この Mac・Android 6 台・配信あり・各 2 run): 減速なしで CPU 97% 以上の時間
    /// 13.1% → この段で約 2%(所要 +11%)。95% の段を 2000ms にしても 97% 以上は減らず所要だけ +6%、
    /// 95% を 93% に下げても変わらなかった
    public static let defaultTiers: [Tier] = [
        Tier(cpuPercentAtLeast: 90, delayMs: 200),
        Tier(cpuPercentAtLeast: 95, delayMs: 1000),
    ]

    public struct Resolution: Equatable, Sendable {
        public var tiers: [Tier]
        /// 設定が不正で既定の段へ倒したときの説明(英語)。呼び手が stderr へ1回出す
        public var warning: String?
    }

    /// 設定 → 有効な段。無効なら nil。不正な段は**既定の段へ倒す**(黙って 0 にすると減速を外した run になる)
    public static func resolve(_ setting: HostLoadPacing?) -> Resolution? {
        if setting?.disabled == true { return nil }
        guard let tiers = setting?.tiers else { return Resolution(tiers: defaultTiers, warning: nil) }
        if let problem = problem(in: tiers) {
            return Resolution(
                tiers: defaultTiers,
                warning: "hostLoadPacing in the machine config is invalid (\(problem)); using the default tiers")
        }
        return Resolution(tiers: tiers, warning: nil)
    }

    static func problem(in tiers: [Tier]) -> String? {
        var seen = Set<Double>()
        for tier in tiers {
            guard tier.cpuPercentAtLeast > 0, tier.cpuPercentAtLeast <= 100 else {
                return "cpuPercentAtLeast must be greater than 0 and at most 100"
            }
            guard tier.delayMs >= 0 else { return "delayMs must not be negative" }
            guard seen.insert(tier.cpuPercentAtLeast).inserted else {
                return "cpuPercentAtLeast is duplicated"
            }
        }
        return nil
    }

    /// 待つのは**画面を変える操作**の前だけ。検証と、画面を読むだけ・待つだけのステップの前では待たない
    /// (操作の直後に消える Snackbar 等を、待ちのせいで見逃して誤った赤になる)。action の無いステップも待たない。
    /// **`settle: false` の操作も待たない** —— 利用者が速さ優先と明示した操作(消える表示を叩く・連打)で、
    /// 待つと間に合わなくなる(Material の Snackbar の短い表示は 1.5 秒)
    public static func pacesBefore(action: String?, isVerification: Bool, settle: Bool?) -> Bool {
        guard !isVerification, settle != false, let action else { return false }
        return !nonOperationActions.contains(action)
    }

    /// action を持つが操作ではないもの: 画面を読むだけ(select・findImages = 検証とセットで使う)/
    /// 待つだけ(waitForSettle)。hold の押している間は FTDriveCore が別に止める
    static let nonOperationActions: Set<String> = ["select", "findImages", "waitForSettle"]

    /// cpu は 0〜1 の割合。当たる段のうち**最大の閾値**の delayMs(入力の並びに依らない)。値が無ければ待たない
    public static func delayMs(cpu: Double?, tiers: [Tier]) -> Int {
        guard let cpu else { return 0 }
        let hit = tiers.filter { cpu >= $0.cpuPercentAtLeast / 100 }
        return hit.max { $0.cpuPercentAtLeast < $1.cpuPercentAtLeast }?.delayMs ?? 0
    }
}

/// 親 → 子へ運ぶ計画
public struct HostLoadPacingPlan: Codable, Sendable, Equatable {
    public var tiers: [HostLoadPacing.Tier]

    public init(tiers: [HostLoadPacing.Tier]) {
        self.tiers = tiers
    }
}

/// **その瞬間**の CPU 使用率(全コア合計の割合)。tick を2回読み、その差で求める(使用率は差分でしか出せない)。
/// 呼んだプロセスは窓のぶん眠る。**Sendable ではない** —— CPUSampler が前回の tick を持つので DSL スレッドだけで使う
public final class InstantHostCPU {
    /// 2回の読みの間隔(秒)。この Mac(M2 Ultra・24 コア)の実測で 5ms の窓でも 100 回中 100 回値が取れ、
    /// 値もばらついた(tick は 10ms より細かい)。分解能の余裕を見て 10ms。操作1回ごとにこのぶん遅れる
    public static let windowSeconds = 0.01

    private let sampler: CPUSampler

    /// 測れない環境(host_processor_info の失敗)は logFailure へ1回だけ言い、以降は nil(= 待たない)
    public init(logFailure: @escaping (String) -> Void) {
        sampler = CPUSampler(logFailure: logFailure)
    }

    public func read() -> Double? {
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: Self.windowSeconds)
        return sampler.sample()
    }
}
