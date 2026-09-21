// dispatch.lock の手前に置く FIFO 待機チケット(Sources/FTRemote/RemoteDispatchQueue.swift)の
// 純粋ロジック。ssh 実行は呼び出し側(Sources/fleetest/RemoteRunDispatcher.swift)。
// コマンド文字列は**完全一致**で固定する(1文字動けばリモートでの挙動が変わりうるため)。

import Foundation
import XCTest
import FTRemote

final class DispatchTicketTests: XCTestCase {

    // MARK: - fileName(辞書順 = 待ち順の土台)

    func testFileNameExactText() {
        let ticket = DispatchTicket(requestedAtMillis: 1_755_000_000_123,
                                    issuer: "wave8san@wave1008-mbp", group: "4242")
        XCTAssertEqual(ticket.fileName, "1755000000123~wave8san@wave1008-mbp~4242")
    }

    /// 13桁ゼロ埋め。桁が揃っていないと辞書順が時刻順にならない
    func testFileNameZeroPadsToThirteenDigits() {
        let ticket = DispatchTicket(requestedAtMillis: 123, issuer: "ci", group: "1")
        XCTAssertEqual(ticket.fileName, "0000000000123~ci~1")
    }

    /// 区切りの `~`・空白・日本語は %XX(大文字16進)へ畳む —— `~` が必ず消えるので3分割は曖昧にならない
    func testFileNameEncodesSeparatorSpaceAndNonASCII() {
        let ticket = DispatchTicket(requestedAtMillis: 1, issuer: "a~b c", group: "日本")
        XCTAssertEqual(ticket.fileName, "0000000000001~a%7Eb%20c~%E6%97%A5%E6%9C%AC")
    }

    func testFileNameKeepsSafeCharactersAsIs() {
        let ticket = DispatchTicket(requestedAtMillis: 0, issuer: "A.z_0-9@h", group: "g")
        XCTAssertEqual(ticket.fileName, "0000000000000~A.z_0-9@h~g")
    }

    // MARK: - parse(fileName の逆)

    func testParseRoundTripsPlainTicket() {
        let ticket = DispatchTicket(requestedAtMillis: 1_755_000_000_123,
                                    issuer: "wave8san@wave1008-mbp", group: "4242")
        XCTAssertEqual(DispatchTicket.parse(fileName: ticket.fileName), ticket)
    }

    func testParseRoundTripsEncodedTicket() {
        let ticket = DispatchTicket(requestedAtMillis: 42, issuer: "a~b c", group: "日本 ~ グループ")
        XCTAssertEqual(DispatchTicket.parse(fileName: ticket.fileName), ticket)
    }

    func testParseRoundTripsEmptyComponents() {
        let ticket = DispatchTicket(requestedAtMillis: 7, issuer: "", group: "")
        XCTAssertEqual(ticket.fileName, "0000000000007~~")
        XCTAssertEqual(DispatchTicket.parse(fileName: ticket.fileName), ticket)
    }

    func testParseRejectsBrokenNames() {
        XCTAssertNil(DispatchTicket.parse(fileName: ""))
        XCTAssertNil(DispatchTicket.parse(fileName: "0000000000001~ci"))          // 区切りが足りない
        XCTAssertNil(DispatchTicket.parse(fileName: "0000000000001~ci~1~extra"))  // 区切りが多い
        XCTAssertNil(DispatchTicket.parse(fileName: "notanumber~ci~1"))
        XCTAssertNil(DispatchTicket.parse(fileName: "~ci~1"))
        XCTAssertNil(DispatchTicket.parse(fileName: "-1~ci~1"))
        XCTAssertNil(DispatchTicket.parse(fileName: "0000000000001~%ZZ~1"))       // 16進でない
        XCTAssertNil(DispatchTicket.parse(fileName: "0000000000001~%7~1"))        // 途中で切れている
        XCTAssertNil(DispatchTicket.parse(fileName: "0000000000001~%+1~1"))       // 符号は16進2桁ではない
        XCTAssertNil(DispatchTicket.parse(fileName: "0000000000001~%FF~1"))       // UTF-8 として不正
    }

    // MARK: - 辞書順 = 時刻順

    func testLexicalOrderFollowsTimeAcrossDigitCounts() {
        let older = DispatchTicket(requestedAtMillis: 999_999_999_999, issuer: "ci", group: "1")
        let newer = DispatchTicket(requestedAtMillis: 1_000_000_000_000, issuer: "ci", group: "1")
        XCTAssertTrue(older.fileName < newer.fileName, "\(older.fileName) < \(newer.fileName)")
    }

