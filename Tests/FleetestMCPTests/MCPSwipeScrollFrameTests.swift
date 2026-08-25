// ft_swipe に scrollFrame(掴む場所の指定)を足した分の回帰(2026-08-12 実機観測: 横スクロール
// する表を動かす手段が MCP に無かった)。
//
// **実装は StepExecutor へ委譲する**(DSL の scrollDown/scrollUp/scrollLeft/scrollRight(scrollFrame:)
// と同じ FlowStep action "scroll")。理由は2つ実機で確認済み:
//   - MCP から driver.swipe(_:intent:path:) を直接叩くと、in-app ブリッジは Compose/Flutter で
//     領域指定つきスクロールを 501 で拒否する(InAppBridge.swift:673-677)。501→XCUITest の
//     フォールバックは StepExecutor.swipeWithFallback(StepExecutor+Settle.swift:479)にしか無い
//   - ScrollGeometry・マージン定数・容器解決・fail-fast の2つ目の実装を MCP に作らない
//
// デバイス無しで判定できる部分を固定する:
//   1. FlowStep の組み立て(action/direction/maxSwipes/scrollFrame/scrollFrameRect)。
//      **direction は指の向きのまま渡す**(action "scroll" は指の向きとして読む —
//      StepExecutor+Actions.swift:55 `FTSwipeDirection(rawValue: step.direction ?? "")`。
//      DSL の scrollImpl も content→指の向きに変換してから積んでいる — Commands.swift:664)
//   2. FakeDriver 経由の dispatch: 容器が解決できない(fail-fast)/解決できた/画面と交差しない
//      (StepExecutor が黙って全画面へ落ち、その旨を note で伝える)/scrollFrame 未指定

import XCTest
import FTCore
@testable import fleetest_mcp

/// **FlowStep の組み立てが要点**(2026-08-12 の作り直し指示)。direction を書き換える変異
/// (誤って content 向きへ写像し直す等)で落ちること
final class MCPSwipeScrollFrameStepBuildingTests: XCTestCase {
    private func locatorArg(_ selector: String) -> MCPServer.ScrollFrameArg {
        MCPServer.ScrollFrameArg(locator: FTSelector.parse(selector).primary)
    }

    func testActionIsScrollAndMaxSwipesIsOne() {
        let step = MCPServer.swipeScrollFrameStep(direction: .up, scrollFrameArg: locatorArg("#list_rows"))
        XCTAssertEqual(step.action, "scroll")
        XCTAssertEqual(step.maxSwipes, 1)
    }

    /// **本丸**: 4方向とも指の向きの文字列がそのまま入ること(逆写像しない)。
    /// action "scroll" は FlowStep.direction を指の向きとして読むので、ここでコンテンツ向きへ
    /// 書き換える変異(例: .up を渡したら "down" が入る)が入ると、StepExecutor は逆方向へ振る
    func testDirectionPassesThroughUnchangedForAllFourDirections() {
        for finger in FTSwipeDirection.allCases {
            let step = MCPServer.swipeScrollFrameStep(direction: finger, scrollFrameArg: locatorArg("#x"))
            XCTAssertEqual(step.direction, finger.rawValue,
                           "finger \(finger.rawValue) を渡したら step.direction も同じ文字列であるべき")
        }
    }

    func testLocatorFormCarriesScrollFrameLocatorAndLeavesRectNil() {
        let arg = locatorArg("#list_rows")
        let step = MCPServer.swipeScrollFrameStep(direction: .up, scrollFrameArg: arg)
        XCTAssertNotNil(step.scrollFrame)
        XCTAssertNil(step.scrollFrameRect)
    }

    func testRefFormCarriesScrollFrameRectAndLeavesLocatorNil() {
        let rect = FTRect(x: 0, y: 100, width: 402, height: 600)
        let arg = MCPServer.ScrollFrameArg(rect: rect)
        let step = MCPServer.swipeScrollFrameStep(direction: .down, scrollFrameArg: arg)
        XCTAssertEqual(step.scrollFrameRect, rect)
        XCTAssertNil(step.scrollFrame)
    }

    /// **MCP 側でマージン比を選ばない**: nil のまま渡し、StepExecutor 側の探索既定に従わせる
    func testMarginRatiosAreNotSet() {
        let step = MCPServer.swipeScrollFrameStep(direction: .left, scrollFrameArg: locatorArg("#x"))
        XCTAssertNil(step.startMarginRatio)
        XCTAssertNil(step.endMarginRatio)
    }
}

