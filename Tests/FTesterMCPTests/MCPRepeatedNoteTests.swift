// once() による繰り返し注記の縮約。セッション(プロセス)を通じて生きる
// 1つの MCPServer インスタンスが同じ長文の注記を毎回満額で返すと、繰り返す呼び出しのぶん
// 文脈を食う。初回だけ満額、以後は短縮形にする対象は7つ(truncatedLabelNote /
// coordinateReproductionNote / indexedSelectorNote / unlabeledClickablesNote /
// ambiguousLabelsNote / snapshotAfterImmediateNote / indexedSelectorCaution)。
// unlabeledClickablesNote と ambiguousLabelsNote は onceNonEmpty 経由(注記が空の画面では
// キーを消費しない)。

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPOnceTests: XCTestCase {

    /// once() 自体の契約: 初回は full、以後は short。鍵ごとに独立する
    func testOnceReturnsFullOnceThenShort() {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        XCTAssertEqual(server.once("k", full: "full", short: "short"), "full")
        XCTAssertEqual(server.once("k", full: "full", short: "short"), "short")
        XCTAssertEqual(server.once("k", full: "full", short: "short"), "short")
        // 別の鍵は独立に初回扱いされる
        XCTAssertEqual(server.once("other", full: "full2", short: "short2"), "full2")
    }
}

final class MCPRepeatedCoordinateNoteTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    /// 座標形の注記(2026-08-16 に「書けない」→「書けるが弱い」へ改訂)は、
    /// 同じセッション内2回目以降は短縮形になる
    func testCoordinateNoteShortensOnTheSecondCallInTheSameSession() async throws {
        let first = try await server.call(tool: "ft_tap", args: ["x": 1.0, "y": 2.0])
        let firstText = try XCTUnwrap(first.first?["text"] as? String)
        XCTAssertTrue(firstText.contains("before keeping it in a scenario"), firstText)

        // 2回目は同じ ft_tap で確かめる(FakeDriver は座標 press を 501 で拒む)。
        // 鍵はツール間で共有なので、縮むこと自体はどのツール経由でも同じ
        let second = try await server.call(tool: "ft_tap", args: ["x": 3.0, "y": 4.0])
        let secondText = try XCTUnwrap(second.first?["text"] as? String)
        XCTAssertFalse(secondText.contains("before keeping it in a scenario"), secondText)
        XCTAssertTrue(secondText.contains("writable as tap(x:, y:)"), secondText)
    }

    /// **fromRef のドラッグは coordinateReproductionNote を一度も「見せて」いない**ので、
    /// その後の座標ドラッグは今までどおり初回として満額を返す(既定値として消費してはいけない)
    func testDragFromRefDoesNotConsumeTheOnceSlot() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "Button", identifier: "grabber", label: "つまみ",
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 10, y: 20, width: 100, height: 40), depth: 1)],
            truncatedCount: 0)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_drag", args: ["fromRef": 1, "dy": -50.0])

        let coordinateDrag = try await server.call(
            tool: "ft_drag", args: ["fromX": 10.0, "fromY": 20.0, "toX": 30.0, "toY": 40.0])
        let text = try XCTUnwrap(coordinateDrag.first?["text"] as? String)
        XCTAssertTrue(text.contains("before keeping it in a scenario"), text)
    }

    /// 長いラベルの切り詰め注記も同じ規則(2回目以降は短縮形)。ft_snapshot と ft_scroll_to は
    /// 鍵を共有するので、どちらから先に見せても以後は縮む
    func testTruncatedLabelNoteShortensOnTheSecondSnapshot() async throws {
        let long = String(repeating: "あ", count: SnapshotRenderer.labelDisplayLimit + 1)
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "staticText", identifier: nil, label: long,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 10, y: 20, width: 100, height: 40), depth: 1)],
            truncatedCount: 0)

        let first = try await server.call(tool: "ft_snapshot", args: [:])
        let firstText = try XCTUnwrap(first.first?["text"] as? String)
        XCTAssertTrue(firstText.contains("note: labels longer than"), firstText)

        let second = try await server.call(tool: "ft_snapshot", args: [:])
        let secondText = try XCTUnwrap(second.first?["text"] as? String)
        XCTAssertFalse(secondText.contains("note: labels longer than"), secondText)
        // **短縮形は「行動に要ることだけ」**(2026-08-13 に文面を削った): `*prefix*` の書き方は
        // 残し、「最初の注記を見よ」は落とした。実運用で 105 B が 6回/run 出ていたため
        XCTAssertTrue(secondText.contains("*prefix*"), secondText)
        XCTAssertLessThan(secondText.count, firstText.count, "2回目が短くなっていない")
    }
}

