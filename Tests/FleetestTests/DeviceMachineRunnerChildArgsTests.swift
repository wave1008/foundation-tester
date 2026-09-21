// `DeviceMachineRunner.childArgs`(マシン別サブ実行の argv 組み立て)の規律を固定する。
// 欠陥(bug-audit-2026-09-06.md §3): 複数機械にまたがるプロファイルでは `--failed`/`--report-dir`
// が黙って落ち、ローカル子は `--skip-build` 無しで親と同じビルドをもう一度払っていた。
// `--failed` は子へは転送しない(DeviceMachineRunner.run が selected を絞ってから配る)ので
// ここでは検査しない —— このテストは「子の argv に何が乗るか」だけを固定する。

import XCTest
import FTCore
@testable import fleetest

final class DeviceMachineRunnerChildArgsTests: XCTestCase {

    private func args(host: String, reportDir: String? = nil) -> [String] {
        DeviceMachineRunner.childArgs(
            project: "E2E", host: host, profile: "p",
            deviceNames: ["iPhone-01"], deviceMachine: host,
            scenarios: ["Warm.up"], folders: [],
            noLPT: false, lptHistoryRuns: nil, performanceMode: false,
            forceLock: false, remoteDir: nil, remoteTimeout: nil,
            quiet: true, junitPath: nil, reportDir: reportDir)
    }

    /// ローカル子は親が既に払ったビルドを繰り返させない
    func testLocalChildGetsSkipBuild() {
        XCTAssertTrue(args(host: "local").contains("--skip-build"))
    }

    /// リモート子は自分のマシンでビルドしなければならないので付けない
    func testRemoteChildDoesNotGetSkipBuild() {
        XCTAssertFalse(args(host: "M1Ultra").contains("--skip-build"))
    }

    /// --report-dir はローカル子にだけ転送する(値も一緒に)
    func testLocalChildRelaysReportDir() {
        let a = args(host: "local", reportDir: "/tmp/custom-reports")
        guard let index = a.firstIndex(of: "--report-dir") else {
            XCTFail("--report-dir が無い: \(a)")
            return
        }
        XCTAssertEqual(a[a.index(after: index)], "/tmp/custom-reports")
    }

    /// リモート子へ --report-dir を渡すと、その子の `dispatchToRemoteHost` が明示的に拒否して
    /// ValidationError で落ちる(Fleetest.swift の RemoteDispatchFlagPolicy.rejected)ので、
    /// 転送してはいけない
    func testRemoteChildDoesNotRelayReportDir() {
        XCTAssertFalse(args(host: "M1Ultra", reportDir: "/tmp/custom-reports").contains("--report-dir"))
    }

    /// reportDir が nil のときはローカル子にも足さない(従来どおり既定の reports/ を使う)
    func testLocalChildOmitsReportDirWhenNil() {
        XCTAssertFalse(args(host: "local").contains("--report-dir"))
    }

    /// FleetRunner.buildArgs 由来の共通部分(--runner 等)はそのまま乗る —— 二重実装していないことの確認
    func testChildArgsStillCarriesTheSharedFleetRunnerArgs() {
        let a = args(host: "M1Ultra")
        guard let index = a.firstIndex(of: "--runner") else {
            XCTFail("--runner が無い: \(a)")
            return
        }
        XCTAssertEqual(a[a.index(after: index)], "M1Ultra")
    }
}
