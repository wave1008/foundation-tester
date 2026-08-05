// BlankWorkerTriage.swift
// run の**開始前**に「画面だけ死んでいるデバイス」を弾く。
//
// Android には同じものが既にある(`ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers`。
// あちらは sleep/wake と guest reboot で**修復**まで行う)。**iOS には無かった**ため、
// 2026-08-05 に E2E-CMP の `-06` が「画面は真っ黒・a11y ツリーは健全・タップだけ届かない」
// 状態になったとき、9/9 の失敗が**無警告でテストの失敗として記録された**(docs/verification.md
// 「iOS シミュレータも『画面だけ死ぬ』」)。失敗して初めて分かるのでは遅い。
//
// **修復は持たない**(iOS で確認できている回復手段は `simctl shutdown`→`boot` だけで、
// ブリッジごと作り直しになるため run 前トリアージの範囲を超える)。弾いて、直し方をログに出す。

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

    /// run 開始前のトリアージ本体。対象ワーカーを**並列に**判定して blank を除外する。
    /// 健全機は1サンプルで即返るので、正常時の固定費はスクショ1枚ぶん
    public static func excludeBlankScreenWorkers(
        _ workers: [RunWorker], log: @Sendable (String) -> Void
    ) async -> Result {
        let candidates = workers.filter(isCandidate)
        guard !candidates.isEmpty else { return Result(workers: workers, excluded: []) }

        let blankLabels = await withTaskGroup(of: String?.self, returning: [String].self) { group in
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
        guard !blankLabels.isEmpty else { return Result(workers: workers, excluded: []) }

        for label in blankLabels {
            // **直し方まで書く**。iOS には自動修復が無いので、ここで手順が出ないと
            // 「弾かれた」だけが残って次の run でも同じ個体が死んでいる
            log("⚠️ \(label): the screen is frozen (a11y still responds but nothing renders and taps"
                + " do not land) — excluding it from dispatch."
                + " Recover it with: xcrun simctl shutdown <udid> && xcrun simctl boot <udid>")
        }
        return exclude(workers, blankByLabel: Dictionary(
            uniqueKeysWithValues: blankLabels.map { ($0, true) }))
    }
}
