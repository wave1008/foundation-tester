// `bridge down --port N` が止めるものが無いときの文言。**in-app ブリッジ(dylib 注入)は
// `.pid` を持たず `.inapp` だけ**なので、`.pid` しか名指さないと「bridge status が inapp と
// 表示したポートなのに pid が無いと言われた」という読み違いを生む。

import XCTest
@testable import FTBridgeClient

final class BridgeLauncherNotRunningMessageTests: XCTestCase {

    func testNotRunningNamesBothLedgerFiles() throws {
        let message = try XCTUnwrap(LauncherError.notRunning(port: 8131).errorDescription)
        XCTAssertTrue(message.contains(".fleetest/bridge-8131.pid"), message)
        XCTAssertTrue(message.contains(".fleetest/bridge-8131.inapp"), message)
    }

    /// ポートが分からない経路でも両方を名指す
    func testNotRunningWithoutPortStillNamesBothLedgerFiles() throws {
        let message = try XCTUnwrap(LauncherError.notRunning(port: nil).errorDescription)
        XCTAssertTrue(message.contains(".pid"), message)
        XCTAssertTrue(message.contains(".inapp"), message)
    }
}