/// 変更C: unlabeledClickablesNote / ambiguousLabelsNote も同じ規則で縮む。
/// 明細(ref の列挙・ラベルごとの候補一覧)は abbreviated でも省かれないので、2回目にも出ていることを
/// 合わせて確かめる(縮むのは冒頭の説明文だけ、という仕様の核心)
final class MCPRepeatedUnlabeledAndAmbiguousNoteTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    private func unlabeledClickableSnapshot() -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "clickable", identifier: nil, label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 10, y: 20, width: 40, height: 40), depth: 1)],
            truncatedCount: 0)
    }

    private func ambiguousLabelSnapshot() -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [
                ElementInfo(ref: 1, type: "staticText", identifier: nil, label: "候補",
                           value: nil, placeholder: nil, enabled: true,
                           frame: FTRect(x: 10, y: 20, width: 80, height: 30), depth: 1),
                ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "候補",
                           value: nil, placeholder: nil, enabled: true,
                           frame: FTRect(x: 10, y: 60, width: 80, height: 30), depth: 1),
            ],
            truncatedCount: 0)
    }

    private func emptySnapshot() -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                         elements: [], truncatedCount: 0)
    }

    func testUnlabeledClickablesNoteShortensOnTheSecondSnapshotButKeepsTheListing() async throws {
        driver.snapshotResponse = unlabeledClickableSnapshot()
        let first = try await server.call(tool: "ft_snapshot", args: [:])
        let firstText = try XCTUnwrap(first.first?["text"] as? String)
        XCTAssertTrue(firstText.contains("targeted by ref or coordinates,"), firstText)
        XCTAssertTrue(firstText.contains("[1]"), firstText)

        let second = try await server.call(tool: "ft_snapshot", args: [:])
        let secondText = try XCTUnwrap(second.first?["text"] as? String)
        XCTAssertFalse(secondText.contains("targeted by ref or coordinates,"), secondText)
        XCTAssertTrue(secondText.contains("see the first snapshot's note"), secondText)
        XCTAssertTrue(secondText.contains("[1]"), secondText)
    }

    /// 該当要素の無い画面はキーを消費しない(onceNonEmpty) —— その後で初めて出た画面がフルになる
    func testUnlabeledClickablesNoteKeyIsNotConsumedByAScreenWithoutOne() async throws {
        driver.snapshotResponse = emptySnapshot()
        let empty = try await server.call(tool: "ft_snapshot", args: [:])
        let emptyText = try XCTUnwrap(empty.first?["text"] as? String)
        XCTAssertFalse(emptyText.contains("clickable element(s)"), emptyText)

        driver.snapshotResponse = unlabeledClickableSnapshot()
        let first = try await server.call(tool: "ft_snapshot", args: [:])
        let firstText = try XCTUnwrap(first.first?["text"] as? String)
        XCTAssertTrue(firstText.contains("targeted by ref or coordinates,"), firstText)
    }

    func testAmbiguousLabelsNoteShortensOnTheSecondSnapshotButKeepsTheListing() async throws {
        driver.snapshotResponse = ambiguousLabelSnapshot()
        let first = try await server.call(tool: "ft_snapshot", args: [:])
        let firstText = try XCTUnwrap(first.first?["text"] as? String)
        XCTAssertTrue(firstText.contains("cannot pick one uniquely"), firstText)
        XCTAssertTrue(firstText.contains("\"候補\" ×2"), firstText)

        let second = try await server.call(tool: "ft_snapshot", args: [:])
        let secondText = try XCTUnwrap(second.first?["text"] as? String)
        XCTAssertFalse(secondText.contains("cannot pick one uniquely"), secondText)
        XCTAssertTrue(secondText.contains("legend in the first snapshot's note"), secondText)
        XCTAssertTrue(secondText.contains("\"候補\" ×2"), secondText)
    }

    func testAmbiguousLabelsNoteKeyIsNotConsumedByAScreenWithoutDuplicates() async throws {
        driver.snapshotResponse = emptySnapshot()
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        driver.snapshotResponse = ambiguousLabelSnapshot()
        let first = try await server.call(tool: "ft_snapshot", args: [:])
        let firstText = try XCTUnwrap(first.first?["text"] as? String)
        XCTAssertTrue(firstText.contains("cannot pick one uniquely"), firstText)
    }
}