    func testLexicalOrderBreaksTiesByIssuerThenGroup() {
        let alice = DispatchTicket(requestedAtMillis: 1_755_000_000_000, issuer: "alice", group: "2")
        let bob = DispatchTicket(requestedAtMillis: 1_755_000_000_000, issuer: "bob", group: "1")
        let aliceLater = DispatchTicket(requestedAtMillis: 1_755_000_000_000, issuer: "alice", group: "3")
        XCTAssertEqual([bob.fileName, aliceLater.fileName, alice.fileName].sorted(),
                       [alice.fileName, aliceLater.fileName, bob.fileName])
    }

    func testSortingFileNamesOrdersTicketsByRequestTime() {
        let first = DispatchTicket(requestedAtMillis: 900, issuer: "z", group: "1")
        let second = DispatchTicket(requestedAtMillis: 1_755_000_000_000, issuer: "a", group: "1")
        let third = DispatchTicket(requestedAtMillis: 1_755_000_000_001, issuer: "a", group: "1")
        XCTAssertEqual([third.fileName, first.fileName, second.fileName].sorted(),
                       [first.fileName, second.fileName, third.fileName])
    }

    // MARK: - now

    func testNowTakesEpochMilliseconds() {
        let ticket = DispatchTicket.now(issuer: "ci", group: "1",
                                        date: Date(timeIntervalSince1970: 1_755_000_000.25))
        XCTAssertEqual(ticket.requestedAtMillis, 1_755_000_000_250)
        XCTAssertEqual(ticket.issuer, "ci")
        XCTAssertEqual(ticket.group, "1")
    }

    // MARK: - 環境変数(親 → 子へ同じチケットを運ぶ)

    func testEnvironmentKeyIsPinned() {
        XCTAssertEqual(DispatchTicket.environmentKey, "FT_DISPATCH_TICKET")
    }

    func testEnvironmentValueUsesTheSameSpellingAsFileName() {
        let ticket = DispatchTicket(requestedAtMillis: 1_755_000_000_123, issuer: "a~b", group: "g 1")
        XCTAssertEqual(ticket.environmentValue, ticket.fileName)
    }

    func testFromEnvironmentRoundTrips() {
        let ticket = DispatchTicket(requestedAtMillis: 1_755_000_000_123, issuer: "a~b", group: "g 1")
        XCTAssertEqual(
            DispatchTicket.fromEnvironment([DispatchTicket.environmentKey: ticket.environmentValue]),
            ticket)
    }

    func testFromEnvironmentIsNilWhenAbsentOrBroken() {
        XCTAssertNil(DispatchTicket.fromEnvironment([:]))
        XCTAssertNil(DispatchTicket.fromEnvironment([DispatchTicket.environmentKey: "broken"]))
        XCTAssertNil(DispatchTicket.fromEnvironment(["OTHER": "0000000000001~ci~1"]))
    }
}

final class RemoteDispatchQueueTests: XCTestCase {

    /// **置き場はホームの `.fleetest/`**(`<base>` ではない。RemoteDispatchLock と同じ理由)
    private let home = "/Users/tester"
    private let ticket = DispatchTicket(requestedAtMillis: 1_755_000_000_000, issuer: "ci", group: "7")
    private let info = RemoteDispatchLockInfo(issuerHost: "h", pid: 1, acquiredAt: "2025-08-12T13:20:00Z")

    // MARK: - 置き場

    func testDirectoryIsSharedAcrossIssuers() {
        XCTAssertEqual(RemoteDispatchQueue.directory(home: home),
                       "/Users/tester/.fleetest/dispatch.queue")
    }

    func testTicketFilePathIsDirectoryPlusFileName() {
        XCTAssertEqual(RemoteDispatchQueue.ticketFilePath(home: home, ticket: ticket),
                       "/Users/tester/.fleetest/dispatch.queue/1755000000000~ci~7")
    }

    /// **同じ Mac に `<base>` を2つ作っても待機列は1本**(ロック本体と同じ規律 ——
    /// 列が分かれると「先頭のチケットの持ち主だけが mkdir を撃つ」が両方で成立し FIFO が壊れる)
    func testTwoBasesOnTheSameMachineShareOneQueue() {
        XCTAssertEqual(
            RemoteDispatchQueue.ticketFilePath(home: home, ticket: ticket),
            RemoteDispatchQueue.ticketFilePath(
                home: RemoteLayout(base: "/Volumes/ssd/other-runner", issuer: "bob", home: home).home,
                ticket: ticket))
    }

