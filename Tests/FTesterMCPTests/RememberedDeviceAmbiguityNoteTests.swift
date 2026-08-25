// セッション記憶(foldInRememberedDevice)が省略呼び出しへ宛先を注入してよいかの規則。
//
// 2026-08-12 は「2台以上を触ったら毎回注記しつつ直近の1台へ流す」だったが、注記は事故を
// 1件も止めなかった(実際に起きた3件はいずれも「2台以上を触ったセッション」で
// 起きている)。2026-08-13 に**曖昧なら拒否**へ格上げした。1台しか触っていないセッションは
// 原理的に外しようがないので、そこは従来どおり黙って適用する。
//
// 判定はすべて純粋関数(デバイスも走査も要らない)。

import XCTest
@testable import ftester_mcp

final class RememberedDeviceAmbiguityNoteTests: XCTestCase {

    // MARK: - 曖昧さの判定(注記側と拒否側で共有する唯一の述語)

    func testAmbiguityRequiresTwoLabelsOrACrossedPlatform() {
        XCTAssertFalse(MCPServer.isAmbiguousMemory(allSeenLabels: [], otherPlatform: nil))
        XCTAssertFalse(MCPServer.isAmbiguousMemory(allSeenLabels: ["8123"], otherPlatform: nil))
        XCTAssertTrue(MCPServer.isAmbiguousMemory(allSeenLabels: ["8123", "8124"],
                                                  otherPlatform: nil))
        // 同 platform 内が1台でも、もう一方の platform を触っていれば行き先は自明ではない
        XCTAssertTrue(MCPServer.isAmbiguousMemory(allSeenLabels: ["8123"],
                                                  otherPlatform: "Android"))
    }

    // MARK: - 1台しか触っていない: 従来どおり初回だけ注記して適用する

    func testOneDeviceSeenNotesOnlyFirstTime() {
        let first = MCPServer.rememberedDeviceNote(chosen: "port 8123", firstTime: true)
        XCTAssertEqual(first, "(reusing this session's earlier device: port 8123"
            + " — pass udid/port/serial to target another)\n")

        let second = MCPServer.rememberedDeviceNote(chosen: "port 8123", firstTime: false)
        XCTAssertEqual(second, "", "1台しか触っていないのに2回目も注記が出た")
    }

    func testFoldAppliesSilentlyOnSecondCallWhenOnlyOneDeviceSeen() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        server.lastExplicitPlatform = "ios"
        server.seenExplicitIOSPorts = [8123]

