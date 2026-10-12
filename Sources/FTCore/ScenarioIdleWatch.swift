import Foundation

/// 子の無出力が許される長さ(秒)。1 ステップは `FTSync.run` が commandTimeout で切り、失敗したステップの
/// 証跡採取が 2 本目の `FTSync` (最大 commandTimeout) を使うので、健全な子の出力間隔は 2 × commandTimeout まで。
/// `deadlineExclusion` の窓(OCR コンパイル待ち等)は含まない —— `ScenarioIdleWatch` が開いている窓の上限を別に足す
public enum ScenarioIdleBudget {
    public static func seconds(commandTimeout: Double) -> Double { 2 * commandTimeout }
}

/// 予算を超えた無出力の区間。`allowed` = budget + その時点で開いている除外窓の上限 + 申告中の待ちの上限
struct IdleGap: Sendable, Equatable {
    let silentFor: Duration
    let allowed: Duration
}

/// 子の出力の到着時刻から「出力が途切れた」を判定する純粋な値型(ScenarioHost の idle 打ち切りが使う)。
/// 許す長さ = budget + **いま開いている**除外窓の上限 + 申告中の待ち(`IdleAllowance`)の上限の最大
/// (どちらも began で開き ended で閉じる。入れ子の申告は内側が外側の中で起きるので最大で足りる)
struct ScenarioIdleWatch: Sendable {
    let budget: Duration
    private var last: SuspendingClock.Instant?
    private var openCap: Duration = .zero
    private var allowances: [Duration] = []

    init(budget: Duration) { self.budget = budget }

    mutating func start(at now: SuspendingClock.Instant) { last = now }

    mutating func activity(at now: SuspendingClock.Instant) {
        // 2 本のパイプの到着を別スレッドで受けるので、古い時刻で巻き戻さない
        if let last, now < last { return }
        last = now
    }

    mutating func setOpenExclusionCap(_ cap: Duration) { openCap = cap }

    mutating func beginAllowance(_ cap: Duration) { allowances.append(cap) }
    /// 対の無い ended は無視する(子が began の前に死んだ等で崩れても負にしない)
    mutating func endAllowance() { _ = allowances.popLast() }

    var allowed: Duration { budget + openCap + (allowances.max() ?? .zero) }

    /// この時刻までに次の出力が無ければ途切れた
    var deadline: SuspendingClock.Instant? { last.map { $0 + allowed } }

    func silence(at now: SuspendingClock.Instant) -> Duration {
        guard let last else { return .zero }
        return now - last
    }

    func overBudget(at now: SuspendingClock.Instant) -> IdleGap? {
        guard last != nil else { return nil }
        let silent = silence(at: now)
        return silent > allowed ? IdleGap(silentFor: silent, allowed: allowed) : nil
    }
}