    func testStaleSecondsIsPinned() {
        XCTAssertEqual(RemoteDispatchQueue.staleSeconds, 30)
    }

    /// 失効はハートビート(= ポーリング間隔ごとの書き直し)の3倍。片方だけ動かすと、
    /// 待っている本人のチケットが生きているうちに掃かれる(順番を失う)
    func testStaleSecondsIsThreeHeartbeats() {
        XCTAssertEqual(RemoteDispatchQueue.staleSeconds, WaitLockPolling.pollIntervalSeconds * 3)
    }

    // MARK: - ssh コマンド文字列(完全一致で固定)

    private var expectedEnqueueCommand: String {
        let dir = "'/Users/tester/.fleetest/dispatch.queue'"
        let ticketPath = "'/Users/tester/.fleetest/dispatch.queue/1755000000000~ci~7'"
        return "mkdir -p \(dir) && printf '%s' 'queued' > \(ticketPath) || exit 1; "
            + "find \(dir) -type f ! -newermt '-30 seconds' -delete 2>/dev/null; "
            + "q=$(find \(dir) -type f 2>/dev/null | sed 's|.*/||' | sort); "
            + "printf '%s\\n' 'QUEUE'; printf '%s\\n' \"$q\"; printf '%s\\n' '---'; "
            + "if [ \"$(printf '%s\\n' \"$q\" | head -n 1)\" = '1755000000000~ci~7' ]; then"
            + " if mkdir -p '/Users/tester/.fleetest'"
            + " && mkdir '/Users/tester/.fleetest/dispatch.lock' 2>/dev/null"
            + " && printf '%s' '{\"acquiredAt\":\"2025-08-12T13:20:00Z\",\"issuerHost\":\"h\",\"pid\":1}'"
            + " > '/Users/tester/.fleetest/dispatch.lock/info.json'; then"
            + " rm -f \(ticketPath); printf '%s\\n' 'ACQUIRED';"
            + " else printf '%s\\n' 'HELD'; fi;"
            + " else printf '%s\\n' 'WAITING'; fi; "
            + "printf '%s\\n' '---'; "
            + "cat '/Users/tester/.fleetest/dispatch.lock/info.json' 2>/dev/null || true"
    }

    func testEnqueueAndTryAcquireCommandExactText() {
        XCTAssertEqual(
            RemoteDispatchQueue.enqueueAndTryAcquireCommand(home: home, ticket: ticket, info: info),
            expectedEnqueueCommand)
    }

    /// 一覧は必ず `find` で作る(相手は zsh。マッチしないグロブは `for` の語リストならシェルごと落ちる)
    func testEnqueueCommandListsWithFindAndHasNoUnquotedGlob() {
        let command = RemoteDispatchQueue.enqueueAndTryAcquireCommand(home: home, ticket: ticket, info: info)
        XCTAssertTrue(command.contains("find '/Users/tester/.fleetest/dispatch.queue' -type f"),
                      command)
        XCTAssertFalse(command.contains("for "), command)
        // `*` / `?` はシングルクォートの内側(sed の式・printf の書式)にしか無いこと
        var quoted = false
        for (offset, character) in command.enumerated() {
            if character == "'" { quoted.toggle() }
            if character == "*" || character == "?" {
                XCTAssertTrue(quoted, "unquoted glob character at \(offset) in: \(command)")
            }
        }
    }

    /// ロックの実体は leaf の `mkdir` の原子性 —— そこに `-p`(既存でも成功)が付くと
    /// 全員が同時に取れてしまう
    func testEnqueueCommandKeepsTheLockLeafMkdirNonRecursive() {
        let command = RemoteDispatchQueue.enqueueAndTryAcquireCommand(home: home, ticket: ticket, info: info)
        XCTAssertTrue(
            command.contains("&& mkdir '/Users/tester/.fleetest/dispatch.lock' 2>/dev/null"),
            command)
        XCTAssertFalse(
            command.contains("mkdir -p '/Users/tester/.fleetest/dispatch.lock'"), command)
    }

    /// `$` とバッククォートはシングルクォートの内側では展開されない(RemoteShell.quote の契約)
    func testEnqueueCommandNeutralizesDollarAndBacktickInHome() {
        let command = RemoteDispatchQueue.enqueueAndTryAcquireCommand(
            home: "/tmp/$(whoami)/`id`", ticket: ticket, info: info)
        XCTAssertTrue(command.contains("mkdir -p '/tmp/$(whoami)/`id`/.fleetest/dispatch.queue'"), command)
        XCTAssertTrue(command.contains("find '/tmp/$(whoami)/`id`/.fleetest/dispatch.queue' -type f"), command)
        XCTAssertTrue(
            command.contains("rm -f '/tmp/$(whoami)/`id`/.fleetest/dispatch.queue/1755000000000~ci~7'"),
            command)
    }

