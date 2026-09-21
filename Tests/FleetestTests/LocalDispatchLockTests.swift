// 手元で直接走る run が取る dispatch.lock(Sources/fleetest/LocalDispatchLock.swift)。
//
// **この経路は緑の run では1度も実行されない** —— 競合が起きないとロックも待ちも観測できない
// (E2E を回しても情報はゼロ)。代わりに**実ファイルシステムの一時ディレクトリを home に見立てて**
// 本物のシェル片をそのまま撃つ —— 撃つ相手が `/bin/sh` に変わっただけで、コマンド文字列は
// リモートと同じ `RemoteDispatchQueue` / `RemoteDispatchLock` が作ったものなので、
// 「同じ綴りが手元でも効く」ことをここで確かめられる。

import FTCore
import FTRemote
import Foundation
import XCTest
@testable import fleetest

final class LocalDispatchLockTests: XCTestCase {

    private var home = ""
    private var lines: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = NSTemporaryDirectory() + "fleetest-local-lock-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        lines = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
        try super.tearDownWithError()
    }

    /// 既定は「取れる側」。テストごとに違えたい値だけ引数で上書きする
    private func lock(pid: Int32, issuer: String = "alice", issuerHost: String = "mac-a",
                      group: String? = nil, waitLock: Int? = nil, forceLock: Bool = false,
                      environment: [String: String] = [:],
                      pidAlive: @escaping (Int32) -> Bool = { _ in true },
                      sleepSeconds: @escaping (Int) -> Void = { _ in
                          XCTFail("待たない設定で待とうとした") },
                      emitWaiting: ((DispatchWaitStatus) -> Void)? = nil) -> LocalDispatchLock {
        LocalDispatchLock(runGroup: group ?? "G\(pid)", waitLock: waitLock, forceLock: forceLock,
                          home: home, issuer: issuer, issuerHost: issuerHost, pid: pid,
                          environment: environment, pidAlive: pidAlive,
                          sleepSeconds: sleepSeconds, log: { [self] in lines.append($0) },
                          emitWaiting: emitWaiting)
    }

    private var lockDirExists: Bool {
        FileManager.default.fileExists(atPath: RemoteDispatchLock.lockDirPath(home: home))
    }

    private func message(_ error: Error) -> String {
        (error as? LocalDispatchLockError)?.message ?? "\(error)"
    }

    // MARK: - 取れる・外れる

    /// 取ると `~/.fleetest/dispatch.lock/info.json` が**この機械の pid** で建ち、
    /// 解放すると消える。**チケットは向こうで消えている**(待機列に自分が残らない)
    func testItTakesAndReleasesTheMachineGlobalLock() throws {
        let holder = try XCTUnwrap(try lock(pid: 4242).acquire())
        XCTAssertTrue(lockDirExists)
        let raw = try String(contentsOfFile: RemoteDispatchLock.infoFilePath(home: home),
                             encoding: .utf8)
        let info = try XCTUnwrap(RemoteDispatchLock.decode(raw))
        XCTAssertEqual(info.pid, 4242)
        XCTAssertEqual(info.issuer, "alice")
        XCTAssertEqual(info.issuerHost, "mac-a")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: RemoteDispatchQueue.directory(home: home)), [String](),
            "取れたのに待機列に自分のチケットが残っている")

        holder.release()
        XCTAssertFalse(lockDirExists)
        holder.release()  // 二重解放は無害
    }

    /// **この変更の目的**: 同じ機械の2本目は断られる(1本目が握っている間)。
    /// 文言は**手元のもの**(リモートの "on this remote host" や `remote unlock` の案内を出さない
    /// —— 手元のロックは pid で自動回収されるので、その案内は誤りを教えることになる)
    func testASecondRunOnTheSameMachineIsRefusedWhileTheFirstHoldsTheLock() throws {
        let holder = try XCTUnwrap(try lock(pid: 4242).acquire())

        XCTAssertThrowsError(try lock(pid: 7777, issuer: "bob", issuerHost: "mac-b").acquire()) {
            let text = message($0)
            XCTAssertTrue(text.contains("another fleetest run is already running on this Mac"), text)
            XCTAssertTrue(text.contains("pid 4242"), text)
            XCTAssertFalse(text.contains("on this remote host"), text)
            XCTAssertFalse(text.contains("remote unlock"), text)
        }

        // **陰性対照**: 1本目が外せば2本目は取れる(「常に断る実装」と区別する)
        holder.release()
        let second = try XCTUnwrap(try lock(pid: 7777, issuer: "bob", issuerHost: "mac-b").acquire())
        second.release()
    }

    // MARK: - 待機列(FIFO)

    /// **順番は待機列が決める** —— 自分より前のチケットが残っている間は、ロックが空いていても
    /// mkdir を撃たない(撃つと先に並んだ run を追い越す)
    func testARunDoesNotOvertakeAnEarlierTicketEvenWhenTheLockIsFree() throws {
        let earlier = DispatchTicket(requestedAtMillis: 1_000, issuer: "bob", group: "B")
        try enqueue(earlier)

        XCTAssertThrowsError(try lock(pid: 7777).acquire()) {
            let text = message($0)
            XCTAssertTrue(text.contains("1 earlier request(s) are queued ahead of yours"), text)
            XCTAssertTrue(text.contains("--wait-lock"), text)
        }
        XCTAssertFalse(lockDirExists, "先頭でないのにロックを取っている")
    }

    /// `--wait-lock` は**手元でも待てる**(相手が外したら取る)。待つ判断はリモートと同じ
    /// `WaitLockPolling` を通るので、刻みは1回ぶん
    func testWaitLockQueuesOnThisMachineAndTakesTheLockWhenItIsReleased() throws {
        let holder = try XCTUnwrap(try lock(pid: 4242).acquire())
        var slept = 0
        let waiting = lock(pid: 7777, issuer: "bob", issuerHost: "mac-b", waitLock: 600,
                           sleepSeconds: { _ in
                               slept += 1
                               holder.release()
                           })
        let taken = try XCTUnwrap(try waiting.acquire())
        XCTAssertEqual(slept, 1, "1周で取れるはずが余分に待っている / 待っていない")
        XCTAssertTrue(lines.contains { $0.contains("queued for the dispatch lock on this Mac") },
                      lines.joined(separator: "\n"))
        taken.release()
    }

    /// 待ち切れなければ断る。**自分のチケットは列から外す**(他人の順番を詰まらせない)
    func testGivingUpLeavesTheQueue() throws {
        let holder = try XCTUnwrap(try lock(pid: 4242).acquire())
        defer { holder.release() }
        // limit 0 = 1周目で giveUp(sleep は呼ばれない)
        XCTAssertThrowsError(try lock(pid: 7777, issuer: "bob", issuerHost: "mac-b",
                                      waitLock: 0).acquire())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: RemoteDispatchQueue.directory(home: home)), [String](),
            "諦めたのに自分のチケットが列に残っている")
    }

    // MARK: - 待機を拡張へ見せる(`fleetest api run` の NDJSON)

    /// 手元のロックを待っている間も `dispatchWaiting` を出す —— 出さないと「テストを実行」を
    /// 押した人には実行ログビューが無言のまま止まって見える。**machine は `local`**
    /// (`--device-machine` / モニタータイルと同じ綴り)で、数字・保持者・経過・上限は
    /// 待機列の事実そのもの。出し口は本番と同じ `apiRunWaitingEmitter`(受け口だけ差し替える)
    func testTheApiRunPathEmitsTheWaitAsNdjsonNamingThisMachineLocal() throws {
        let holder = try XCTUnwrap(try lock(pid: 4242).acquire())
        defer { holder.release() }
        try enqueue(DispatchTicket(requestedAtMillis: 1_000, issuer: "carol", group: "C"))

        var ndjson: [String] = []
        // limit 0 = 1周目で諦める(sleep を呼ばずに、刻み1回ぶんの出力だけを観測できる)
        let waiting = lock(pid: 7777, issuer: "bob", issuerHost: "mac-b", waitLock: 0,
                           emitWaiting: LocalDispatchLock.apiRunWaitingEmitter(
                               out: { ndjson.append($0) }))
        XCTAssertThrowsError(try waiting.acquire())

        XCTAssertEqual(ndjson.count, 1, "進行ログと同じ刻み(1周 = 1行)で出ていない")
        let data = try XCTUnwrap(ndjson[0].data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "dispatchWaiting")
        XCTAssertEqual(object["machine"] as? String, "local")
        XCTAssertEqual(object["position"] as? Int, 2, "自分の前に carol のチケットが1枚ある")
        XCTAssertEqual(object["total"] as? Int, 2)
        XCTAssertEqual(object["elapsedSeconds"] as? Int, 0)
        XCTAssertEqual(object["limitSeconds"] as? Int, 0)
        let holderText = try XCTUnwrap(object["holder"] as? String)
        XCTAssertTrue(holderText.contains("pid 4242"), holderText)
        XCTAssertTrue(holderText.contains("alice"), holderText)
        // **ログとイベントは同じ回数**(刻みが2つに割れていない)
        XCTAssertEqual(lines.filter { $0.contains("queued for the dispatch lock on this Mac") }.count, 1,
                       lines.joined(separator: "\n"))
    }

    /// **陰性対照**: 待たずに取れた run は1行も出さない(「常に出す」実装と区別する) ——
    /// 出すと、待っていないのに拡張の全体レーンへ順番待ちが流れる
    func testARunThatTakesTheLockWithoutQueuingEmitsNothing() throws {
        var ndjson: [String] = []
        let holder = try XCTUnwrap(try lock(
            pid: 4242, waitLock: 600,
            emitWaiting: LocalDispatchLock.apiRunWaitingEmitter(out: { ndjson.append($0) })
        ).acquire())
        defer { holder.release() }
        XCTAssertTrue(ndjson.isEmpty, ndjson.joined(separator: "\n"))
    }

    // MARK: - 死んだロックの回収(pid だけで確定する)

    /// **同じ機械の pid は生死で確定できる**ので、死んだ自分のロックは次の run が回収する。
    /// リモートの `pgrep` による裏取りは通らない(通すと手元の run は見つからず永久に残る)
    func testADeadLocalLockIsReclaimedFromThePidAlone() throws {
        _ = try lock(pid: 4242).acquire()  // 解放せずに落ちた run を模す
        XCTAssertTrue(lockDirExists)

        let next = lock(pid: 7777, pidAlive: { $0 != 4242 })
        let holder = try XCTUnwrap(try next.acquire())
        XCTAssertTrue(lines.contains { $0.contains("auto-releasing a stale dispatch lock on this Mac") },
                      lines.joined(separator: "\n"))
        holder.release()
    }

    /// **陰性対照**: pid が生きていれば回収しない(「常に回収する実装」と区別する)
    func testALiveLocalLockIsNotReclaimed() throws {
        let holder = try XCTUnwrap(try lock(pid: 4242).acquire())
        defer { holder.release() }
        XCTAssertThrowsError(try lock(pid: 7777, pidAlive: { _ in true }).acquire())
        XCTAssertFalse(lines.contains { $0.contains("auto-releasing") },
                       lines.joined(separator: "\n"))
    }

    /// **他人がこの Mac へディスパッチして置いたロックは、pid が死んでいても外さない** ——
    /// 発行元が別の機械なので、その pid の生死はここからは確かめられない
    func testALockLeftByADispatchFromAnotherMacIsNeverReclaimed() throws {
        _ = try lock(pid: 4242, issuer: "alice", issuerHost: "someone-else-mbp").acquire()
        XCTAssertThrowsError(try lock(pid: 7777, issuer: "alice", issuerHost: "mac-a",
                                      pidAlive: { _ in false }).acquire())
        XCTAssertTrue(lockDirExists, "他の Mac から発行されたロックを外している")
    }

    /// 回収の判定は `RemoteDispatchUnlock` の1つだけを通し、**リモートの裏取りは持ち込まない**
    /// (型では守れないのでソースで固定する)
    func testTheLocalReclaimDoesNotGoThroughTheRemotePgrepPath() throws {
        let text = try Self.source("Sources/fleetest/LocalDispatchLock.swift")
        XCTAssertTrue(text.contains("RemoteDispatchUnlock.decideLocalSweep("),
                      "回収の判定が共有の1箇所を通っていない")
        // **コメントを剥いでからコードだけを見る** —— 「なぜリモートの裏取りを掛けないか」は
        // コメントで説明すべきことで、その語が書いてあること自体を禁じたいのではない
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
        for remoteOnly in ["guardingLiveRemoteRun", "liveDispatchedRunsCommand", "pgrep"] {
            XCTAssertFalse(code.contains(remoteOnly),
                           "手元の回収にリモートの裏取りを持ち込んでいる: \(remoteOnly)")
        }
    }

    // MARK: - 親が握っているとき

    /// 親(fan-out / ディスパッチした発行側)の印があれば**取りに行かない**。
    /// 印の値は `DispatchTicketIssuer.childEnvironment` が local の子へ渡すものそのもの
    func testTheChildOfAFanoutDoesNotTakeTheLockItsParentHolds() throws {
        let ticket = DispatchTicket(requestedAtMillis: 1_000, issuer: "alice", group: "G")
        let childEnv = DispatchTicketIssuer.childEnvironment(
            ticket: ticket, lockHeldTarget: DispatchLockHandoff.localTarget, base: [:])
        XCTAssertTrue(LocalDispatchLock.parentHoldsTheLock(environment: childEnv))

        XCTAssertNil(try lock(pid: 7777, environment: childEnv).acquire())
        XCTAssertFalse(lockDirExists, "親が握っているロックを子が建て直している")
    }

    /// **陰性対照**: 別の宛先(リモート)の印では飛ばさない —— 印は子孫へそのまま継がれるので、
    /// 真偽値にすると手元の run までロック無しで走る
    func testAMarkerForAnotherDestinationDoesNotSkipTheLocalLock() throws {
        let env = [DispatchLockHandoff.environmentKey: "ci@m1max.local"]
        XCTAssertFalse(LocalDispatchLock.parentHoldsTheLock(environment: env))
        let holder = try XCTUnwrap(try lock(pid: 7777, environment: env).acquire())
        holder.release()
    }

    /// ディスパッチが ssh 越しに運ぶ印(ランナー機の上で走る `run --runner local` 用)も同じ値
    func testTheSshSideMarkerIsTheSameValueTheLocalLockLooksFor() {
        let layout = RemoteLayout(base: "/Users/ci/fleetest-runner", issuer: "alice", home: "/Users/ci")
        let command = RemoteShell.remoteRunCommand(layout: layout, fleetestArgs: ["run"])
        XCTAssertTrue(command.contains("export FT_DISPATCH_LOCK_HELD='local' && "), command)
        XCTAssertTrue(LocalDispatchLock.parentHoldsTheLock(
            environment: [DispatchLockHandoff.environmentKey: DispatchLockHandoff.localTarget]))
    }

    // MARK: - --force-lock

    func testForceLockStealsTheLockOnThisMachine() throws {
        _ = try lock(pid: 4242).acquire()
        let stolen = try XCTUnwrap(try lock(pid: 7777, issuer: "bob", issuerHost: "mac-b",
                                            forceLock: true).acquire())
        let raw = try String(contentsOfFile: RemoteDispatchLock.infoFilePath(home: home),
                             encoding: .utf8)
        XCTAssertEqual(RemoteDispatchLock.decode(raw)?.pid, 7777)
        stolen.release()
    }

    // MARK: - 補助

    /// 自分より前に並んでいる人のチケットを、本物の綴り(`RemoteDispatchQueue`)で置く
    private func enqueue(_ ticket: DispatchTicket) throws {
        let dir = RemoteDispatchQueue.directory(home: home)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "queued".write(toFile: RemoteDispatchQueue.ticketFilePath(home: home, ticket: ticket),
                           atomically: true, encoding: .utf8)
    }

    static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
