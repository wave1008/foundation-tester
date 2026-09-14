// bug-audit-2026-09-06.md §3: `RunnerProfileTransfer.localizeAndUpload` は
// `RemoteRunDispatcher.dispatch`/`dispatchApi`(どちらも async)から同期的に呼ばれる。
// `Process.waitUntilExit()` は RunLoop 通知に依存するため、async 関数の協調スレッド上で
// 呼ぶと終了通知を取りこぼして永久ハングし得る(Sources/FTCore/Shell.swift の
// `ProcessExitWait` 宣言参照)。修正は `ProcessExitWait.prepareBlocking` へ置き換え(挙動は
// 「rsync の終了まで同期的に待つ」のまま変えない)。ソース走査で退行を止める。

import Foundation
import XCTest

final class RunnerProfileTransferProcessWaitTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
    }

    func testRunnerProfileTransferDoesNotUseRunLoopBasedWait() throws {
        let url = Self.repoRoot.appendingPathComponent("Sources/fleetest/RunnerProfileTransfer.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains(".waitUntilExit()"),
                       "RunnerProfileTransfer.swift は async 関数(RemoteRunDispatcher.dispatch/"
                       + "dispatchApi)から呼ばれるので Process.waitUntilExit() を使わないこと"
                       + "(ProcessExitWait.prepareBlocking を使う)")
        XCTAssertTrue(source.contains("ProcessExitWait.prepareBlocking"),
                     "rsync の終了待ちが ProcessExitWait 経由でなくなっている")
    }
}
