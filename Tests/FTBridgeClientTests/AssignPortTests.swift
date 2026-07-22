// BridgeProvisioner.assignPort の採番ロジック(pid ファイル存在=使用中とみなす)を
// デバイス不要で検証する。並列 device-up の bindFailed(48) 競合の中核ロジック。

import XCTest
@testable import FTBridgeClient

final class AssignPortTests: XCTestCase {
    private var repoRoot: URL!

    override func setUpWithError() throws {
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftbridge-assignport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent(".ftester"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func writePidFile(port: UInt16) throws {
        try "12345".write(
            to: repoRoot.appendingPathComponent(".ftester/bridge-\(port).pid"),
            atomically: true, encoding: .utf8)
    }

    private func writeInAppFile(port: UInt16) throws {
        try "11111111-2222-3333-4444-555555555555 com.example.app".write(
            to: repoRoot.appendingPathComponent(".ftester/bridge-\(port).inapp"),
            atomically: true, encoding: .utf8)
    }

    func testPrefersUnusedPreferred() throws {
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130)
        var used: Set<UInt16> = []
        XCTAssertEqual(try provisioner.assignPort(preferred: 8127, used: &used), 8127)
        XCTAssertTrue(used.contains(8127))
    }

    func testSkipsPreferredWhenUsedAndFallsToRangeHead() throws {
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130)
        var used: Set<UInt16> = [8123]
        // preferred 8123 は used のため範囲先頭の空き 8124 へ
        XCTAssertEqual(try provisioner.assignPort(preferred: 8123, used: &used), 8124)
    }

    func testSkipsPreferredWithStalePidFile() throws {
        try writePidFile(port: 8127)
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130)
        var used: Set<UInt16> = []
        let port = try provisioner.assignPort(preferred: 8127, used: &used)
        XCTAssertNotEqual(port, 8127, "pid ファイルのある preferred は honor しない")
        XCTAssertEqual(port, 8123, "自動採番で範囲先頭の空きへ")
    }

    func testPreferredWithPidFileHonoredWhenIgnored() throws {
        try writePidFile(port: 8127)
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130)
        var used: Set<UInt16> = []
        // 同ポート再起動(ignoringPidFileFor)なら pid ファイルがあっても preferred を honor する
        XCTAssertEqual(
            try provisioner.assignPort(preferred: 8127, used: &used, ignoringPidFileFor: 8127), 8127)
    }

    func testSkipsPortsWithPidFile() throws {
        try writePidFile(port: 8123)
        try writePidFile(port: 8124)
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130)
        var used: Set<UInt16> = []
        XCTAssertEqual(try provisioner.assignPort(preferred: nil, used: &used), 8125,
                       "pid ファイルのある 8123/8124 はスキップされる")
    }

    func testIgnoringPidFileForReusesThatPort() throws {
        try writePidFile(port: 8123)
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130)
        var used: Set<UInt16> = []
        // 8123 は pid ファイルがあるが ignoringPidFileFor で空き扱いになる(同ポート再起動用)
        XCTAssertEqual(
            try provisioner.assignPort(preferred: nil, used: &used, ignoringPidFileFor: 8123), 8123)
    }

    func testUsedSetPreventsSameAssignmentTwice() throws {
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130)
        var used: Set<UInt16> = []
        let first = try provisioner.assignPort(preferred: nil, used: &used)
        let second = try provisioner.assignPort(preferred: nil, used: &used)
        XCTAssertNotEqual(first, second, "used が引き継がれ同一ポートを二度返さない")
    }

    func testNoFreePortThrows() throws {
        for port: UInt16 in 8123...8125 { try writePidFile(port: port) }
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8125)
        var used: Set<UInt16> = []
        XCTAssertThrowsError(try provisioner.assignPort(preferred: nil, used: &used)) { error in
            guard case BridgeProvisionerError.noFreePort = error else {
                return XCTFail("noFreePort を期待: \(error)")
            }
        }
    }

    func testInAppOnlyPortsAreDeferred() throws {
        try writeInAppFile(port: 8123)
        try writeInAppFile(port: 8124)
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130)
        var used: Set<UInt16> = []
        XCTAssertEqual(try provisioner.assignPort(preferred: nil, used: &used), 8125,
                       ".inapp のある 8123/8124 は後回しにされる")
    }

    func testInAppPortsUsedWhenAllPortsHaveInApp() throws {
        for port: UInt16 in 8123...8125 { try writeInAppFile(port: port) }
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8125)
        var used: Set<UInt16> = []
        // 全ポートに .inapp が残っていても枯渇せず(.inapp のみの)最初のポートを返す
        XCTAssertEqual(try provisioner.assignPort(preferred: nil, used: &used), 8123)
    }

    func testPidFileExcludesPortEvenWithInApp() throws {
        try writePidFile(port: 8123)
        try writeInAppFile(port: 8123)
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130)
        var used: Set<UInt16> = []
        // .pid のあるポートは .inapp の有無に関係なく常に除外される
        XCTAssertEqual(try provisioner.assignPort(preferred: nil, used: &used), 8124)
    }

    func testStopIfOwnedBridgeNotFoundForUnusedPort() throws {
        // 誰も LISTEN していない高番ポート。lsof が見つけられなければ .notFound
        let outcome = PortHolder.stopIfOwnedBridge(
            port: 59_999, stateDir: repoRoot.appendingPathComponent(".ftester"),
            derivedDataPath: repoRoot.appendingPathComponent(".ftester/DerivedData"))
        guard case .notFound = outcome else {
            return XCTFail(".notFound を期待: \(outcome)")
        }
    }
}
