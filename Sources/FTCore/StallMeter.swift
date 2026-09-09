// **プロセスが止まっていたか**を、仕事の中身と無関係に外から見るための心拍。
//
// なぜ要るか(実測 2026-09-10): 120 秒で打ち切られたステップは、順番待ち 0ms・
// snapshot/action/wait の合計 0.1〜1.5 秒・出力ブロック 0ms・FM 呼び出し無しだった。
// つまり「何かを待っていた」ことしか分からず、**待たされた側なのか自分が固まったのか**が
// 判定できない。心拍を2本持つと3つを区別できる:
//   - ①専用 OS スレッドの心拍が飛ぶ  = プロセス/機械ごと止まっている(外因。締め切りは不当)
//   - ②協調スレッドプールの心拍だけ飛ぶ = プールが詰まっている(誰かが cooperative thread を
//     ブロックしている。締め切りは不当だが直す場所はこちら側)
//   - ③どちらも動いているのにステップだけ長い = 相手(ブリッジ/デバイス)待ち
//
// 数える対象は**遅延ぶんだけ**(予定より遅れた分の合計)。刻みそのものは数えない。

import Foundation

public final class StallMeter: @unchecked Sendable {
    public static let shared = StallMeter()

    /// 心拍の間隔。短くすると計測自体が負荷になり、長くすると短い停止を見落とす。
    /// 100ms は「ステップの締め切り 120 秒に対して 0.08%」= 見落としが結論を変えない粒度
    static let tickMilliseconds = 100
    /// これ以下の遅れは数えない(スケジューラの普通のゆらぎ。実測でこの下は常時発生する)
    static let ignoreBelowMilliseconds = 50

    private let lock = NSLock()
    private var threadStall = 0
    private var poolStall = 0
    private var started = false

    /// テストは**自分のインスタンス**で算術を確かめる(shared は心拍が走っていて、
    /// 同じ過程で数字が動くため等号で固定できない)
    init() {}

    /// プロセスに1組だけ立てる(2 回目以降は何もしない)
    public func startIfNeeded() {
        lock.lock()
        let wasStarted = started
        started = true
        lock.unlock()
        guard !wasStarted else { return }

        // ①協調スレッドプールの外。ここが飛べばプロセスごと止まっている
        let thread = Thread { [weak self] in
            let clock = ContinuousClock()
            var expected = clock.now
            while true {
                expected = expected.advanced(by: .milliseconds(Self.tickMilliseconds))
                Thread.sleep(forTimeInterval: Double(Self.tickMilliseconds) / 1000)
                self?.record(overshoot: clock.now - expected, pool: false)
                expected = max(expected, clock.now)
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()

        // ②協調スレッドプールの中。①が動いていてここが飛べばプールが詰まっている
        Task.detached(priority: .userInitiated) { [weak self] in
            let clock = ContinuousClock()
            var expected = clock.now
            while true {
                expected = expected.advanced(by: .milliseconds(Self.tickMilliseconds))
                try? await Task.sleep(for: .milliseconds(Self.tickMilliseconds))
                self?.record(overshoot: clock.now - expected, pool: true)
                expected = max(expected, clock.now)
            }
        }
    }

    func record(overshoot: Duration, pool: Bool) {
        let ms = Int(overshoot.components.seconds) * 1000
            + Int(overshoot.components.attoseconds / 1_000_000_000_000_000)
        guard ms >= Self.ignoreBelowMilliseconds else { return }
        lock.lock()
        if pool { poolStall += ms } else { threadStall += ms }
        lock.unlock()
    }

    /// プロセス開始からの累計(ミリ秒)。読み手は差分を取る(cpuMs と同じ使い方)
    public var threadStallMilliseconds: Int {
        lock.lock(); defer { lock.unlock() }; return threadStall
    }

    public var poolStallMilliseconds: Int {
        lock.lock(); defer { lock.unlock() }; return poolStall
    }
}
