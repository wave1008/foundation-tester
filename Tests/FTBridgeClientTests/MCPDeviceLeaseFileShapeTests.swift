// MCPDeviceLease は「1台1ファイル」だった頃、後から同じ鍵を触った別の生きたセッションが
// 先のセッションの印を上書きし、そのセッションの終了処理(removeAll)がファイルごと消して
// 先の生きた保持者を消していた(実害: ライブ操作が保持していた台へ、別の対話セッションの
// 終了処理を経由して stop-device が通ってしまった)。この一群は、いま「鍵 × pid」で1ファイル
// (`mcp-<鍵>@<pid>.lease`)になっていて、書き手が自分のファイルしか触らないことを固定する。
// RunLeaseTests.swift と同型: 実プロセス起動不要で、自プロセスの pid と launchd(1)を
// 「別々の生きたプロセス」として使う。

import XCTest
@testable import FTBridgeClient
import FTCore

final class MCPDeviceLeaseFileShapeTests: XCTestCase {
    let udid = "TEST-UDID-0000"
    /// 「別の生きているプロセス」の陽性対照。launchd(1)は常に生きている
    let otherLivePID: Int32 = 1

    func makeStateDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    /// **本命**: 2つの生きたセッションが同じ台を触っても、後発の終了処理は先発の印を巻き込まない。
    /// 「1台1ファイル」だった頃はここで holderPID が nil になっていた(B の removeAll が
    /// ファイルごと消していたため)
    func testRemoveAllByOneHolderDoesNotEraseAnotherLiveHolderOfTheSameKey() {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let a = otherLivePID
        let b = ProcessInfo.processInfo.processIdentifier

        MCPDeviceLease.write(stateDir: stateDir, key: udid, pid: a)
        MCPDeviceLease.write(stateDir: stateDir, key: udid, pid: b)
        MCPDeviceLease.removeAll(stateDir: stateDir, pid: b)

        XCTAssertEqual(MCPDeviceLease.holderPID(stateDir: stateDir, key: udid, excluding: []), a,
                       "B が終了しても A の印は残っていること")
    }

    /// writeAndWarnIfInUse は自分の (key, pid) しか書かない ―― 相手を書いたあとも
    /// 相手はまだ「使用中」として見える(以前は自分の書き込みが相手の印を上書きして消していた)
    func testWriteAndWarnIfInUseDoesNotEraseTheOtherHoldersLease() {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let other = otherLivePID
        let me = ProcessInfo.processInfo.processIdentifier

        MCPDeviceLease.write(stateDir: stateDir, key: udid, pid: other)
        let warning = MCPDeviceLease.writeAndWarnIfInUse(stateDir: stateDir, key: udid, pid: me)
        XCTAssertEqual(warning, "⚠️ another MCP session (pid \(other)) is driving this device too — the two"
            + " sessions move each other's screens, so refs and snapshots go stale under you."
            + " Drive another device, or finish one of the sessions.")
        // もう一度呼んでも(自分の印を書き直しても)相手はまだ見える ―― 上書きで消えていない
        XCTAssertEqual(MCPDeviceLease.writeAndWarnIfInUse(stateDir: stateDir, key: udid, pid: me), warning)
        XCTAssertEqual(MCPDeviceLease.holderPID(stateDir: stateDir, key: udid, excluding: [me]), other)
    }

    func testHolderPIDAndLiveHoldersPickTheSmallestPIDWhenSeveralHoldTheSameKey() {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let low = otherLivePID
        let high = ProcessInfo.processInfo.processIdentifier
        XCTAssertLessThan(low, high, "テストの前提(pid 1 が自プロセスより小さい)")

        MCPDeviceLease.write(stateDir: stateDir, key: udid, pid: high)
        MCPDeviceLease.write(stateDir: stateDir, key: udid, pid: low)

        XCTAssertEqual(MCPDeviceLease.holderPID(stateDir: stateDir, key: udid, excluding: []), low)
        XCTAssertEqual(MCPDeviceLease.liveHolders(stateDir: stateDir, excluding: []), [udid: low])
    }

    /// 旧形式(`@` 無し)のファイルは無視される(壊れない・誤って生きた保持者として拾わない)
    func testOldSingleFileFormatIsIgnoredNotMisread() throws {
        let stateDir = makeStateDir()
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let started = ProcessLiveness.startTime(pid) else {
            throw XCTSkip("この環境では自プロセスの開始時刻が読めない")
        }
        try "\(pid) \(Int(started.timeIntervalSince1970))".write(
            to: stateDir.appendingPathComponent("mcp-\(udid).lease"), atomically: true, encoding: .utf8)

        XCTAssertNil(MCPDeviceLease.parse(fileName: "mcp-\(udid).lease"))
        XCTAssertNil(MCPDeviceLease.holderPID(stateDir: stateDir, key: udid, excluding: []))
        XCTAssertTrue(MCPDeviceLease.liveHolders(stateDir: stateDir, excluding: []).isEmpty)
        // それでも isLeaseFile + holder(at:) を使う掃除(BridgeProvisioner.sweepStaleLeases)は
        // このファイルを従来どおり扱える(死んでいれば消す・生きていれば残す)
        XCTAssertTrue(MCPDeviceLease.isLeaseFile("mcp-\(udid).lease"))
        XCTAssertEqual(MCPDeviceLease.holder(at: stateDir.appendingPathComponent("mcp-\(udid).lease")), pid)
    }

    func testParseRoundTripsKeyAndPIDFromLeaseURL() {
        let url = MCPDeviceLease.leaseURL(stateDir: makeStateDir(), key: udid, pid: 4242)
        let parsed = MCPDeviceLease.parse(fileName: url.lastPathComponent)
        XCTAssertEqual(parsed?.key, udid)
        XCTAssertEqual(parsed?.pid, 4242)
    }

    func testParseRejectsNamesWithoutTheSeparatorOrAnEmptyKey() {
        XCTAssertNil(MCPDeviceLease.parse(fileName: "mcp-\(udid).lease"), "旧形式(区切り無し)")
        XCTAssertNil(MCPDeviceLease.parse(fileName: "mcp-@42.lease"), "空の鍵")
        XCTAssertNil(MCPDeviceLease.parse(fileName: "mcp-\(udid)@notapid.lease"), "pid が数字でない")
        XCTAssertNil(MCPDeviceLease.parse(fileName: "run-\(udid).lease"), "MCP 以外の lease")
    }

    /// removeAll はファイル名の pid だけを見る ―― 別鍵でも自分の pid の印は全部消える
    func testRemoveAllDropsEveryKeyThisPIDHoldsButNotOthers() {
        let stateDir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let me = ProcessInfo.processInfo.processIdentifier
        let other = otherLivePID

        MCPDeviceLease.write(stateDir: stateDir, key: "UA", pid: me)
        MCPDeviceLease.write(stateDir: stateDir, key: "UB", pid: me)
        MCPDeviceLease.write(stateDir: stateDir, key: "UC", pid: other)

        MCPDeviceLease.removeAll(stateDir: stateDir, pid: me)

        XCTAssertNil(MCPDeviceLease.holderPID(stateDir: stateDir, key: "UA", excluding: []))
        XCTAssertNil(MCPDeviceLease.holderPID(stateDir: stateDir, key: "UB", excluding: []))
        XCTAssertEqual(MCPDeviceLease.holderPID(stateDir: stateDir, key: "UC", excluding: []), other)
    }
}
