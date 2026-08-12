// セッション記憶(foldInRememberedDevice)の注記を「初回だけ」から「同 platform で2台以上
// 触ったら毎回」へ広げる変更(2026-08-12)。実アプリ監査で iOS/Android を並行運転したとき、
// 初回だけの注記は2台目以降どちらへ行ったか読み手に伝わらなかった。
//
// rememberedDeviceNote(MCPServer+Dispatch.swift)を直接叩く: デバイスも走査も要らない純粋関数。

import XCTest
@testable import ftester_mcp

final class RememberedDeviceAmbiguityNoteTests: XCTestCase {

    // MARK: - 1台しか触っていない: 従来どおり初回だけ

    func testOneDeviceSeenNotesOnlyFirstTime() {
        let first = MCPServer.rememberedDeviceNote(
            chosen: "port 8123", allSeenLabels: [], deviceNoun: "iOS devices", unitNoun: "ports",
            firstTime: true)
        XCTAssertEqual(first, "(reusing this session's earlier device: port 8123"
            + " — pass udid/port/serial to target another)\n")

        let second = MCPServer.rememberedDeviceNote(
            chosen: "port 8123", allSeenLabels: [], deviceNoun: "iOS devices", unitNoun: "ports",
            firstTime: false)
        XCTAssertEqual(second, "", "1台しか触っていないのに2回目も注記が出た")
    }

    /// allSeenLabels に自分自身しか入っていない(1件)ときも同じ扱い —— 「2件以上」だけが曖昧
    func testExactlyOneSeenLabelIsStillUnambiguous() {
        let note = MCPServer.rememberedDeviceNote(
            chosen: "port 8123", allSeenLabels: ["8123"], deviceNoun: "iOS devices", unitNoun: "ports",
            firstTime: true)
        XCTAssertTrue(note.contains("reusing this session's earlier device"), note)
        XCTAssertFalse(note.contains("driven"), "1件だけなのに曖昧文言が混ざった: \(note)")
    }

    // MARK: - 2台以上触った: firstTime の値によらず毎回出る

    func testTwoDevicesSeenNotesEveryTime() {
        let note = MCPServer.rememberedDeviceNote(
            chosen: "port 8123", allSeenLabels: ["8123", "8124"], deviceNoun: "iOS devices",
            unitNoun: "ports", firstTime: false)
        XCTAssertFalse(note.isEmpty, "2台目を触った後は firstTime: false でも注記が出るべき")
        XCTAssertTrue(note.contains("port 8123"), note)
        XCTAssertTrue(note.contains("8124"), note)
    }

    func testTwoDevicesSeenNoteIdenticalRegardlessOfFirstTime() {
        let whenFirst = MCPServer.rememberedDeviceNote(
            chosen: "port 8123", allSeenLabels: ["8123", "8124"], deviceNoun: "iOS devices",
            unitNoun: "ports", firstTime: true)
        let whenNotFirst = MCPServer.rememberedDeviceNote(
            chosen: "port 8123", allSeenLabels: ["8123", "8124"], deviceNoun: "iOS devices",
            unitNoun: "ports", firstTime: false)
        XCTAssertEqual(whenFirst, whenNotFirst,
                       "曖昧なときは firstTime の値が結果に影響してはいけない")
    }

    // MARK: - 一覧は決定的な順序(入力順序に依らない)

    func testListIsSortedRegardlessOfInputOrder() {
        let ascending = MCPServer.rememberedDeviceNote(
            chosen: "port 8123", allSeenLabels: ["8123", "8124", "8130"], deviceNoun: "iOS devices",
            unitNoun: "ports", firstTime: false)
        let reversed = MCPServer.rememberedDeviceNote(
            chosen: "port 8123", allSeenLabels: ["8130", "8124", "8123"], deviceNoun: "iOS devices",
            unitNoun: "ports", firstTime: false)
        let shuffled = MCPServer.rememberedDeviceNote(
            chosen: "port 8123", allSeenLabels: ["8124", "8130", "8123"], deviceNoun: "iOS devices",
            unitNoun: "ports", firstTime: false)
        XCTAssertEqual(ascending, reversed,
                       "Set の反復順(プロセスごとに変わる)がそのまま文字列へ漏れている")
        XCTAssertEqual(ascending, shuffled)
        XCTAssertTrue(ascending.contains("8123, 8124, 8130"), ascending)
    }

    // MARK: - 台数が上限を超えたら件数だけ名乗る

    func testListCapExceededNamesCountOnly() {
        let many = (0..<(MCPServer.rememberedDeviceListCap + 1)).map { "812\($0)" }
        let note = MCPServer.rememberedDeviceNote(
            chosen: "port 8120", allSeenLabels: many, deviceNoun: "iOS devices", unitNoun: "ports",
            firstTime: false)
        XCTAssertTrue(note.contains("\(many.count) ports"), note)
        // 上限を超えたら個々のラベルを列挙しない(1件目以外は名指ししない)
        XCTAssertFalse(note.contains(many.sorted().last!), note)
    }

