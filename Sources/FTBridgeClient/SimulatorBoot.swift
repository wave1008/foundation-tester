// シミュレータのブート待ち(`simctl bootstatus -b` = Shutdown なら boot して SpringBoard が上がるまで待つ)。
// in-app(simctl launch はブート済みが前提)と XCUITest の両方の起動口がこれを通る。
// XCUITest 経路は xcodebuild が自動ブートもするが、**ブートの時間がランナーの起動予算に混ざる**:
// 再起動直後の 8 台同時ブートは 3 分を超え、ランナーは何も書かないまま `startupTimeoutSeconds` を
// 跨いで全滅した(2026-09-14 の陽性対照。台帳 §19.25)。ブートは観測できる事象なので先に待ち切る

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

    /// ブート済みなら約 200ms で返る。Shutdown なら boot して待つ(上限は simctl 任せ = 完了は観測で決まる)
    public static func ensureBooted(udid: String) throws {
        let result = try Shell.run(["xcrun", "simctl", "bootstatus", udid, "-b"])
        guard result.status == 0 else { throw Error.failed(udid: udid, detail: result.tail) }
    }
}
