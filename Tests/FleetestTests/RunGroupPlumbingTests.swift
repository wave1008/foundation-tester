// 機械ごとに分かれた run を束ねる鍵(FTCore.RunMetaRecord.runGroup)の中継。
// **発行はファンアウトの親だけ**で、子(手元・リモート)は受け取った値をそのまま run.json に書く。
// 落ちると症状は「録画セッションが Mac ごとにバラバラのまま」= 静かな退行なので、
// 両方の親(CLI の DeviceMachineRunner / api の ApiRunMachineFanout)の引数組み立てを等号で固定する。
// リモートへの中継は FTCoreTests.RemoteDispatchTests の testRemoteRunArgsRelaysTheRunGroup。

import XCTest
import FTCore
@testable import fleetest

final class RunGroupPlumbingTests: XCTestCase {

    private let key = "20260826-010203Z-LDIPC96-beef"

    /// CLI のマシン別サブ実行(`fleetest run`)。ローカル子・リモート子のどちらにも同じ鍵が付く
    func testFleetRunnerBuildArgsRelaysTheRunGroupForEveryHost() {
        for host in ["local", "M1Max"] {
            let args = FleetRunner.buildArgs(
                project: "E2E-Android", host: host, profile: "android",
                deviceNames: ["Pixel 3a"], deviceMachine: host,
                scenarios: ["A.S0010"], folders: [],
                heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
                fastInput: false, enableAnimations: false, performanceMode: false,
                forceLock: false, waitLock: nil, remoteDir: nil, remoteTimeout: nil,
                remoteArtifacts: "collect", quiet: false, junitPath: nil, runGroup: key)
            guard let index = args.firstIndex(of: "--run-group") else {
                XCTFail("host=\(host) に束ね鍵が付いていない: \(args)")
                return
            }
            XCTAssertEqual(args[args.index(after: index)], key, "host=\(host)")
        }
    }

    /// 単機の run(束ねる相手が居ない)には付けない —— 旧レコードと同じ形を保つ
    func testFleetRunnerBuildArgsOmitsTheRunGroupWhenAbsent() {
        let args = FleetRunner.buildArgs(
            project: "E2E-Android", host: "local", profile: "android",
            scenarios: [], folders: [],
            heal: false, noHeal: false, noLPT: false, lptHistoryRuns: nil,
            fastInput: false, enableAnimations: false, performanceMode: false,
            forceLock: false, waitLock: nil, remoteDir: nil, remoteTimeout: nil,
            remoteArtifacts: "collect", quiet: false, junitPath: nil)
        XCTAssertFalse(args.contains("--run-group"), "\(args)")
    }

    /// 拡張の経路(`fleetest api run`)。こちらは鍵が必須引数なので、付いていることと値を見る
    func testApiRunMachineFanoutBuildArgsRelaysTheRunGroupForEveryMachine() {
        for machine: String? in [nil, "M1Ultra"] {
            let group = DeviceMachineRunner.Group(
                machine: machine, deviceNames: ["Pixel 3a"], platforms: ["android"])
            let args = ApiRunMachineFanout.buildArgs(
                project: "E2E-Android", profileName: "android", group: group,
                scenarioIDs: ["A.S0010"],
                options: ApiRunMachineFanout.Options(
                    heal: false, defaultTimeout: nil, scenarioTimeout: nil, noLPT: false,
                    lptHistoryRuns: nil, performanceMode: false, remoteDir: nil,
                    remoteTimeout: nil, remoteArtifacts: "collect", waitLock: nil),
                runGroup: key)
            guard let index = args.firstIndex(of: "--run-group") else {
                XCTFail("machine=\(String(describing: machine)) に束ね鍵が付いていない: \(args)")
                return
            }
            XCTAssertEqual(args[args.index(after: index)], key, "machine=\(String(describing: machine))")
        }
    }

    /// 鍵は **runID と同じ形**(辞書順=時系列順)で、呼ぶたびに違う値になる
    /// (親が1回だけ発行して配る前提なので、同じ値が返ると別々の実行が束になる)
    func testMakeRunGroupIDLooksLikeARunIDAndIsUnique() {
        let a = RunRecorder.makeRunGroupID()
        let b = RunRecorder.makeRunGroupID()
        XCTAssertNotEqual(a, b)
        XCTAssertNotNil(a.range(of: #"^\d{8}-\d{6}Z-[A-Za-z0-9_-]+-[0-9a-f]{4}$"#, options: .regularExpression),
                        "runID と同じ形でない: \(a)")
    }

    /// `--wait-lock` は**リモートの子にだけ**渡す(手元の子にディスパッチのロックは無い)。
    /// ここが抜けると、拡張の設定が**複数機械にまたがるプロファイルでだけ黙って効かない**
    /// (共有フリートで一番待ちたい形。docs/remote-runner.md §18.7)
    func testApiRunMachineFanoutRelaysWaitLockToRemoteChildrenOnly() {
        func args(machine: String?) -> [String] {
            ApiRunMachineFanout.buildArgs(
                project: "E2E-Android", profileName: "android",
                group: DeviceMachineRunner.Group(
                    machine: machine, deviceNames: ["Pixel 3a"], platforms: ["android"]),
                scenarioIDs: ["A.S0010"],
                options: ApiRunMachineFanout.Options(
                    heal: false, defaultTimeout: nil, scenarioTimeout: nil, noLPT: false,
                    lptHistoryRuns: nil, performanceMode: false, remoteDir: nil,
                    remoteTimeout: nil, remoteArtifacts: "collect", waitLock: 600),
                runGroup: "g")
        }
        let remote = args(machine: "M1Ultra")
        guard let index = remote.firstIndex(of: "--wait-lock") else {
            return XCTFail("リモートの子に --wait-lock が付いていない: \(remote)")
        }
        XCTAssertEqual(remote[remote.index(after: index)], "600")
        XCTAssertFalse(args(machine: nil).contains("--wait-lock"), "手元の子には渡さない")
    }
}
