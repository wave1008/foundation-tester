// `--set <key>=<value>` の中継。`fleetest run --heal` 等の旧フラグは
// FleetRunner.buildArgs(マシン別サブ実行・--fleet の子)と ApiRunMachineFanout.buildArgs
// (拡張の複数機械プロファイル)の両方へ個別に配線されていた。ここは置き換えた `--set` が
// 同じ2箇所へ実際に届くことを固定する(FTCoreTests.RemoteDispatchTests は `--host` 越しの
// RemoteRunArgs.build/buildApi の中継を固定しており、こちらはローカル子プロセス経路)。

import XCTest
import FTCore
@testable import fleetest

final class SetOverrideRelayTests: XCTestCase {

    /// マシン別サブ実行・--fleet の子プロセス引数。**中継しないと黙って無視される**
    /// (子はプロファイルの既定で走る)。キーは辞書順で安定させる
    func testFleetRunnerBuildArgsRelaysSetOverridesSortedByKey() {
        let args = FleetRunner.buildArgs(
            project: "E2E-Android", host: "local", profile: "android",
            scenarios: ["A.S0010"], folders: [],
            setOverrides: ["heal": true, "enableAnimations": false],
            noLPT: false, lptHistoryRuns: nil, performanceMode: false,
            forceLock: false, waitLock: nil, remoteDir: nil, remoteTimeout: nil,
            remoteArtifacts: "collect", quiet: false, junitPath: nil)
        guard let index = args.firstIndex(of: "--set") else {
            return XCTFail("--set が中継されていない: \(args)")
        }
        XCTAssertEqual(Array(args[index...]),
                       ["--set", "enableAnimations=false", "--set", "heal=true"], "\(args)")
    }

    func testFleetRunnerBuildArgsOmitsSetWhenEmpty() {
        let args = FleetRunner.buildArgs(
            project: "E2E-Android", host: "local", profile: "android",
            scenarios: [], folders: [],
            noLPT: false, lptHistoryRuns: nil, performanceMode: false,
            forceLock: false, waitLock: nil, remoteDir: nil, remoteTimeout: nil,
            remoteArtifacts: "collect", quiet: false, junitPath: nil)
        XCTAssertFalse(args.contains("--set"), "\(args)")
    }

    /// 拡張の複数機械プロファイル(`fleetest api run`)の子プロセス引数。同じ規律
    func testApiRunMachineFanoutBuildArgsRelaysSetOverridesSortedByKey() {
        let group = DeviceMachineRunner.Group(
            machine: "M1Ultra", deviceNames: ["Pixel 3a"], platforms: ["android"])
        let args = ApiRunMachineFanout.buildArgs(
            project: "E2E-Android", profileName: "android", group: group,
            scenarioIDs: ["A.S0010"],
            options: ApiRunMachineFanout.Options(
                setOverrides: ["falsePositiveCheck": false, "ocr": true],
                defaultTimeout: nil, scenarioTimeout: nil, noLPT: false,
                lptHistoryRuns: nil, performanceMode: false, remoteDir: nil,
                remoteTimeout: nil, remoteArtifacts: "collect", waitLock: nil),
            runGroup: "g")
        guard let index = args.firstIndex(of: "--set") else {
            return XCTFail("--set が中継されていない: \(args)")
        }
        // 末尾は --run-group g なので、その手前2組が --set トークン
        let setTokens = Array(args[index..<(args.count - 2)])
        XCTAssertEqual(setTokens,
                       ["--set", "falsePositiveCheck=false", "--set", "ocr=true"], "\(args)")
    }

    func testApiRunMachineFanoutBuildArgsOmitsSetWhenEmpty() {
        let group = DeviceMachineRunner.Group(
            machine: nil, deviceNames: ["Pixel 3a"], platforms: ["android"])
        let args = ApiRunMachineFanout.buildArgs(
            project: "E2E-Android", profileName: "android", group: group,
            scenarioIDs: ["A.S0010"],
            options: ApiRunMachineFanout.Options(
                defaultTimeout: nil, scenarioTimeout: nil, noLPT: false,
                lptHistoryRuns: nil, performanceMode: false, remoteDir: nil,
                remoteTimeout: nil, remoteArtifacts: "collect", waitLock: nil),
            runGroup: "g")
        XCTAssertFalse(args.contains("--set"), "\(args)")
    }
}
