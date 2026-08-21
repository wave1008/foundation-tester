// `ftester run --each-device` のフラグの規律。中継漏れと「黙って無視」は緑の run に現れない
// (分配で走っても全部通る)ので、ここで固定する。

import XCTest
import ArgumentParser
import FTCore
@testable import ftester

final class EachDeviceFlagTests: XCTestCase {

    /// ホスト別サブ実行(DeviceHostRunner)は FleetRunner.buildArgs で子の引数を作る。
    /// ここで落とすと、ホスト混在プロファイルだけブロードキャストにならない
    func testFleetBuildArgsRelaysEachDeviceOnlyWhenSet() {
        func args(eachDevice: Bool) -> [String] {
            FleetRunner.buildArgs(
                project: "E2E", host: "local", profile: "p",
                deviceNames: ["iPhone-01"], deviceHost: "local",
                scenarios: ["Warm.up"], folders: [],
                heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
                fastInput: false, enableAnimations: false, performanceMode: false,
                forceLock: false, waitLock: nil, remoteDir: nil, remoteTimeout: nil,
                remoteArtifacts: "collect", quiet: true, junitPath: nil, eachDevice: eachDevice)
        }
        XCTAssertTrue(args(eachDevice: true).contains("--each-device"))
        XCTAssertFalse(args(eachDevice: false).contains("--each-device"))
    }

    /// --profile 無しでは拒否する(レーン = プロファイルのデバイス。--ports にはレーンの名が無い)
    func testEachDeviceRequiresProfile() {
        XCTAssertThrowsError(try RunScenarios.parse(["--each-device"])) { error in
            XCTAssertTrue(RunScenarios.message(for: error).contains("--each-device requires --profile"),
                          RunScenarios.message(for: error))
        }
        XCTAssertNoThrow(try RunScenarios.parse(["--each-device", "--profile", "p"]))
    }

    /// --fleet とは併用不可(fleet の子へは中継していないので、通すと黙って分配で走る)
    func testEachDeviceRejectsFleet() {
        XCTAssertThrowsError(try RunScenarios.parse(["--each-device", "--fleet", "f"])) { error in
            XCTAssertTrue(RunScenarios.message(for: error).contains("--each-device cannot be combined with --fleet"),
                          RunScenarios.message(for: error))
        }
    }
}
