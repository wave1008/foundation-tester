// sweepStuckStartingRunners の安全弁2つ: ①一度でも ready(BridgeReadyLedger)なら対象外
// ②宛先の台に生きた run-lease/MCP の印があれば対象外。どちらも欠けると、負荷で isBound の
// 300ms 判定が外れたとき、今も応答している長寿ブリッジを「起動しきれないランナー」と誤認して撃つ。
//
// 実プロセスは xcodebuild を起動できないので、`ps` が拾う**コマンド文字列だけ**を模す
// (isOurRunner/RunnerDestination は文字列の部分一致で判定する純粋関数なので、これで実際の
// production コードパスを踏める)。verdict(StartingRunnerVerdict.decide)まで到達させるには
// 実プロセスの生存時間が起動予算(180秒)を超えている必要があり単体テストでは作れないため、
// ここで確かめるのは「verdict に届く前にこの2つのガードで止まること」まで
// (verdict 自体は StartingRunnerVerdictTests が純粋関数として固定する)。

import XCTest
@testable import FTBridgeClient

/// `ps -ww -p <pid> -o command=` に狙った argv を含ませるためだけのダミー常駐プロセス。
/// `/usr/bin/yes` は任意の引数を(意味を解釈せず)繰り返し出力し続けるだけなので、
/// 実xcodebuildの `-destination …` 引数列をそのまま argv として渡せる
/// (`/bin/sh -c "… # marker"` は単一コマンドの sh がその場で exec に化けてコメントごと消え、
/// argv に残らない —— 実測で確認済み)
private final class FakeRunnerProcess {
    let pid: Int32
    private let process: Process

    init(argv: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        process.arguments = argv
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        self.pid = process.processIdentifier
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}

final class StuckStartingRunnerOwnershipTests: XCTestCase {

    private var repoRoot: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("stuck-ownership-\(UUID().uuidString)")
        stateDir = repoRoot.appendingPathComponent(".fleetest")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func writePidFile(port: UInt16, pid: Int32) throws {
        try String(pid).write(to: stateDir.appendingPathComponent("bridge-\(port).pid"),
                              atomically: true, encoding: .utf8)
    }

    /// ready 印があるポートは、たとえ誰も listen していなくても(= isBound/connectProbe が
    /// 「refused」を返す形でも)対象外
    func testReadyMarkedRunnerIsNeverSwept() throws {
        let port = try TestPorts.withNoListener()
        let runner = try FakeRunnerProcess(argv: ["FleetestRunner-\(port).xctestrun"])
        defer { runner.stop() }
        try writePidFile(port: port, pid: runner.pid)
        BridgeReadyLedger.mark(stateDir: stateDir, port: port)

        var logs: [String] = []
        StaleLedgerSweep.sweepStuckStartingRunners(repoRoot: repoRoot, log: { logs.append($0) })

        XCTAssertTrue(logs.isEmpty, "ready 印のあるランナーを撃っている: \(logs)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stateDir.appendingPathComponent("bridge-\(port).pid").path))
    }

    /// 宛先(RunnerDestination)に生きた run-lease があれば、ready 印が無くても対象外
    func testRunnerWithALiveRunLeaseOnItsDeviceIsLeftAlone() throws {
        let port = try TestPorts.withNoListener()
        let udid = "12345678-1234-1234-1234-123456789ABC"
        let runner = try FakeRunnerProcess(argv: [
            "FleetestRunner-\(port).xctestrun", "-destination", "platform=iOS Simulator,id=\(udid)",
        ])
        defer { runner.stop() }
        try writePidFile(port: port, pid: runner.pid)
        // 保持者は生きていればよい(このテストプロセス自身の pid を使う)
        RunLease.write(stateDir: stateDir, key: udid, pid: ProcessInfo.processInfo.processIdentifier)
        defer { RunLease.remove(stateDir: stateDir, key: udid) }

        var logs: [String] = []
        StaleLedgerSweep.sweepStuckStartingRunners(repoRoot: repoRoot, log: { logs.append($0) })

        XCTAssertTrue(logs.contains { $0.contains("port \(port)") && $0.contains("active run") },
                     "run-lease のある台のランナーを名指しで見逃していない: \(logs)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stateDir.appendingPathComponent("bridge-\(port).pid").path))
    }

    /// 宛先に生きた MCP の印(mcp-<udid>.lease)があっても同様に対象外
    func testRunnerWithALiveMCPLeaseOnItsDeviceIsLeftAlone() throws {
        let port = try TestPorts.withNoListener()
        let udid = "87654321-4321-4321-4321-CBA987654321"
        let runner = try FakeRunnerProcess(argv: [
            "FleetestRunner-\(port).xctestrun", "-destination", "platform=iOS Simulator,id=\(udid)",
        ])
        defer { runner.stop() }
        try writePidFile(port: port, pid: runner.pid)
        MCPDeviceLease.write(stateDir: stateDir, key: udid, pid: ProcessInfo.processInfo.processIdentifier)

        var logs: [String] = []
        StaleLedgerSweep.sweepStuckStartingRunners(repoRoot: repoRoot, log: { logs.append($0) })

        XCTAssertTrue(logs.contains { $0.contains("port \(port)") },
                     "MCP の印がある台のランナーを見逃していない: \(logs)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stateDir.appendingPathComponent("bridge-\(port).pid").path))
    }
}
