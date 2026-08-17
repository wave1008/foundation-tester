// 同一リモートホストへの二重ディスパッチ防止ロック(docs/remote-runner.md §5)の純粋ロジック。
// ssh 実行は Sources/ftester/RemoteRunDispatcher.swift 側(e2e に残す)。

import Foundation
import XCTest
@testable import FTCore

final class RemoteDispatchLockTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_755_000_000)  // 2025-08-12T12:00:00Z (date -u -r)

    // MARK: - RemoteDispatchLockInfo.now

    func testNowFormatsAcquiredAtAsUTCISO8601() {
        let info = RemoteDispatchLockInfo.now(issuerHost: "wave1008-mbp", pid: 4242, date: fixedDate)
        XCTAssertEqual(info.acquiredAt, "2025-08-12T12:00:00Z")
        XCTAssertEqual(info.issuerHost, "wave1008-mbp")
        XCTAssertEqual(info.pid, 4242)
    }

    // MARK: - encode/decode round trip

    func testEncodeDecodeRoundTrips() {
        let info = RemoteDispatchLockInfo(issuerHost: "wave1008-mbp", pid: 4242, acquiredAt: "2025-08-12T13:20:00Z")
        let encoded = try? XCTUnwrap(RemoteDispatchLock.encode(info))
        XCTAssertEqual(RemoteDispatchLock.decode(encoded!), info)
    }

    /// sortedKeys でエンコードするので JSON のキー順が固定される(ssh コマンド文字列の
    /// 完全一致テストのため。値が変わればテキストも決定的に変わる)
    func testEncodeProducesSortedKeys() throws {
        let info = RemoteDispatchLockInfo(issuerHost: "h", pid: 1, acquiredAt: "2025-08-12T13:20:00Z")
        let encoded = try XCTUnwrap(RemoteDispatchLock.encode(info))
        XCTAssertEqual(encoded,
            "{\"acquiredAt\":\"2025-08-12T13:20:00Z\",\"issuerHost\":\"h\",\"pid\":1}")
    }

    func testDecodeReturnsNilForGarbage() {
        XCTAssertNil(RemoteDispatchLock.decode("not json"))
    }

    func testDecodeReturnsNilForEmptyString() {
        XCTAssertNil(RemoteDispatchLock.decode(""))
    }

    // MARK: - paths

    func testLockDirPathIsUnderDotFtester() {
        XCTAssertEqual(RemoteDispatchLock.lockDirPath(base: "/Users/tester/ftester-runner"),
                       "/Users/tester/ftester-runner/.ftester/dispatch.lock")
    }

    func testInfoFilePathIsInsideLockDir() {
        XCTAssertEqual(RemoteDispatchLock.infoFilePath(base: "/Users/tester/ftester-runner"),
                       "/Users/tester/ftester-runner/.ftester/dispatch.lock/info.json")
    }

    // MARK: - heldMessage

    func testHeldMessageIncludesIssuerPidAndTimestamp() {
        let info = RemoteDispatchLockInfo(issuerHost: "wave1008-mbp", pid: 4242, acquiredAt: "2025-08-12T13:20:00Z")
        let message = RemoteDispatchLock.heldMessage(info)
        XCTAssertTrue(message.contains("wave1008-mbp"), message)
        XCTAssertTrue(message.contains("4242"), message)
        XCTAssertTrue(message.contains("2025-08-12T13:20:00Z"), message)
        XCTAssertTrue(message.contains("--force-lock"), message)
    }

    func testHeldMessageHandlesUnreadableInfo() {
        let message = RemoteDispatchLock.heldMessage(nil)
        XCTAssertTrue(message.contains("holder unknown"), message)
        XCTAssertTrue(message.contains("--force-lock"), message)
    }

    // MARK: - ssh コマンド文字列(完全一致で固定)

    private let sampleInfo = RemoteDispatchLockInfo(issuerHost: "h", pid: 1, acquiredAt: "2025-08-12T13:20:00Z")

    func testAcquireCommandExactText() {
        let command = RemoteDispatchLock.acquireCommand(base: "/Users/tester/ftester-runner", info: sampleInfo)
        XCTAssertEqual(command,
            "mkdir -p '/Users/tester/ftester-runner/.ftester'"
            + " && mkdir '/Users/tester/ftester-runner/.ftester/dispatch.lock' 2>/dev/null"
            + " && printf '%s' '{\"acquiredAt\":\"2025-08-12T13:20:00Z\",\"issuerHost\":\"h\",\"pid\":1}'"
            + " > '/Users/tester/ftester-runner/.ftester/dispatch.lock/info.json'")
    }

    func testForceAcquireCommandRemovesLockDirFirst() {
        let command = RemoteDispatchLock.forceAcquireCommand(base: "/Users/tester/ftester-runner", info: sampleInfo)
        XCTAssertEqual(command,
            "rm -rf '/Users/tester/ftester-runner/.ftester/dispatch.lock'"
            + " && \(RemoteDispatchLock.acquireCommand(base: "/Users/tester/ftester-runner", info: sampleInfo))")
    }

    func testReadCommandExactText() {
        XCTAssertEqual(RemoteDispatchLock.readCommand(base: "/Users/tester/ftester-runner"),
            "cat '/Users/tester/ftester-runner/.ftester/dispatch.lock/info.json' 2>/dev/null || true")
    }

    func testReleaseCommandExactText() {
        XCTAssertEqual(RemoteDispatchLock.releaseCommand(base: "/Users/tester/ftester-runner"),
            "rm -rf '/Users/tester/ftester-runner/.ftester/dispatch.lock'")
    }

    /// `$` とバッククォートはシングルクォート内では展開されない(RemoteShell.quote の契約 ——
    /// POSIX sh はシングルクォート内を完全に literal として扱う)。base に紛れ込んでも
    /// (RemoteLayout.validateBase は本来弾くが、ロック側は防御的にも壊れないことを確認する)
    /// コマンド置換を起こす形にならない = 生成結果全体がシングルクォートで包まれたままである
    func testAcquireCommandNeutralizesDollarAndBacktickInBase() {
        let command = RemoteDispatchLock.acquireCommand(base: "/tmp/$(whoami)/`id`", info: sampleInfo)
        XCTAssertEqual(command,
            "mkdir -p '/tmp/$(whoami)/`id`/.ftester'"
            + " && mkdir '/tmp/$(whoami)/`id`/.ftester/dispatch.lock' 2>/dev/null"
            + " && printf '%s' '{\"acquiredAt\":\"2025-08-12T13:20:00Z\",\"issuerHost\":\"h\",\"pid\":1}'"
            + " > '/tmp/$(whoami)/`id`/.ftester/dispatch.lock/info.json'")
    }

    /// issuerHost にシングルクォートが混じっても壊れない(RemoteShell.quote が '\'' で無害化)
    func testAcquireCommandEscapesSingleQuoteInIssuerHost() throws {
        let info = RemoteDispatchLockInfo(issuerHost: "o'brien-mbp", pid: 1, acquiredAt: "2025-08-12T13:20:00Z")
        let payload = try XCTUnwrap(RemoteDispatchLock.encode(info))
        let command = RemoteDispatchLock.acquireCommand(base: "/Users/tester/ftester-runner", info: info)
        XCTAssertTrue(command.contains(RemoteShell.quote(payload)), command)
    }
}