/// FakeDriver 経由の dispatch。StepExecutor の実際の挙動(容器なし=fail-fast・容器はあるが
/// 交差なし=黙って全画面へ落ちて note を出す)をそのまま踏襲していることを確かめる —
/// **MCP 側で別の判断をしていない**ことがここでの主眼
final class MCPSwipeScrollFrameDispatchTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func el(_ ref: Int, id: String, frame: FTRect) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true, frame: frame, depth: 1)
    }

    /// scrollFrame セレクタが何にも当たらない → StepExecutor の scrollFrameMissing fail-fast
    /// (1本も振らない)。MCP は二重の判定を持たず、そのまま throw する
    func testScrollFrameThatMatchesNothingFailsFastWithoutSwiping() async {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: screen,
            elements: [el(1, id: "list_rows", frame: FTRect(x: 0, y: 100, width: 402, height: 600))],
            truncatedCount: 0)

        do {
            _ = try await server.call(tool: "ft_swipe",
                                      args: ["direction": "up", "scrollFrame": "#does_not_exist"])
            XCTFail("当たらない scrollFrame は fail-fast するはず")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("does_not_exist"), message)
            XCTAssertTrue(message.contains("matched nothing"), message)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("swipe(") }, "\(driver.calls)")
    }

    /// **セレクタでも ref でもない値は入口で断る**(2026-08-12 のレビュー指摘)。
    /// `resolveScrollFrameArg` が見るのは Int と String だけなので、素通しすると
    /// 空の ScrollFrameArg になり、**容器を無視した全画面スワイプを「inside …」と名乗って**返る
    func testScrollFrameOfAWrongTypeIsRefusedInsteadOfSwipingTheWholeScreen() async {
        do {
            _ = try await server.call(tool: "ft_swipe",
                                      args: ["direction": "up", "scrollFrame": true])
            XCTFail("型違いの scrollFrame は断るはず")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("scrollFrame must be"),
                          error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("swipe(") }, "\(driver.calls)")
    }

    /// **呼び出し元の向きがそのまま指の向きとして届くこと**(2026-08-12 の変異で発見した穴)。
    /// `swipeScrollFrameStep` 単体のテストは純関数の中しか見ないので、**ディスパッチが
    /// 途中で写像をかけても落ちなかった**。経路の始点・終点で見る = 指が実際にどちらへ動いたか。
    /// 指が上("up")なら下端から上端へ = fromY > toY
    func testTheCallersFingerDirectionReachesTheGestureUnchanged() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: screen,
            elements: [el(1, id: "list_rows", frame: FTRect(x: 0, y: 100, width: 402, height: 600))],
            truncatedCount: 0)

        _ = try await server.call(tool: "ft_swipe",
                                  args: ["direction": "up", "scrollFrame": "#list_rows"])
        let up = try XCTUnwrap(driver.lastSwipePath)
        XCTAssertGreaterThan(up.fromY, up.toY, "指が上へ動いていない: \(up)")

        _ = try await server.call(tool: "ft_swipe",
                                  args: ["direction": "down", "scrollFrame": "#list_rows"])
        let down = try XCTUnwrap(driver.lastSwipePath)
        XCTAssertLessThan(down.fromY, down.toY, "指が下へ動いていない: \(down)")
    }

    /// **陰性対照**: 容器が交差していれば成功し、応答が「どの容器の中を振ったか」を名乗る
    func testScrollFrameThatResolvesAndIntersectsSucceedsAndNamesTheContainer() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: screen,
            elements: [el(1, id: "list_rows", frame: FTRect(x: 0, y: 100, width: 402, height: 600))],
            truncatedCount: 0)

        let text = body(try await server.call(tool: "ft_swipe",
                                              args: ["direction": "up", "scrollFrame": "#list_rows"]))
        XCTAssertTrue(text.contains("list_rows"), text)
        XCTAssertTrue(text.contains("inside"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("swipe(") }, "\(driver.calls)")
    }

    /// **容器は解決できるが画面と交差しない**: StepExecutor は fail-fast しない(容器自体は
    /// 見つかっている)—— 黙って全画面へ落ち、その旨を note で伝える。MCP はこれをそのまま
    /// 通す(独自の拒否を上乗せしない)。swipe 自体は送られる
    func testScrollFrameThatDoesNotIntersectFallsBackToFullScreenWithANote() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: screen,
            elements: [el(1, id: "offscreen_rows", frame: FTRect(x: 0, y: 900, width: 402, height: 100))],
            truncatedCount: 0)

        let text = body(try await server.call(tool: "ft_swipe",
                                              args: ["direction": "up", "scrollFrame": "#offscreen_rows"]))
        XCTAssertTrue(text.contains("leaves nothing to move"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("swipe(") }, "\(driver.calls)")
    }

    /// **未指定は今までと1バイトも変えない**: scrollFrame を渡さなければ従来どおり
    /// 「swipe <direction> sent.」だけで、容器の名乗りは出ない
    func testWithoutScrollFrameBehaviorIsUnchanged() async throws {
        let text = body(try await server.call(tool: "ft_swipe", args: ["direction": "up"]))
        XCTAssertTrue(text.hasPrefix("swipe up sent."), text)
        XCTAssertFalse(text.contains("inside"), text)
    }

    /// **ref 形は rect として効く**(id が重複・欠落する容器のための逃げ道)。
    /// 経路が容器(y 100〜700)の中に収まっていること = 全画面(y 0〜874)へ黙って
    /// 退化していないことを見る。**FTCore 側の穴の回帰テスト**でもある:
    /// action "scroll" は rect だけの step で木を撮らず、path ごと nil にして
    /// 全画面スワイプへ落ちていた(StepExecutor+Actions.swift の latest の条件)
    func testScrollFrameRefConfinesTheSwipeToThatContainer() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: screen,
            elements: [el(1, id: "list_rows", frame: FTRect(x: 0, y: 100, width: 402, height: 600))],
            truncatedCount: 0)
        _ = try await server.call(tool: "ft_snapshot", args: [:])

        _ = try await server.call(tool: "ft_swipe", args: ["direction": "up", "scrollFrame": 1])
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("swipe(") }, "\(driver.calls)")
        let path = try XCTUnwrap(driver.lastSwipePath, "領域指定の経路が渡っていない(全画面へ退化)")
        XCTAssertTrue(path.fromY > 100 && path.fromY < 700, "fromY=\(path.fromY)")
        XCTAssertTrue(path.toY > 100 && path.toY < 700, "toY=\(path.toY)")
    }
}
