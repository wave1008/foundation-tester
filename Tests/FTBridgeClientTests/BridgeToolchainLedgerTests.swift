// BridgeToolchainLedger: 稼働中ブリッジが起動した時点の Xcode 指紋をポート台帳の隣に控える
// (成果物の指紋と比べてはいけない理由は Sources/FTBridgeClient/BridgeToolchainLedger.swift の doc)。
// **判定できないケースは必ず「一致しない」側に倒す**(ToolchainFingerprint と同じ規律)。
import XCTest
@testable import FTBridgeClient

final class BridgeToolchainLedgerTests: XCTestCase {

    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-bridge-toolchain-\(UUID().uuidString)/.fleetest")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir.deletingLastPathComponent())
    }

    func testRecordThenMatches() {
        BridgeToolchainLedger.record(stateDir: stateDir, port: 8123, toolchain: "Xcode 27.0 Build 27A1")
        XCTAssertTrue(BridgeToolchainLedger.matchesCurrent(
            stateDir: stateDir, port: 8123, current: "Xcode 27.0 Build 27A1"))
    }

    /// Xcode を替えた = 指紋が変わる → 再利用しない
    func testDifferentToolchainDoesNotMatch() {
        BridgeToolchainLedger.record(stateDir: stateDir, port: 8123, toolchain: "Xcode 27.0 Build 27A1")
        XCTAssertFalse(BridgeToolchainLedger.matchesCurrent(
            stateDir: stateDir, port: 8123, current: "Xcode 27.2 Build 27C1"))
    }

    /// 控えが無い(この変更より前に起動したブリッジ・別ポート)は不一致扱い(作り直す側)
    func testMissingRecordDoesNotMatch() {
        XCTAssertFalse(BridgeToolchainLedger.matchesCurrent(
            stateDir: stateDir, port: 8123, current: "Xcode 27.0"))
    }

    /// 読めない(壊れた・同名ディレクトリ)ときも不一致扱い
    func testUnreadableRecordDoesNotMatch() throws {
        let path = BridgeToolchainLedger.url(stateDir: stateDir, port: 8123)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertFalse(BridgeToolchainLedger.matchesCurrent(stateDir: stateDir, port: 8123, current: "Xcode 27.0"))
    }

    /// 現在値が取れない(xcodebuild が使えない等)ときも不一致扱い
    func testNilCurrentDoesNotMatch() {
        BridgeToolchainLedger.record(stateDir: stateDir, port: 8123, toolchain: "Xcode 27.0")
        XCTAssertFalse(BridgeToolchainLedger.matchesCurrent(stateDir: stateDir, port: 8123, current: nil))
    }

    /// 現在値が取れないときは書かない(空ファイルを残して誤って一致させない)
    func testRecordWithNilDoesNothing() {
        BridgeToolchainLedger.record(stateDir: stateDir, port: 8123, toolchain: nil)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: BridgeToolchainLedger.url(stateDir: stateDir, port: 8123).path))
    }

    /// ポートごとに独立(別ポートの控えを混同しない = hybrid の inapp/xcuitest 2 ポートを取り違えない)
    func testDifferentPortsAreIndependent() {
        BridgeToolchainLedger.record(stateDir: stateDir, port: 8123, toolchain: "Xcode 27.0")
        XCTAssertFalse(BridgeToolchainLedger.matchesCurrent(stateDir: stateDir, port: 8124, current: "Xcode 27.0"))
    }

    func testRemoveDeletesTheRecord() {
        BridgeToolchainLedger.record(stateDir: stateDir, port: 8123, toolchain: "Xcode 27.0")
        BridgeToolchainLedger.remove(stateDir: stateDir, port: 8123)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: BridgeToolchainLedger.url(stateDir: stateDir, port: 8123).path))
    }

    /// 保存側の末尾改行など空白差で不一致にしない(書き手と読み手がずれると毎回再ビルドになる)
    func testTrailingWhitespaceIsIgnored() throws {
        try "Xcode 27.0\n".write(to: BridgeToolchainLedger.url(stateDir: stateDir, port: 8123),
                                  atomically: true, encoding: .utf8)
        XCTAssertTrue(BridgeToolchainLedger.matchesCurrent(stateDir: stateDir, port: 8123, current: "Xcode 27.0"))
    }

    /// 親ディレクトリが無くても書ける
    func testRecordCreatesParentDirectory() {
        let nested = stateDir.appendingPathComponent("nested")
        BridgeToolchainLedger.record(stateDir: nested, port: 8123, toolchain: "Xcode 27.0")
        XCTAssertTrue(BridgeToolchainLedger.matchesCurrent(stateDir: nested, port: 8123, current: "Xcode 27.0"))
    }

    /// 仕分けの全組み合わせ。**リースがあるときは止めない**(他プロセスの run・MCP を壊さない)が、
    /// **黙っても使わない**(呼び手が1行言う)
    func testDecideKeepsLeasedBridgesButStillSpeaksUp() {
        XCTAssertEqual(BridgeToolchainLedger.decide(toolchainMatches: true, hasForeignLease: false), .reuse)
        XCTAssertEqual(BridgeToolchainLedger.decide(toolchainMatches: true, hasForeignLease: true), .reuse)
        XCTAssertEqual(BridgeToolchainLedger.decide(toolchainMatches: false, hasForeignLease: false), .restart)
        XCTAssertEqual(BridgeToolchainLedger.decide(toolchainMatches: false, hasForeignLease: true),
                       .warnAndReuse, "リースのある台は止めないが、黙って使わない")
    }
}
