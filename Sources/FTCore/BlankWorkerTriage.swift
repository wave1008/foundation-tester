// BlankWorkerTriage.swift
// run の**開始前**に「画面だけ死んでいるデバイス」を弾く。
//
// Android には同じものが既にある(`ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers`。
// あちらは sleep/wake と guest reboot で**修復**まで行う)。**iOS には無かった**ため、
// 2026-08-05 に E2E-CMP の `-06` が「画面は真っ黒・a11y ツリーは健全・タップだけ届かない」
// 状態になったとき、9/9 の失敗が**無警告でテストの失敗として記録された**(docs/verification.md
// 「iOS シミュレータも『画面だけ死ぬ』」)。失敗して初めて分かるのでは遅い。
//
// **修復そのものはここに持たない**(iOS で確認できている回復手段は `simctl shutdown`→`boot`
// だけで、ブリッジごと作り直しになる)。代わりに**回復を呼び出し側から注入できる**ようにしてある
// (`recover:`)。ブリッジを張り直せるのは供給を持っている側(ProfileRunner)だけなので、
// 判定はここ・回復はあちら、と役割を割る。
//
// **レーンに凍結機を残さない**(2026-08-09 のユーザー決定): 検出したら回復を試み、
// 回復できたものはレーンに戻し、**どうしても回復できないものだけ外す**。
// 回復を注入しない呼び出し(`recover` 省略)は従来どおり「弾いて直し方を出す」だけ。

import Foundation

public enum BlankWorkerTriage {

    /// 判定結果。excluded はワーカー label(呼び出し側がログ・監査に使う)
    public struct Result {
        public let workers: [RunWorker]
        public let excluded: [String]
        public init(workers: [RunWorker], excluded: [String]) {
            self.workers = workers
            self.excluded = excluded
        }
    }

    /// blank を確定させるサンプル数と間隔。**単発のフレームでは決めない**
    /// (アプリ起動直後の白/黒フレームを凍結と誤断する)。Android 側の run 前トリアージと同じ規約
    public static let samples = 2
    public static let intervalMs = 1_500

    /// **どのワーカーを弾くかの判定だけ**を切り出した純粋ロジック(デバイス不要 = 単体テストで固める)。
    /// `blankByLabel` は「そのワーカーが恒常 blank か」。元の順序を保ったまま除外する
    public static func exclude(_ workers: [RunWorker],
                               blankByLabel: [String: Bool]) -> Result {
        let excluded = workers.map(\.label).filter { blankByLabel[$0] == true }
        guard !excluded.isEmpty else { return Result(workers: workers, excluded: []) }
        let kept = workers.filter { blankByLabel[$0.label] != true }
        return Result(workers: kept, excluded: excluded)
    }

    /// 対象にするワーカーか。**iOS の仮想デバイスだけ**:
    ///   - Android は自前のトリアージ(修復つき)が既にある = 二重に撃たない
    ///   - 実機は「画面が消灯しているだけ」を凍結と誤断する(Android 側と同じ理由)
    public static func isCandidate(_ worker: RunWorker) -> Bool {
        worker.platform == "ios" && !worker.connection.physical
    }

    /// 恒常 blank かを判定する(`samples` 回続けて一様フレームなら blank)。
    /// **撮れなかったフレームは「健全」に倒す**(誤って健全機を弾かない安全側。Android の
    /// probeBlank と同じ方針)。screenshot はテストから差し替えられるよう引数で受ける
    public static func isPersistentlyBlank(
        screenshot: () async -> Data?,
        samples: Int = samples,
        sleep: (Int) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }
    ) async -> Bool {
        for index in 0..<max(1, samples) {
            if index > 0 { await sleep(intervalMs) }
            guard let shot = await screenshot(),
                  BlankFrameDetector.isUniformBlank(pngData: shot) else { return false }
        }
        return true
    }

    /// 凍結したワーカーの label 一覧(並列判定)。健全機は1サンプルで即返るので、
    /// 正常時の固定費はスクショ1枚ぶん
    public static func frozenLabels(_ workers: [RunWorker]) async -> [String] {
        let candidates = workers.filter(isCandidate)
        guard !candidates.isEmpty else { return [] }
        return await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for worker in candidates {
                group.addTask {
                    let blank = await isPersistentlyBlank(screenshot: {
                        try? await worker.driver.screenshot()
                    })
                    return blank ? worker.label : nil
                }
            }
            var found: [String] = []
            for await label in group { if let label { found.append(label) } }
            return found
        }
    }

    /// 回復を試みる回数の上限。**2回**: 1回で戻らない個体はもう1回でも戻らないことが多く、
    /// run の立ち上がりを何分も伸ばすほうが害になる(戻らなければ外して先へ進む)
    public static let recoveryAttempts = 2

    /// run 開始前のトリアージ本体。
    ///
    /// `recover` を渡すと、凍結を見つけたときに**回復を試み、戻ったものはレーンに残す**。
    /// 戻り値は回復後に作り直したワーカー一覧で、呼び出し側はそれを使う。回復できなかった
    /// ものだけを外すので、**レーンに凍結機が残らない**。省略時は従来どおり弾くだけ。
    ///
    /// `recover` の契約: 渡された label 群のデバイスを回復し、**ブリッジを張り直した**
    /// ワーカー一覧を返す。回復手段が無い/失敗したら nil(即座に除外へ進む)
    public static func excludeBlankScreenWorkers(
        _ workers: [RunWorker],
        recover: (@Sendable ([String]) async -> [RunWorker]?)? = nil,
        log: @Sendable (String) -> Void
    ) async -> Result {
        var current = workers
        var blankLabels = await frozenLabels(current)
        guard !blankLabels.isEmpty else { return Result(workers: current, excluded: []) }

        if let recover {
            for attempt in 1...recoveryAttempts {
                log("⚠️ \(blankLabels.count) device(s) have a frozen screen"
                    + " (\(blankLabels.joined(separator: ", "))) — recovering before the run starts"
                    + " (attempt \(attempt)/\(recoveryAttempts))")
                guard let rebuilt = await recover(blankLabels) else { break }
                current = rebuilt
                blankLabels = await frozenLabels(current)
                if blankLabels.isEmpty {
                    log("✅ every frozen device recovered — starting with all lanes")
                    return Result(workers: current, excluded: [])
                }
            }
        }

        for label in blankLabels {
            // **直し方まで書く**。iOS には自動修復が無いので、ここで手順が出ないと
            // 「弾かれた」だけが残って次の run でも同じ個体が死んでいる
            log("⚠️ \(label): the screen is frozen (a11y still responds but nothing renders and taps"
                + " do not land) — could not recover it, so it is excluded from dispatch."
                + " Recover it with: xcrun simctl shutdown <udid> && xcrun simctl boot <udid>")
        }
        return exclude(current, blankByLabel: Dictionary(
            uniqueKeysWithValues: blankLabels.map { ($0, true) }))
    }
}