    func testDequeueCommandRemovesOnlyMyTicket() {
        XCTAssertEqual(RemoteDispatchQueue.dequeueCommand(home: home, ticket: ticket),
            "rm -f '/Users/tester/.fleetest/dispatch.queue/1755000000000~ci~7'")
    }

    // MARK: - 出力の解析

    private let holderJSON = "{\"acquiredAt\":\"2025-08-12T13:20:00Z\",\"issuerHost\":\"h\",\"pid\":1}"

    private func output(queue: [String], verdict: String, info: String) -> String {
        (["QUEUE"] + queue + ["---", verdict, "---", info]).joined(separator: "\n") + "\n"
    }

    func testParseAcquired() {
        let out = output(queue: ["1755000000000~ci~7"], verdict: "ACQUIRED", info: "")
        XCTAssertEqual(RemoteDispatchQueue.parseOutcome(out, ticket: ticket), .acquired)
    }

    func testParseHeldReportsFirstPositionAndHolder() {
        let out = output(queue: ["1755000000000~ci~7"], verdict: "HELD", info: holderJSON)
        XCTAssertEqual(RemoteDispatchQueue.parseOutcome(out, ticket: ticket),
                       .held(position: 1, total: 1, holder: info))
    }

    func testParseWaitingReportsPositionAndTotal() {
        let out = output(queue: ["1754000000000~alice~1", "1755000000000~ci~7", "1756000000000~bob~2"],
                         verdict: "WAITING", info: holderJSON)
        XCTAssertEqual(RemoteDispatchQueue.parseOutcome(out, ticket: ticket),
                       .waiting(position: 2, total: 3, holder: info))
    }

    /// 自分のチケットが一覧に無い = 解析不能(呼び出し側が従来のエラー経路へ倒せるように nil)
    func testParseWaitingWithoutMyTicketIsNil() {
        let out = output(queue: ["1754000000000~alice~1"], verdict: "WAITING", info: holderJSON)
        XCTAssertNil(RemoteDispatchQueue.parseOutcome(out, ticket: ticket))
    }

    func testParseHeldWithoutMyTicketIsNil() {
        let out = output(queue: ["1754000000000~alice~1"], verdict: "HELD", info: holderJSON)
        XCTAssertNil(RemoteDispatchQueue.parseOutcome(out, ticket: ticket))
    }

    /// info.json が読めない(空・壊れている)ときも**順番は出す** ―― holder だけ nil
    func testParseKeepsPositionWhenHolderInfoIsUnreadable() {
        let broken = output(queue: ["1755000000000~ci~7"], verdict: "HELD", info: "{not json")
        XCTAssertEqual(RemoteDispatchQueue.parseOutcome(broken, ticket: ticket),
                       .held(position: 1, total: 1, holder: nil))
        let empty = output(queue: ["1755000000000~ci~7"], verdict: "HELD", info: "")
        XCTAssertEqual(RemoteDispatchQueue.parseOutcome(empty, ticket: ticket),
                       .held(position: 1, total: 1, holder: nil))
    }

    func testParseIgnoresBlankQueueLines() {
        let out = "QUEUE\n\n1755000000000~ci~7\n\n---\nWAITING\n---\n\(holderJSON)\n"
        XCTAssertEqual(RemoteDispatchQueue.parseOutcome(out, ticket: ticket),
                       .waiting(position: 1, total: 1, holder: info))
    }

    func testParseRejectsMalformedOutput() {
        XCTAssertNil(RemoteDispatchQueue.parseOutcome("", ticket: ticket))
        // ヘッダが無い
        XCTAssertNil(RemoteDispatchQueue.parseOutcome("1755000000000~ci~7\n---\nHELD\n---\n", ticket: ticket))
        // 区切りが1本しかない
        XCTAssertNil(RemoteDispatchQueue.parseOutcome("QUEUE\n1755000000000~ci~7\n---\nHELD\n", ticket: ticket))
        // 判定語が無い
        XCTAssertNil(RemoteDispatchQueue.parseOutcome("QUEUE\n1755000000000~ci~7\n---\n---\n", ticket: ticket))
        // 知らない判定語(ssh の断片・シェルのエラー等)
        XCTAssertNil(RemoteDispatchQueue.parseOutcome(
            output(queue: ["1755000000000~ci~7"], verdict: "zsh: command not found", info: ""),
            ticket: ticket))
    }
}
