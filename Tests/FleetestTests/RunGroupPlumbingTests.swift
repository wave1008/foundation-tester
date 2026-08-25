// 機械ごとに分かれた run を束ねる鍵(FTCore.RunMetaRecord.runGroup)の中継。
// **発行はファンアウトの親だけ**で、子(手元・リモート)は受け取った値をそのまま run.json に書く。
// 落ちると症状は「録画セッションが Mac ごとにバラバラのまま」= 静かな退行なので、
// 両方の親(CLI の DeviceHostRunner / api の ApiRunHostFanout)の引数組み立てを等号で固定する。
// リモートへの中継は FTCoreTests.RemoteDispatchTests の testRemoteRunArgsRelaysTheRunGroup。

import XCTest
import FTCore
@testable import fleetest

final class RunGroupPlumbingTests: XCTestCase {

    private let key = "20260826-010203Z-LDIPC96-beef"

    /// CLI のホスト別サブ実行(`fleetest run`)。ローカル子・リモート子のどちらにも同じ鍵が付く
    func testFleetRunnerBuildArgsRelaysTheRunGroupForEveryHost() {
        for host in ["local", "M1Max"] {
            let args = FleetRunner.buildArgs(
                project: "E2E-Android", host: host, profile: "android",
                deviceNames: ["Pixel 3a"], deviceHost: host,
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
    func testApiRunHostFanoutBuildArgsRelaysTheRunGroupForEveryHost() {
        for host: String? in [nil, "M1Ultra"] {
            let group = DeviceHostRunner.Group(
                host: host, deviceNames: ["Pixel 3a"], platforms: ["android"])
            let args = ApiRunHostFanout.buildArgs(
                project: "E2E-Android", profileName: "android", group: group,
                scenarioIDs: ["A.S0010"],
                options: ApiRunHostFanout.Options(
                    heal: false, defaultTimeout: nil, scenarioTimeout: nil, noLPT: false,
                    lptHistoryRuns: nil, performanceMode: false, remoteDir: nil,
                    remoteTimeout: nil, remoteArtifacts: "collect"),
                runGroup: key)
            guard let index = args.firstIndex(of: "--run-group") else {
                XCTFail("host=\(String(describing: host)) に束ね鍵が付いていない: \(args)")
                return
            }
            XCTAssertEqual(args[args.index(after: index)], key, "host=\(String(describing: host))")
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
}
