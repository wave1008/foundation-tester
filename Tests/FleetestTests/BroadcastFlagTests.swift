// `fleetest run --broadcast` のフラグの規律。中継漏れと「黙って無視」は緑の run に現れない
// (分配で走っても全部通る)ので、ここで固定する。

import XCTest
import ArgumentParser
import FTCore
@testable import fleetest

final class BroadcastFlagTests: XCTestCase {

    /// ホスト別サブ実行(DeviceHostRunner)は FleetRunner.buildArgs で子の引数を作る。
    /// ここで落とすと、ホスト混在プロファイルだけブロードキャストにならない
    func testFleetBuildArgsRelaysBroadcastOnlyWhenSet() {
        func args(broadcast: Bool) -> [String] {
            FleetRunner.buildArgs(
                project: "E2E", host: "local", profile: "p",
                deviceNames: ["iPhone-01"], deviceHost: "local",
                scenarios: ["Warm.up"], folders: [],
                heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
                fastInput: false, enableAnimations: false, performanceMode: false,
                forceLock: false, waitLock: nil, remoteDir: nil, remoteTimeout: nil,
                remoteArtifacts: "collect", quiet: true, junitPath: nil, broadcast: broadcast)
        }
        XCTAssertTrue(args(broadcast: true).contains("--broadcast"))
        XCTAssertFalse(args(broadcast: false).contains("--broadcast"))
    }

    /// --profile 無しでは拒否する(レーン = プロファイルのデバイス。--ports にはレーンの名が無い)
    func testBroadcastRequiresProfile() {
        XCTAssertThrowsError(try RunScenarios.parse(["--broadcast"])) { error in
            XCTAssertTrue(RunScenarios.message(for: error).contains("--broadcast requires --profile"),
                          RunScenarios.message(for: error))
        }
        XCTAssertNoThrow(try RunScenarios.parse(["--broadcast", "--profile", "p"]))
    }

    /// --fleet とは併用不可(fleet の子へは中継していないので、通すと黙って分配で走る)
    func testBroadcastRejectsFleet() {
        XCTAssertThrowsError(try RunScenarios.parse(["--broadcast", "--fleet", "f"])) { error in
            XCTAssertTrue(RunScenarios.message(for: error).contains("--broadcast cannot be combined with --fleet"),
                          RunScenarios.message(for: error))
        }
    }
}