        guard case .applied(let firstArgs, let firstNote) = server.foldInRememberedDevice([:]),
              case .applied(_, let secondNote) = server.foldInRememberedDevice([:]) else {
            return XCTFail("1台だけのセッションで記憶が適用されなかった")
        }
        XCTAssertEqual(firstArgs["port"] as? Int, 8123)
        XCTAssertTrue(firstNote.contains("reusing this session's earlier device"), firstNote)
        XCTAssertEqual(secondNote, "", "同じ1台を使い続けているのに毎回注記が出た")
    }

    /// 宛先を明示した呼び出しには一切触らない(記憶は省略呼び出しだけのもの)
    func testExplicitTargetIsLeftUnchangedEvenWhenAmbiguous() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        server.lastExplicitPlatform = "ios"
        server.seenExplicitIOSPorts = [8123, 8124]

        guard case .unchanged = server.foldInRememberedDevice(["port": 8130]) else {
            return XCTFail("明示された宛先に記憶が干渉した")
        }
    }

    // MARK: - 2台以上触った: 適用せず拒否する

    func testTwoIOSPortsSeenRefusesInsteadOfGuessing() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        server.lastExplicitPlatform = "ios"
        server.seenExplicitIOSPorts = [8124, 8123]

        guard case .ambiguous(let message) = server.foldInRememberedDevice([:]) else {
            return XCTFail("2台を触った後の省略呼び出しが黙って直近の1台へ流れた")
        }
        XCTAssertTrue(message.contains("8123"), message)
        XCTAssertTrue(message.contains("8124"), message)
        XCTAssertTrue(message.contains("Refusing to guess"), message)
    }

    func testTwoAndroidSerialsSeenRefuses() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.lastExplicitAndroidSerial = "emulator-5554"
        server.lastExplicitPlatform = "android"
        server.seenExplicitAndroidSerials = ["emulator-5554", "emulator-5556"]

        guard case .ambiguous(let message) = server.foldInRememberedDevice([:]) else {
            return XCTFail("Android 2台を触った後の省略呼び出しが拒否されなかった")
        }
        XCTAssertTrue(message.contains("emulator-5554"), message)
        XCTAssertTrue(message.contains("emulator-5556"), message)
    }

    /// 同 platform 内は1台でも、platform を跨いで触っていれば拒否する
    /// (iOS 1台 + Android 1台の並行運転で platform も宛先も省いた呼び出し)
    func testCrossPlatformSessionRefusesWhenPlatformAlsoOmitted() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        server.lastExplicitPlatform = "ios"
        server.seenExplicitIOSPorts = [8123]
        server.seenExplicitAndroidSerials = ["emulator-5554"]

        guard case .ambiguous(let message) = server.foldInRememberedDevice([:]) else {
            return XCTFail("iOS と Android を両方触った後の全省略呼び出しが拒否されなかった")
        }
        XCTAssertTrue(message.contains("Android"), message)
    }

    /// platform を明示していれば跨ぎの曖昧さは消える(同 platform 内が1台なら適用してよい)
    func testExplicitPlatformRemovesCrossPlatformAmbiguity() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        server.lastExplicitPlatform = "ios"
        server.seenExplicitIOSPorts = [8123]
        server.seenExplicitAndroidSerials = ["emulator-5554"]

        guard case .applied(let args, _) = server.foldInRememberedDevice(["platform": "ios"]) else {
            return XCTFail("platform 明示で一意になっているのに拒否された")
        }
        XCTAssertEqual(args["port"] as? Int, 8123)
    }

    // MARK: - 拒否の文面(候補を名指しする・上限を超えたら件数だけ)

    func testRefusalListsCandidatesInDeterministicOrder() {
        let ascending = MCPServer.rememberedDeviceRefusal(
            allSeenLabels: ["8123", "8124", "8130"], deviceNoun: "iOS devices", unitNoun: "ports",
            otherPlatform: nil)
        let shuffled = MCPServer.rememberedDeviceRefusal(
            allSeenLabels: ["8124", "8130", "8123"], deviceNoun: "iOS devices", unitNoun: "ports",
            otherPlatform: nil)
        XCTAssertEqual(ascending, shuffled,
                       "Set の反復順(プロセスごとに変わる)がそのまま文字列へ漏れている")
        XCTAssertTrue(ascending.contains("8123, 8124, 8130"), ascending)
    }

    func testRefusalNamesWhatToPass() {
        let message = MCPServer.rememberedDeviceRefusal(
            allSeenLabels: ["8123", "8124"], deviceNoun: "iOS devices", unitNoun: "ports",
            otherPlatform: nil)
        XCTAssertTrue(message.contains("udid"), message)
        XCTAssertTrue(message.contains("serial"), message)
    }

    func testRefusalListCapExceededNamesCountOnly() {
        let many = (0..<(MCPServer.rememberedDeviceListCap + 1)).map { "812\($0)" }
        let message = MCPServer.rememberedDeviceRefusal(
            allSeenLabels: many, deviceNoun: "iOS devices", unitNoun: "ports", otherPlatform: nil)
        XCTAssertTrue(message.contains("\(many.count) ports"), message)
        XCTAssertFalse(message.contains(many.sorted().last!), message)
    }

    func testRefusalAtCapStillListsAllLabels() {
        let atCap = (0..<MCPServer.rememberedDeviceListCap).map { "812\($0)" }
        let message = MCPServer.rememberedDeviceRefusal(
            allSeenLabels: atCap, deviceNoun: "iOS devices", unitNoun: "ports", otherPlatform: nil)
        for label in atCap {
            XCTAssertTrue(message.contains(label),
                          "上限ちょうどなのに \(label) が列挙されていない: \(message)")
        }
    }

    // MARK: - 曖昧さが解消したら適用へ戻る

    /// forgetConnection が候補を1件へ減らしたら、以後は非曖昧の規則(初回だけ注記して適用)へ戻る。
    /// **曖昧なあいだは「初回だけ」の鍵を消費しない**ので、戻った直後の呼び出しは満額の文言を受け取る
    func testShrinkingBackToOneDeviceResumesApplyingWithFirstTimeNote() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        server.lastExplicitPlatform = "ios"
        server.seenExplicitIOSPorts = [8123, 8124]

        // 曖昧なあいだに複数回踏む(鍵を消費しないことを狙う)
        _ = server.foldInRememberedDevice([:])
        _ = server.foldInRememberedDevice([:])

        server.connectedPorts["direct:ios:8124:"] = 8124
        server.connections["direct:ios:8124:"] = "port 8124"
        server.forgetConnection("direct:ios:8124:")
        XCTAssertEqual(server.seenExplicitIOSPorts, [8123],
                       "忘れたポートが延べ集合に残っている — 消えた機を候補として名乗り続ける")

        guard case .applied(_, let note) = server.foldInRememberedDevice([:]) else {
            return XCTFail("候補が1件へ減ったのに拒否が続いた")
        }
        XCTAssertEqual(note, "(reusing this session's earlier device: port 8123"
            + " — pass udid/port/serial to target another)\n",
            "曖昧なあいだにキーが消費され、非曖昧に戻ったのに初回の満額注記が出なかった")
    }
}