    func testListAtCapStillListsAllLabels() {
        let atCap = (0..<MCPServer.rememberedDeviceListCap).map { "812\($0)" }
        let note = MCPServer.rememberedDeviceNote(
            chosen: "port 8120", allSeenLabels: atCap, deviceNoun: "iOS devices", unitNoun: "ports",
            firstTime: false)
        for label in atCap {
            XCTAssertTrue(note.contains(label), "上限ちょうどなのに \(label) が列挙されていない: \(note)")
        }
    }

    // MARK: - Android(serial)側でも同じ規則

    func testAndroidTwoSerialsNotesEveryTime() {
        let note = MCPServer.rememberedDeviceNote(
            chosen: "serial emulator-5554", allSeenLabels: ["emulator-5554", "emulator-5556"],
            deviceNoun: "Android devices", unitNoun: "serials", firstTime: false)
        XCTAssertFalse(note.isEmpty)
        XCTAssertTrue(note.contains("serial emulator-5554"), note)
        XCTAssertTrue(note.contains("emulator-5556"), note)
    }

    func testAndroidOneSerialNotesOnlyFirstTime() {
        let first = MCPServer.rememberedDeviceNote(
            chosen: "serial emulator-5554", allSeenLabels: [], deviceNoun: "Android devices",
            unitNoun: "serials", firstTime: true)
        XCTAssertTrue(first.contains("reusing this session's earlier device"), first)
        let second = MCPServer.rememberedDeviceNote(
            chosen: "serial emulator-5554", allSeenLabels: [], deviceNoun: "Android devices",
            unitNoun: "serials", firstTime: false)
        XCTAssertEqual(second, "")
    }

    // MARK: - 配線: foldInRememberedDevice が延べ集合を実際に渡す

    /// 2台の iOS を明示済みのセッションでは、省略呼び出しの注記が1回目・2回目とも出て一致する
    /// (finishingFold が曖昧なときキーを消費しない・rememberedDeviceNote が firstTime を無視する
    /// ことの配線確認)
    func testFoldNotesEveryCallWhenTwoIOSPortsSeenThisSession() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        server.lastExplicitPlatform = "ios"
        server.seenExplicitIOSPorts = [8124, 8123]

        let (_, firstNote) = server.foldInRememberedDevice([:])
        XCTAssertTrue(firstNote.contains("port 8123"), firstNote)
        XCTAssertTrue(firstNote.contains("8124"), firstNote)

        let (_, secondNote) = server.foldInRememberedDevice([:])
        XCTAssertEqual(firstNote, secondNote, "2台見た後は2回目も注記が出て内容が一致するはず")
    }

    /// forgetConnection が候補を1件へ減らしたら、以後は非曖昧の規則(初回だけ)に戻る
    func testForgetConnectionShrinksAmbiguitySetSoNoteGoesQuietAgain() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        server.lastExplicitPlatform = "ios"
        server.seenExplicitIOSPorts = [8123, 8124]
        server.connectedPorts["direct:ios:8124:"] = 8124
        server.connections["direct:ios:8124:"] = "port 8124"

        server.forgetConnection("direct:ios:8124:")

        XCTAssertEqual(server.seenExplicitIOSPorts, [8123],
                       "忘れたポートが延べ集合に残っている — 消えた機を候補として名乗り続ける")
    }

    /// 曖昧なあいだは「初回だけ」の鍵を消費しない: 2台見ている間の呼び出しはキーを一切
    /// 消費せず、1台へ減って非曖昧に戻った直後の呼び出しでも満額の「初回」文言が出る
    /// (finishingFold が isAmbiguous ? false : firstTime(noteKey) と分岐させている理由の実証)
    func testKeyNotConsumedWhileAmbiguousSoUnambiguousReturnGetsFirstTimeNote() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        server.lastExplicitIOSTarget = (port: 8123, udid: nil)
        server.lastExplicitPlatform = "ios"
        server.seenExplicitIOSPorts = [8123, 8124]

        // 曖昧なあいだに複数回呼ぶ(鍵を消費しないことを狙って何度も踏む)
        _ = server.foldInRememberedDevice([:])
        _ = server.foldInRememberedDevice([:])

        server.connectedPorts["direct:ios:8124:"] = 8124
        server.connections["direct:ios:8124:"] = "port 8124"
        server.forgetConnection("direct:ios:8124:")
        XCTAssertEqual(server.seenExplicitIOSPorts, [8123])

        let (_, afterShrink) = server.foldInRememberedDevice([:])
        XCTAssertEqual(afterShrink, "(reusing this session's earlier device: port 8123"
            + " — pass udid/port/serial to target another)\n",
            "曖昧なあいだにキーが消費され、非曖昧に戻ったのに初回の満額注記が出なかった")
    }
}
