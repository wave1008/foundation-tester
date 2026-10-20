// iOS Simulator を起動する**唯一の入口**(`simctl bootstatus -b` = Shutdown なら boot して SpringBoard が上がるまで待つ)。
// 起動前の掃除 `SimulatorBootCleanup.beforeBoot` と、機械全体で同時2台の枠 `SimulatorBootSlots` をここで掛ける。
// 直接 simctl boot / bootstatus を撃たない(`SimulatorBootSingleEntryTests`)。
// XCUITest 経路は xcodebuild が自動ブートもするが、**ブートの時間がランナーの起動予算に混ざる**:
// 再起動直後の 8 台同時ブートは 3 分を超え、ランナーは何も書かないまま `startupTimeoutSeconds` を
// 跨いで全滅した(陽性対照。台帳 §19.25)。ブートは観測できる事象なので先に待ち切る

import Foundation
import FTCore

public enum SimulatorBoot {
    public enum Error: Swift.Error, CustomStringConvertible {
        case failed(udid: String, detail: String)
        public var description: String {
            switch self {
            case .failed(let udid, let detail): return "could not boot the simulator \(udid) (simctl bootstatus -b):\n\(detail)"
            }
        }
    }

    /// ブート済みなら約 200ms で返る。Shutdown なら枠を待って boot し、完了まで待つ(上限は simctl 任せ = 完了は観測で決まる)
    public static func ensureBooted(udid: String, log: (String) -> Void) throws {
        // Booted なら SimulatorPosterCache が自ら気付いて何もしない(docs/design.md §Simulator の供給・健全性)
        SimulatorBootCleanup.beforeBoot(udid: udid)
        try run(
            udid: udid,
            tryAcquire: { SimulatorBootSlots.acquireWithoutWaiting(udid: udid) },
            acquireWaiting: { SimulatorBootSlots.acquire(udid: udid, log: log) },
            release: { SimulatorBootSlots.release(udid: udid) },
            readBootedOrTransitioning: {
                (try? SimulatorCatalog.devices())?.first(where: { $0.udid == udid })
                    .map { $0.booted || $0.transitioning } ?? false
            },
            boot: { try Shell.run(["xcrun", "simctl", "bootstatus", udid, "-b"]) })
    }

    /// 枠の判断だけを切り出した本体(状態読みと起動を注入してテストする)。
    /// 枠が空いていれば状態を読まずに撃つ。埋まっていて起動済み・起動中なら枠なしで撃つ(他の起動を待たせない)。
    /// 状態が読めなければ Shutdown 扱い = 枠を待つ
    static func run(udid: String,
                    tryAcquire: () -> Bool,
                    acquireWaiting: () -> Void,
                    release: () -> Void,
                    readBootedOrTransitioning: () -> Bool,
                    boot: () throws -> Shell.Result) throws {
        func bootAndCheck() throws {
            let result = try boot()
            guard result.status == 0 else { throw Error.failed(udid: udid, detail: result.tail) }
        }
        if tryAcquire() {
            defer { release() }
            try bootAndCheck()
            return
        }
        if readBootedOrTransitioning() {
            try bootAndCheck()
            return
        }
        acquireWaiting()
        defer { release() }
        try bootAndCheck()
    }
}
