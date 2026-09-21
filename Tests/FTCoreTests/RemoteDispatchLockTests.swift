// 同一リモートホストへの二重ディスパッチ防止ロック(docs/remote-runner.md §5)の純粋ロジック。
// ssh 実行は Sources/fleetest/RemoteRunDispatcher.swift 側(e2e に残す)。

import Foundation
import XCTest
@testable import FTCore
import FTRemote

final class RemoteDispatchLockTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_755_000_000)  // 2025-08-12T12:00:00Z (date -u -r)

    // MARK: - RemoteDispatchLockInfo.now

    func testNowFormatsAcquiredAtAsUTCISO8601() {
        let info = RemoteDispatchLockInfo.now(issuerHost: "wave1008-mbp", pid: 4242, date: fixedDate)
        XCTAssertEqual(info.acquiredAt, "2025-08-12T12:00:00Z")
        XCTAssertEqual(info.issuerHost, "wave1008-mbp")
        XCTAssertEqual(info.pid, 4242)
        XCTAssertNil(info.issuer)
    }

    func testNowSetsIssuerWhenGiven() {
        let info = RemoteDispatchLockInfo.now(issuerHost: "wave1008-mbp", pid: 4242,
                                              issuer: "wave8san@wave1008-mbp", date: fixedDate)
        XCTAssertEqual(info.issuer, "wave8san@wave1008-mbp")
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

    /// issuer 付きの encode(_:) は sortedKeys で "issuer" < "issuerHost" の順に来る
    func testEncodeWithIssuerProducesSortedKeysIncludingIssuer() throws {
        let info = RemoteDispatchLockInfo(issuerHost: "h", pid: 1,
                                          acquiredAt: "2025-08-12T13:20:00Z", issuer: "alice@h")
        let encoded = try XCTUnwrap(RemoteDispatchLock.encode(info))
        XCTAssertEqual(encoded,
            "{\"acquiredAt\":\"2025-08-12T13:20:00Z\",\"issuer\":\"alice@h\","
            + "\"issuerHost\":\"h\",\"pid\":1}")
    }

    /// 旧 info.json(issuer キーが無い)を素朴な Optional Codable がそのまま decode できること
    func testDecodeOldInfoJsonWithoutIssuerKey() throws {
        let raw = "{\"acquiredAt\":\"2025-08-12T13:20:00Z\",\"issuerHost\":\"h\",\"pid\":1}"
        let decoded = try XCTUnwrap(RemoteDispatchLock.decode(raw))
        XCTAssertNil(decoded.issuer)
        XCTAssertEqual(decoded.issuerHost, "h")
        XCTAssertEqual(decoded.pid, 1)
    }

    // MARK: - paths

    /// **置き場はホームの `.fleetest/`**(`<base>` ではない)。完全一致で固定する
    func testLockDirPathIsUnderTheMachineGlobalDotFleetest() {
        XCTAssertEqual(RemoteDispatchLock.lockDirPath(home: "/Users/tester"),
                       "/Users/tester/.fleetest/dispatch.lock")
    }

    func testInfoFilePathIsInsideLockDir() {
        XCTAssertEqual(RemoteDispatchLock.infoFilePath(home: "/Users/tester"),
                       "/Users/tester/.fleetest/dispatch.lock/info.json")
    }

    /// **この変更の目的そのもの**: 同じ Mac に `<base>` を2つ作ってもロックは1本。
    /// 2つの run が取り合うのは同じ CoreSimulatorService と同じ loopback のポートなので、
    /// base ごとにロックが分かれると排他が成立せず黙って壊れる
    func testTwoBasesOnTheSameMachineShareOneLock() {
        let first = RemoteLayout(base: "/Users/tester/fleetest-runner", issuer: "alice",
                                 home: "/Users/tester")
        let second = RemoteLayout(base: "/Volumes/ssd/other-runner", issuer: "bob",
                                  home: "/Users/tester")
        XCTAssertEqual(RemoteDispatchLock.lockDirPath(home: first.home),
                       RemoteDispatchLock.lockDirPath(home: second.home))
        XCTAssertEqual(RemoteDispatchQueue.directory(home: first.home),
                       RemoteDispatchQueue.directory(home: second.home))
    }

    /// 逆向き: **ホームが違えば別のロック**(同じ base を別の Mac で使っても混ざらない)
    func testDifferentHomesAreDifferentLocks() {
        XCTAssertNotEqual(RemoteDispatchLock.lockDirPath(home: "/Users/tester"),
                          RemoteDispatchLock.lockDirPath(home: "/Users/other"))
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

    /// issuer 付き info は「started by <issuer>」を先頭に出し、issuerHost/pid は "(from X, pid N)" で残す
    func testHeldMessageWithIssuerIncludesIssuerAndStillIncludesHostAndPid() {
        let info = RemoteDispatchLockInfo(issuerHost: "wave1008-mbp", pid: 4242,
                                          acquiredAt: "2025-08-12T13:20:00Z", issuer: "alice@wave1008-mbp")
        let message = RemoteDispatchLock.heldMessage(info)
        XCTAssertTrue(message.contains("started by alice@wave1008-mbp"), message)
        XCTAssertTrue(message.contains("(from wave1008-mbp, pid 4242)"), message)
        XCTAssertTrue(message.contains("2025-08-12T13:20:00Z"), message)
    }

    /// issuer nil の既存挙動は1バイトも変わらない(旧 info.json の表示互換)
    func testHeldMessageWithoutIssuerIsByteIdenticalToPriorText() {
        let info = RemoteDispatchLockInfo(issuerHost: "wave1008-mbp", pid: 4242, acquiredAt: "2025-08-12T13:20:00Z")
        let message = RemoteDispatchLock.heldMessage(info)
        XCTAssertEqual(message,
            "another dispatch is already running on this remote host"
            + " (started by wave1008-mbp (pid 4242) at 2025-08-12T13:20:00Z)"
            + " — wait for it to finish, run `fleetest remote unlock --runner <machine>` if it is your own"
            + " dispatch that died, or pass --force-lock if it is stuck"
            + " (docs/remote-runner.md §5)")
    }

    /// **手元のロックは別の文言**(逃げ道が違う)。`remote unlock --runner` は案内しない ——
    /// 手元の死んだロックは次の run が pid の生死で自分で回収するので、あの案内は誤りを教える
    func testHeldMessageForThisMachineDoesNotSuggestRemoteUnlock() {
        let info = RemoteDispatchLockInfo(issuerHost: "wave1008-mbp", pid: 4242,
                                          acquiredAt: "2025-08-12T13:20:00Z", issuer: "alice")
        let message = RemoteDispatchLock.heldMessage(info, scope: .thisMachine)
        XCTAssertTrue(message.contains("another fleetest run is already running on this Mac"), message)
        XCTAssertTrue(message.contains("started by alice (from wave1008-mbp, pid 4242)"), message)
        XCTAssertTrue(message.contains("--wait-lock"), message)
        XCTAssertFalse(message.contains("remote unlock"), message)
        XCTAssertFalse(message.contains("on this remote host"), message)
    }

    // MARK: - alignHeldMessage

    func testAlignHeldMessageIncludesIssuerPidAndTimestamp() {
        let info = RemoteDispatchLockInfo(issuerHost: "wave1008-mbp", pid: 4242, acquiredAt: "2025-08-12T13:20:00Z")
        let message = RemoteDispatchLock.alignHeldMessage(info)
        XCTAssertTrue(message.contains("wave1008-mbp"), message)
        XCTAssertTrue(message.contains("4242"), message)
        XCTAssertTrue(message.contains("2025-08-12T13:20:00Z"), message)
    }

    func testAlignHeldMessageWithIssuerIncludesIssuerAndStillIncludesHostAndPid() {
        let info = RemoteDispatchLockInfo(issuerHost: "wave1008-mbp", pid: 4242,
                                          acquiredAt: "2025-08-12T13:20:00Z", issuer: "alice@wave1008-mbp")
        let message = RemoteDispatchLock.alignHeldMessage(info)
        XCTAssertTrue(message.contains("started by alice@wave1008-mbp"), message)
        XCTAssertTrue(message.contains("(from wave1008-mbp, pid 4242)"), message)
    }

    func testAlignHeldMessageHandlesUnreadableInfo() {
        let message = RemoteDispatchLock.alignHeldMessage(nil)
        XCTAssertTrue(message.contains("holder unknown"), message)
    }

    func testAlignHeldMessageDoesNotMentionForceLock() {
        let info = RemoteDispatchLockInfo(issuerHost: "wave1008-mbp", pid: 4242, acquiredAt: "2025-08-12T13:20:00Z")
        XCTAssertFalse(RemoteDispatchLock.alignHeldMessage(info).contains("--force-lock"))
        XCTAssertFalse(RemoteDispatchLock.alignHeldMessage(nil).contains("--force-lock"))
    }

    // MARK: - ssh コマンド文字列(完全一致で固定)

    private let sampleInfo = RemoteDispatchLockInfo(issuerHost: "h", pid: 1, acquiredAt: "2025-08-12T13:20:00Z")

    func testAcquireCommandExactText() {
        let command = RemoteDispatchLock.acquireCommand(home: "/Users/tester", info: sampleInfo)
        XCTAssertEqual(command,
            "mkdir -p '/Users/tester/.fleetest'"
            + " && mkdir '/Users/tester/.fleetest/dispatch.lock' 2>/dev/null"
            + " && printf '%s' '{\"acquiredAt\":\"2025-08-12T13:20:00Z\",\"issuerHost\":\"h\",\"pid\":1}'"
            + " > '/Users/tester/.fleetest/dispatch.lock/info.json'")
    }

    func testForceAcquireCommandRemovesLockDirFirst() {
        let command = RemoteDispatchLock.forceAcquireCommand(home: "/Users/tester", info: sampleInfo)
        XCTAssertEqual(command,
            "rm -rf '/Users/tester/.fleetest/dispatch.lock'"
            + " && \(RemoteDispatchLock.acquireCommand(home: "/Users/tester", info: sampleInfo))")
    }

    func testReadCommandExactText() {
        XCTAssertEqual(RemoteDispatchLock.readCommand(home: "/Users/tester"),
            "cat '/Users/tester/.fleetest/dispatch.lock/info.json' 2>/dev/null || true")
    }

    func testReleaseCommandExactText() {
        XCTAssertEqual(RemoteDispatchLock.releaseCommand(home: "/Users/tester"),
            "rm -rf '/Users/tester/.fleetest/dispatch.lock'")
    }

    /// `$` とバッククォートはシングルクォート内では展開されない(RemoteShell.quote の契約 ——
    /// POSIX sh はシングルクォート内を完全に literal として扱う)。base に紛れ込んでも
    /// (home がそういう値になることは無いが、ロック側は防御的にも壊れないことを確認する)
    /// コマンド置換を起こす形にならない = 生成結果全体がシングルクォートで包まれたままである
    func testAcquireCommandNeutralizesDollarAndBacktickInHome() {
        let command = RemoteDispatchLock.acquireCommand(home: "/tmp/$(whoami)/`id`", info: sampleInfo)
        XCTAssertEqual(command,
            "mkdir -p '/tmp/$(whoami)/`id`/.fleetest'"
            + " && mkdir '/tmp/$(whoami)/`id`/.fleetest/dispatch.lock' 2>/dev/null"
            + " && printf '%s' '{\"acquiredAt\":\"2025-08-12T13:20:00Z\",\"issuerHost\":\"h\",\"pid\":1}'"
            + " > '/tmp/$(whoami)/`id`/.fleetest/dispatch.lock/info.json'")
    }

    /// issuerHost にシングルクォートが混じっても壊れない(RemoteShell.quote が '\'' で無害化)
    func testAcquireCommandEscapesSingleQuoteInIssuerHost() throws {
        let info = RemoteDispatchLockInfo(issuerHost: "o'brien-mbp", pid: 1, acquiredAt: "2025-08-12T13:20:00Z")
        let payload = try XCTUnwrap(RemoteDispatchLock.encode(info))
        let command = RemoteDispatchLock.acquireCommand(home: "/Users/tester", info: info)
        XCTAssertTrue(command.contains(RemoteShell.quote(payload)), command)
    }
}

/// `remote unlock` の判定(RemoteDispatchUnlock)。自分の死んだディスパッチだけを外す
final class RemoteDispatchUnlockTests: XCTestCase {
    private let mine = RemoteDispatchLockInfo(issuerHost: "my-mac", pid: 4242,
                                              acquiredAt: "2026-08-23T12:00:23Z", issuer: "wave1008")

    func testAbsentLockIsNothingToDo() {
        XCTAssertEqual(RemoteDispatchUnlock.decide(probe: .absent, myIssuer: "wave1008", myHost: "my-mac",
                                                   pidAlive: { _ in true }), .nothingToDo)
    }

    func testUnreadableInfoIsRefused() {
        guard case .refuse = RemoteDispatchUnlock.decide(probe: .held(nil), myIssuer: "wave1008",
                                                         myHost: "my-mac", pidAlive: { _ in false })
        else { return XCTFail("unreadable info must not be released") }
    }

    func testOtherIssuerIsRefusedEvenIfPidIsDead() {
        let theirs = RemoteDispatchLockInfo(issuerHost: "my-mac", pid: 1, acquiredAt: "x", issuer: "alice")
        guard case .refuse(let reason) = RemoteDispatchUnlock.decide(
            probe: .held(theirs), myIssuer: "wave1008", myHost: "my-mac", pidAlive: { _ in false })
        else { return XCTFail("another issuer's lock must not be released") }
        XCTAssertTrue(reason.contains("alice"), reason)
    }

    func testLegacyInfoWithoutIssuerIsRefused() {
        let legacy = RemoteDispatchLockInfo(issuerHost: "my-mac", pid: 1, acquiredAt: "x")
        guard case .refuse = RemoteDispatchUnlock.decide(
            probe: .held(legacy), myIssuer: "wave1008", myHost: "my-mac", pidAlive: { _ in false })
        else { return XCTFail("a lock with no issuer cannot be proven to be mine") }
    }

    func testMyLiveDispatchOnThisMachineIsRefused() {
        guard case .refuse(let reason) = RemoteDispatchUnlock.decide(
            probe: .held(mine), myIssuer: "wave1008", myHost: "my-mac", pidAlive: { $0 == 4242 })
        else { return XCTFail("a running dispatch of mine must not lose its lock") }
        XCTAssertTrue(reason.contains("4242"), reason)
    }

    /// ProcessInfo.hostName(小文字)と `hostname`(大文字)が同じ機械で食い違う実測に合わせる
    func testHostComparisonIsCaseInsensitive() {
        guard case .refuse = RemoteDispatchUnlock.decide(
            probe: .held(mine), myIssuer: "wave1008", myHost: "MY-MAC", pidAlive: { $0 == 4242 })
        else { return XCTFail("the same machine spelled in another case must still see the live pid") }
    }

    func testMyDeadDispatchOnThisMachineIsReleased() {
        guard case .release = RemoteDispatchUnlock.decide(
            probe: .held(mine), myIssuer: "wave1008", myHost: "my-mac", pidAlive: { _ in false })
        else { return XCTFail("my dead dispatch's lock must be released") }
    }

    // MARK: - decideAutomaticSweep(モニター起動時の自動掃除。手動 unlock より保守側)

    /// 自動掃除が外してよいのは「この機械の自分の pid が死んでいる」ときだけ
    func testSweepReleasesMyDeadDispatchOnThisMachine() {
        guard case .release = RemoteDispatchUnlock.decideAutomaticSweep(
            probe: .held(mine), myIssuer: "wave1008", myHost: "my-mac", pidAlive: { _ in false })
        else { return XCTFail("the sweep must release my dead dispatch's lock") }
    }

    /// **手動 unlock との差分**: 別の機械から発行した自分のロックは自動では触らない
    /// (pid の生死を確かめられず、別 Mac の生きている run を殺し得る)
    func testSweepRefusesMyLockFromAnotherMachine() {
        guard case .refuse(let reason) = RemoteDispatchUnlock.decideAutomaticSweep(
            probe: .held(mine), myIssuer: "wave1008", myHost: "other-mac", pidAlive: { _ in false })
        else { return XCTFail("the sweep must not release a lock it cannot prove dead") }
        XCTAssertTrue(reason.contains("my-mac"), reason)
    }

    func testSweepRefusesOtherIssuersAndLivePids() {
        let theirs = RemoteDispatchLockInfo(issuerHost: "my-mac", pid: 1, acquiredAt: "x", issuer: "alice")
        guard case .refuse = RemoteDispatchUnlock.decideAutomaticSweep(
            probe: .held(theirs), myIssuer: "wave1008", myHost: "my-mac", pidAlive: { _ in false })
        else { return XCTFail("another issuer's lock must never be swept") }
        guard case .refuse = RemoteDispatchUnlock.decideAutomaticSweep(
            probe: .held(mine), myIssuer: "wave1008", myHost: "my-mac", pidAlive: { $0 == 4242 })
        else { return XCTFail("a live dispatch must never be swept") }
    }

    // MARK: - decideLocalSweep(手元のロック。pid だけで確定する)

    /// 手元のロックは**同じ機械の pid** なので生死で確定できる —— 死んでいれば回収する。
    /// 規則は `decideAutomaticSweep` と同じ1つを通す(2つ目の回収規則を作らない)
    func testLocalSweepReleasesMyDeadRunsLock() {
        guard case .release = RemoteDispatchUnlock.decideLocalSweep(
            probe: .held(mine), myIssuer: "wave1008", myHost: "my-mac", pidAlive: { _ in false })
        else { return XCTFail("my dead local run's lock must be released") }
    }

    /// **陰性対照2つ**: 生きている自分の run と、他人がこの Mac へディスパッチして置いたロック
    /// (別の機械から発行 = pid の生死を確かめられない)は外さない
    func testLocalSweepRefusesLiveRunsAndLocksDispatchedFromAnotherMac() {
        guard case .refuse = RemoteDispatchUnlock.decideLocalSweep(
            probe: .held(mine), myIssuer: "wave1008", myHost: "my-mac", pidAlive: { $0 == 4242 })
        else { return XCTFail("a live local run must never be swept") }
        guard case .refuse = RemoteDispatchUnlock.decideLocalSweep(
            probe: .held(mine), myIssuer: "wave1008", myHost: "someone-else-mbp",
            pidAlive: { _ in false })
        else { return XCTFail("a lock dispatched from another Mac must never be swept locally") }
    }

    func testMyDispatchFromAnotherMachineIsReleasedWithoutPidCheck() {
        var pidChecked = false
        guard case .release = RemoteDispatchUnlock.decide(
            probe: .held(mine), myIssuer: "wave1008", myHost: "other-mac",
            pidAlive: { _ in pidChecked = true; return true })
        else { return XCTFail("my lock from another machine is released on my say-so") }
        XCTAssertFalse(pidChecked)
    }

    func testProbeCommandAndParse() {
        XCTAssertEqual(RemoteDispatchLock.parseProbe("absent\n"), .absent)
        XCTAssertEqual(RemoteDispatchLock.parseProbe("held\n"), .held(nil))
        let info = RemoteDispatchLockInfo(issuerHost: "h", pid: 7, acquiredAt: "t", issuer: "i")
        XCTAssertEqual(RemoteDispatchLock.parseProbe("held\n" + RemoteDispatchLock.encode(info)! + "\n"),
                       .held(info))
        XCTAssertNil(RemoteDispatchLock.parseProbe(""))
        XCTAssertEqual(
            RemoteDispatchLock.probeCommand(home: "/Users/ci"),
            "if [ -d '/Users/ci/.fleetest/dispatch.lock' ]; then echo held;"
            + " cat '/Users/ci/.fleetest/dispatch.lock/info.json' 2>/dev/null || true;"
            + " else echo absent; fi")
    }
}
