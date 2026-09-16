// 生きたランナーの居ないポートの結果の束を消す(BridgeLauncher.sweepOrphanResultBundles)。
// 起動時の掃除は同じポートで起動し直したときしか消さないので、復活のたびにポートが変わると
// 束が誰にも消されず残った(2026-09-16: 23 束・4.1GB)。

import XCTest
@testable import FTBridgeClient

final class BridgeResultBundleSweepTests: XCTestCase {

    func testPortIsReadFromBothNameForms() {
        XCTAssertEqual(BridgeLauncher.resultBundlePort("bridge-8124-1789546342822.xcresult"), 8124)
        XCTAssertEqual(BridgeLauncher.resultBundlePort("bridge-8199.xcresult"), 8199)
    }

    func testUnrelatedNamesAreNotRead() {
        XCTAssertNil(BridgeLauncher.resultBundlePort("bridge-8124.log"))
        XCTAssertNil(BridgeLauncher.resultBundlePort("other-8124.xcresult"))
        XCTAssertNil(BridgeLauncher.resultBundlePort("bridge-abc.xcresult"))
        XCTAssertNil(BridgeLauncher.resultBundlePort(".DS_Store"))
    }

    func testOnlyBundlesOfPortsWithoutALiveRunnerAreOrphans() {
        let names = ["bridge-8123-1.xcresult", "bridge-8125-2.xcresult", "bridge-8199.xcresult",
                     "bridge-8123-0.xcresult", "notes.txt"]
        XCTAssertEqual(BridgeLauncher.orphanResultBundleNames(names, livePorts: [8123]),
                       ["bridge-8125-2.xcresult", "bridge-8199.xcresult"])
    }

    func testNothingIsAnOrphanWhenEveryPortIsLive() {
        XCTAssertEqual(BridgeLauncher.orphanResultBundleNames(
            ["bridge-8123-1.xcresult", "bridge-8125-2.xcresult"], livePorts: [8123, 8125]), [])
    }

    /// 実ファイルで: `.pid` の残っているポートの束は残し、それ以外を消す
    func testSweepRemovesOnlyOrphanBundlesOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftxcresult-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent(".fleetest")
        let bundles = state.appendingPathComponent("xcresult")
        try FileManager.default.createDirectory(at: bundles, withIntermediateDirectories: true)
        try "123".write(to: state.appendingPathComponent("bridge-8123.pid"), atomically: true, encoding: .utf8)
        for name in ["bridge-8123-1.xcresult", "bridge-8125-2.xcresult"] {
            try FileManager.default.createDirectory(
                at: bundles.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        BridgeLauncher.sweepOrphanResultBundles(repoRoot: root)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bundles.path),
                       ["bridge-8123-1.xcresult"])
    }
}