/// snapshotAfter の「整定を待たない即時読み」注意(2026-08-10・Fix3)。実測: ft_type の
/// snapshotAfter がネットワーク由来の候補リストの前の木を返し、waitFor 付きの ft_snapshot なら
/// 出るものが「候補なし」に見えた
final class MCPRepeatedSnapshotAfterNoteTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    func testImmediateReadNoteShortensOnTheSecondSnapshotAfter() async throws {
        let first = try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true])
        let firstText = try XCTUnwrap(first.first?["text"] as? String)
        XCTAssertTrue(firstText.contains("read immediately after the action"), firstText)
        XCTAssertTrue(firstText.contains("ft_snapshot waitFor"), firstText)

        let second = try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true])
        let secondText = try XCTUnwrap(second.first?["text"] as? String)
        XCTAssertFalse(secondText.contains("read immediately after the action"), secondText)
        XCTAssertTrue(secondText.contains("see the first snapshotAfter note"), secondText)
    }

    /// snapshotAfter を使わない呼び出しはキーを消費しない(空の note を先に見せない)
    func testPlainTapDoesNotConsumeTheOnceSlot() async throws {
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
        let first = try await server.call(tool: "ft_tap", args: ["ref": 1, "snapshotAfter": true])
        let firstText = try XCTUnwrap(first.first?["text"] as? String)
        XCTAssertTrue(firstText.contains("read immediately after the action"), firstText)
    }
}

/// index-based selector の但し書きは初回だけ満額、以後は短縮形(2026-08-10・Fix5)。
/// id の薄いアプリではタップのたび同じ長文が繰り返され、id を足せない他社アプリ相手ではノイズ
final class MCPRepeatedIndexedSelectorCautionTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    /// id を持つ祖先(`#tabs`)+ id もラベルも無い `clickable` 2つ = スコープ記法
    /// (`#tabs >> .clickable[n]`)でしか書けない(MCPWritableSelectorTests.testScopedNotationIsTheLastResort
    /// と同じ形)。ラベル/id が一意な要素は候補にすら挙がらないので、これで indexed を確実に踏む
    private func indexedSelectorSnapshot() -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [
                ElementInfo(ref: 1, type: "other", identifier: "tabs", label: nil,
                           value: nil, placeholder: nil, enabled: true,
                           frame: FTRect(x: 0, y: 0, width: 390, height: 60), depth: 1),
                ElementInfo(ref: 2, type: "clickable", identifier: nil, label: nil,
                           value: nil, placeholder: nil, enabled: true,
                           frame: FTRect(x: 10, y: 20, width: 80, height: 30), depth: 2),
                ElementInfo(ref: 3, type: "clickable", identifier: nil, label: nil,
                           value: nil, placeholder: nil, enabled: true,
                           frame: FTRect(x: 100, y: 20, width: 80, height: 30), depth: 2),
            ],
            truncatedCount: 0)
    }

    func testIndexedSelectorCautionShortensOnTheSecondTap() async throws {
        driver.snapshotResponse = indexedSelectorSnapshot()
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        let first = try await server.call(tool: "ft_tap", args: ["ref": 2])
        let firstText = try XCTUnwrap(first.first?["text"] as? String)
        XCTAssertTrue(firstText.contains("index-based, so it breaks"), firstText)

        let second = try await server.call(tool: "ft_tap", args: ["ref": 3])
        let secondText = try XCTUnwrap(second.first?["text"] as? String)
        XCTAssertFalse(secondText.contains("index-based, so it breaks"), secondText)
        XCTAssertTrue(secondText.contains("index-based (see the first note)"), secondText)
        // セレクタ自体は毎回出す(但し書きだけが縮む)
        XCTAssertTrue(secondText.contains("selector:"), secondText)
    }

    /// 安定なセレクタでは何も付かない(既存 testMarkAndCautionOnlyOnIndexed が単体で守る契約の配線確認)
    func testStableSelectorNeverGetsACaution() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [ElementInfo(ref: 1, type: "button", identifier: "btn_ok", label: "OK",
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 10, y: 20, width: 80, height: 30), depth: 1)],
            truncatedCount: 0)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let result = try await server.call(tool: "ft_tap", args: ["ref": 1])
        let text = try XCTUnwrap(result.first?["text"] as? String)
        XCTAssertFalse(text.contains("index-based"), text)
    }
}
