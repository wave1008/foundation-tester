// ft_batch: 1手目に限り ref を受け付ける。
//
// 「後続ステップの ref は信用できない」という制約自体は正しいまま(各手が木を変え得るので、
// 2手目以降の ref は撮られたスナップショットとの間に自分自身が挟まる)。1手目だけ例外なのは、
// まだどの手も画面を変えていないから。3層で見る:
//   - パース/解決(BatchLineParser / BatchStepResolver) — デバイスに触れない
//   - ref → セレクタの解決(MCPServer.buildResolvedRefStep) — 純粋関数。掴めた ElementInfo から
//     ステップと表示行を作るだけで、RefGuard の再照合そのものはここに無い
//   - 統合(server.call 経由) — FakeDriver で実行まで通す

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPBatchFirstStepRefTests: XCTestCase {

    // MARK: - パース/解決レベル(BatchLineParser.parse → BatchStepResolver.resolve)

    private func resolve(command: String, line: String, stepIndex: Int) throws -> [String: Any] {
        let parsed = try BatchLineParser.parse(line)
        let info = DSLCommandIndex.all.first(where: { $0.name == command })!
        let builder = MCPServer.batchStepBuilders[command]!
        return try BatchStepResolver.resolve(command: command, signature: info.signature,
                                             args: parsed.args, declaredKeys: builder.keys,
                                             stepIndex: stepIndex)
    }

    /// 1手目の `tap ref: 5` はパースを通り、`raw["ref"]` に整数が入る(selector は無い)
    func testFirstStepRefParsesForASelectorTakingCommand() throws {
        let raw = try resolve(command: "tap", line: "tap ref: 5", stepIndex: 0)
        XCTAssertEqual(raw["ref"] as? Int, 5)
        XCTAssertNil(raw["selector"])
    }

    /// 2手目以降の ref は拒否され、「1手目でだけ使える」ことが分かる文言になる
    func testSecondStepRefIsRejectedAndSaysFirstStepOnly() {
        XCTAssertThrowsError(try resolve(command: "tap", line: "tap ref: 5", stepIndex: 1)) { error in
            let message = (error as? BatchStepResolver.ResolveError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("first step"), message)
            XCTAssertTrue(message.contains("selector"), message)
        }
    }

    /// セレクタを取らないコマンド(`swipe`)は1手目でも ref を拒否する。**メッセージは通常の
    /// 「そんな引数は無い」のまま**(1手目限定の案内を出さない — 混乱を増やすだけ)
    func testNonSelectorCommandRejectsRefEvenOnFirstStep() {
        XCTAssertThrowsError(try resolve(command: "swipe", line: "swipe ref: 5", stepIndex: 0)) { error in
            let message = (error as? BatchStepResolver.ResolveError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("has no \"ref:\" parameter"), message)
            XCTAssertFalse(message.contains("first step"), message)
        }
    }

    /// pressEnter も同型(セレクタを取らないコマンドの掃討)
    func testPressEnterRejectsRefEvenOnFirstStep() {
        XCTAssertThrowsError(try resolve(command: "pressEnter", line: "pressEnter ref: 5", stepIndex: 0)) { error in
            let message = (error as? BatchStepResolver.ResolveError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("has no \"ref:\" parameter"), message)
        }
    }

    /// selector と ref を両方書いたら、順序に関わらず拒否する
    func testSelectorAndRefTogetherIsRejected() {
        XCTAssertThrowsError(try resolve(command: "tap", line: "tap '#a' ref: 5", stepIndex: 0)) { error in
            let message = (error as? BatchStepResolver.ResolveError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("both a selector and"), message)
        }
        XCTAssertThrowsError(try resolve(command: "tap", line: "tap ref: 5 selector: '#a'", stepIndex: 0)) { error in
            let message = (error as? BatchStepResolver.ResolveError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("both a selector and"), message)
        }
    }

    /// ref を2回書いたら「more than once」で弾く(他のラベルと同じ規律)
    func testRepeatedRefIsRejected() {
        XCTAssertThrowsError(try resolve(command: "tap", line: "tap ref: 5 ref: 6", stepIndex: 0)) { error in
            let message = (error as? BatchStepResolver.ResolveError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("more than once"), message)
        }
    }

    // MARK: - ref → セレクタの解決(純粋関数: MCPServer.buildResolvedRefStep)

    private func element(ref: Int, type: String = "Button", id: String? = nil, label: String? = nil,
                         x: Double, y: Double, w: Double = 100, h: Double = 40,
                         depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    private func screen(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                         elements: elements, truncatedCount: 0)
    }

    private func pendingTap(ref: Int, raw: [String: Any] = [:]) -> MCPServer.PendingBatchRef {
        MCPServer.PendingBatchRef(ref: ref, raw: raw, builder: MCPServer.batchStepBuilders["tap"]!)
    }

    /// (a) 一意な id が引ける要素は stable セレクタへ解決し、注記に ref の出所を書く
    func testBuildResolvedRefStepUsesAStableSelector() throws {
        let target = element(ref: 7, id: "btn_ok", label: "OK", x: 10, y: 20)
        let snapshot = screen([target])
        let (step, summary, note) = try MCPServer.buildResolvedRefStep(
            pendingTap(ref: 7), element: target, snapshot: snapshot, refNote: "")
        XCTAssertEqual(step.locator?.id, "btn_ok")
        XCTAssertEqual(summary, "tap \"#btn_ok\"")
        XCTAssertTrue(note.contains("ref 7 resolved to this selector"), note)
        XCTAssertFalse(note.contains("index-based"), note)
    }

    /// (b) id もラベルも無い兄弟だけの要素は添字形(index-based)へ解決し、脆さの注意書きが付く。
    /// **深さは preorder の祖先復元(TapTargetGeometry.ancestors)が要る通りに組む**: 容器は
    /// depth 1・中身は depth 2 で容器の直後に並べる(容器の frame が中身を包含すること)
    func testBuildResolvedRefStepMarksAnIndexBasedSelectorAsFragile() throws {
        let scope = ElementInfo(ref: 1, type: "Other", identifier: "row_container", label: nil,
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 390, height: 200), depth: 1)
        let target = element(ref: 2, type: "Clickable", id: nil, label: nil, x: 0, y: 0, depth: 2)
        let sibling1 = element(ref: 3, type: "Clickable", id: nil, label: nil, x: 0, y: 60, depth: 2)
        let sibling2 = element(ref: 4, type: "Clickable", id: nil, label: nil, x: 0, y: 120, depth: 2)
        let snapshot = screen([scope, target, sibling1, sibling2])
        let (_, _, note) = try MCPServer.buildResolvedRefStep(
            pendingTap(ref: 2), element: target, snapshot: snapshot, refNote: "")
        XCTAssertTrue(note.contains("ref 2 resolved to this selector"), note)
        XCTAssertTrue(note.contains("index-based"), note)
        XCTAssertTrue(note.contains(MCPServer.Durability.indexed.caution), note)
    }

    /// (c) 一意なセレクタが作れない要素は拒否し、ft_tap を ref で呼ぶ代替を示す
    func testBuildResolvedRefStepRejectsAnElementWithNoSelector() {
        let target = element(ref: 5, type: "StaticText", id: nil, label: "重複", x: 0, y: 0)
        let dup = element(ref: 6, type: "StaticText", id: nil, label: "重複", x: 0, y: 60)
        let snapshot = screen([target, dup])
        XCTAssertThrowsError(try MCPServer.buildResolvedRefStep(
            pendingTap(ref: 5), element: target, snapshot: snapshot, refNote: "")) { error in
            let message = (error as? MCPError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("no selector"), message)
            XCTAssertTrue(message.contains("ft_tap ref: 5"), message)
        }
    }

    /// RefGuard が返す注記(移動・ghost 等)は素通しでステップの注記に混ぜ込む
    /// (2つ目の警告文言を作らない — ft_tap が出すのと同じ文字列をそのまま連結する)
    func testBuildResolvedRefStepPassesThroughTheRefGuardNote() throws {
        let target = element(ref: 3, id: "row", label: "行", x: 10, y: 10)
        let snapshot = screen([target])
        let (_, _, note) = try MCPServer.buildResolvedRefStep(
            pendingTap(ref: 3), element: target, snapshot: snapshot,
            refNote: " (warning: from RefGuard)")
        XCTAssertTrue(note.contains("(warning: from RefGuard)"), note)
    }

    // MARK: - 統合(server.call 経由。FakeDriver)

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// FakeDriver の既定スナップショットは `#login_btn`(ref 1)を1件だけ持つ ——
    /// ft_snapshot を先に撮っておけば、その ref を1手目の `tap ref: 1` から解決できる
    func testFirstStepRefResolvesAndExecutesEndToEnd() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = body(try await server.call(tool: "ft_batch", args: ["steps": "tap ref: 1"]))
        XCTAssertTrue(text.contains("ref 1 resolved to this selector"), text)
        XCTAssertTrue(text.contains("tap \"#login_btn\""), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("tap(") }, "\(driver.calls)")
    }

    /// 2手目以降の ref は実行前に拒否され、1手目もデバイスへ通らない
    /// (「全手を実行前に検証する」規律を崩さないこと)
    func testSecondStepRefIsRejectedEndToEndBeforeAnythingRuns() async {
        do {
            _ = try await server.call(tool: "ft_batch",
                                      args: ["steps": "tap '#login_btn'; tap ref: 1"])
            XCTFail("2手目の ref が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("first step"),
                          error.localizedDescription)
        }
        XCTAssertEqual(driver.calls, [], "1手目もデバイスへ通さないこと")
    }

    /// 直前に ft_snapshot を撮っていないと ref は解決できない —— それでも実行には入らない
    /// (RefGuard を経由しないケースなので、拒否の理由がここだけ別だが、実行前に止まることは同じ)
    func testFirstStepRefWithoutAPriorSnapshotIsRejectedBeforeExecuting() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: ["steps": "tap ref: 1"])
            XCTFail("解決できない ref のバッチが通った")
        } catch {
            XCTAssertFalse(driver.calls.contains { $0.hasPrefix("tap(") }, "\(driver.calls)")
        }
    }

    /// 下書きに記録されるのは解決後のセレクタを持つステップ(ref は下書きに書けないので、
    /// これが無いと ft_draft_scenario が壊れた行を出す)
    func testDraftRecordsTheResolvedSelectorNotTheRef() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_batch", args: ["steps": "tap ref: 1"])
        let draft = body(try await server.call(tool: "ft_draft_scenario", args: [:]))
        XCTAssertTrue(draft.contains("tap(\"#login_btn\")"), draft)
        XCTAssertFalse(draft.contains("ref:"), draft)
        XCTAssertFalse(draft.contains("ref 1"), draft)
    }
}
