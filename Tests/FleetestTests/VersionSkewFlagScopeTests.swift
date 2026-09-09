// `--allow-version-skew` は DriverOptions を共有する全コマンドのヘルプに出るが、効くのは
// `makeDriver` を通る手動駆動コマンドだけ。通らないコマンド(bridge up/status・api list-apps・
// api live)は「指定したのに黙って効かない」形を作らないよう名指しで断る。
// ここは拒否が parse 時点で落ちることと、手動駆動側では受理されること(陰性対照)を固定する。

import XCTest
import ArgumentParser
@testable import fleetest

final class VersionSkewFlagScopeTests: XCTestCase {

    func testBridgeUpRejectsTheFlag() {
        XCTAssertThrowsError(try Bridge.Up.parse(["--allow-version-skew"])) { error in
            let message = Bridge.Up.message(for: error)
            XCTAssertTrue(message.contains("--allow-version-skew has no effect on bridge up"), message)
        }
    }

    func testBridgeStatusRejectsTheFlag() {
        XCTAssertThrowsError(try Bridge.Status.parse(["--allow-version-skew"])) { error in
            let message = Bridge.Status.message(for: error)
            XCTAssertTrue(message.contains("has no effect on bridge status"), message)
        }
    }

    func testApiListAppsRejectsTheFlag() {
        XCTAssertThrowsError(try ApiListApps.parse(["--allow-version-skew"])) { error in
            let message = ApiListApps.message(for: error)
            XCTAssertTrue(message.contains("has no effect on api list-apps"), message)
        }
    }

    /// 陰性対照: 手動駆動コマンドは受理する(常に throw する実装と区別する)
    func testManualDriveCommandsAcceptTheFlag() throws {
        let snapshot = try Snapshot.parse(["--allow-version-skew"])
        XCTAssertTrue(snapshot.driverOptions.allowVersionSkew)
        let status = try Bridge.Status.parse([])
        XCTAssertFalse(status.driverOptions.allowVersionSkew)
    }
}
