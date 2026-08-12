// ft_snapshot の注記生成(ghostFlags/foldedGroups/SelectorNaming.graded)を1応答ぶんの
// SnapshotAnnotationCache へ寄せた改善(2026-08-12)の恒久計測+回帰ゲート。
//
// 実測(実アプリ・Apple マップ経路画面 203 要素。コミットしていないスクラッチ fixture):
// 素の呼び出しは同じ木に対して ghostFlags を3回・foldedGroups を2回払い、
// ambiguousLabelsNote と duplicateIDsNote は別々の SelectorNaming を作るので、
// 両方の群に出る要素(実測: `#TitleLabel` ×3 と `"経路"` ×3 が要素を共有)の graded が
// 二重に走ることがあった。
//
// **合否は時間で判定しない**(環境で揺れて flaky になる)。代わりに「同じ計算が何回走ったか」
// (SnapshotAnnotationCache の compute カウンタ)を固定する。時間は参考として print するだけ。

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPAnnotationCacheTests: XCTestCase {

    private func fixture(_ name: String) throws -> SnapshotResponse {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots/\(name).json")
        return try JSONDecoder().decode(SnapshotResponse.self, from: try Data(contentsOf: url))
    }

    private func fixtureNames() throws -> [String] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RealAppSnapshots")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    private func element(_ ref: Int, type: String = "button", id: String? = nil,
                         label: String? = nil, y: Double = 100) -> ElementInfo {
        // **全要素を同じ depth に置く**: TapTargetGeometry.ancestors は depth の大小だけで
        // 祖先を復元するので、同じ depth の並びは互いに無関係な兄弟になる
        // (isSingleChain が false になる = 曖昧ラベル/重複 id の除外条件に掛からない)
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 100, height: 40), depth: 1)
    }

    /// snapshotBody が組む注記のうち、キャッシュ対象の部分だけを同じ順序で呼ぶ
    /// (backgroundNote/switchedNote 等ドライバ依存の注記はキャッシュの対象外なのでここには無い)
    private func buildCachedAnnotations(_ snapshot: SnapshotResponse,
                                        cache: MCPServer.SnapshotAnnotationCache) -> String {
        MCPServer.ghostNote(snapshot, collapsingBulk: true, cache: cache)
            + MCPServer.ambiguousLabelsNote(snapshot, cache: cache)
            + MCPServer.duplicateIDsNote(snapshot, cache: cache)
            + SnapshotRenderer.render(snapshot, flagging: cache.ghostFlags(snapshot),
                                      collapsingBulk: true)
    }

    private func buildUncachedAnnotations(_ snapshot: SnapshotResponse) -> String {
        MCPServer.ghostNote(snapshot, collapsingBulk: true)
            + MCPServer.ambiguousLabelsNote(snapshot)
            + MCPServer.duplicateIDsNote(snapshot)
            + SnapshotRenderer.render(snapshot, flagging: MCPServer.ghostFlags(snapshot),
                                      collapsingBulk: true)
    }

    // MARK: - 恒久計測ハーネス(リポジトリ内最大のフィクスチャ=120要素)

    /// **合否は呼び出し回数**。時間は最後に print するだけ(環境で揺れるので assert しない)。
    /// **各ステップの直後に確かめる**(全部呼んでから最後に1回だけ見ない) —— ある呼び手が
    /// cache を渡されても内部で使わず生の関数を呼んでいたケースを、後続の
    /// `cache.ghostFlags(snapshot)` 呼び出し(render 相当)が「結果的に1回」に見せかけて隠す
    func testAnnotationGenerationCallCountsOnLargestFixture() throws {
        let snapshot = try fixture("ios-maps_station")
        XCTAssertEqual(snapshot.elements.count, 120,
                       "コーパス最大のフィクスチャが入れ替わった — このテストの前提を見直すこと")

        let cache = MCPServer.SnapshotAnnotationCache()
        _ = MCPServer.ghostNote(snapshot, collapsingBulk: true, cache: cache)
        XCTAssertEqual(cache.ghostFlagsComputeCount, 1, "ghostNote が cache 経由で ghostFlags を計算していない")
        XCTAssertEqual(cache.foldedGroupsComputeCount, 1, "ghostNote が cache 経由で foldedGroups を計算していない")

        _ = MCPServer.duplicateIDsNote(snapshot, cache: cache)
        XCTAssertEqual(cache.ghostFlagsComputeCount, 1, "duplicateIDsNote が ghostFlags を再計算した")
        // duplicateIDsNote は常に collapsingBulk: true で引くので ghostNote と同じキーに乗る
        XCTAssertEqual(cache.foldedGroupsComputeCount, 1, "duplicateIDsNote が foldedGroups を再計算した")

        _ = cache.ghostFlags(snapshot)   // render が渡す flagging 引数と同じ呼び出し
        XCTAssertEqual(cache.ghostFlagsComputeCount, 1, "render 相当の呼び出しで ghostFlags を再計算した")

        // 参考計測(合否には使わない): N 回まわした所要を print する
        let iterations = 30
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<iterations {
            _ = buildCachedAnnotations(snapshot, cache: MCPServer.SnapshotAnnotationCache())
        }
        let cachedMs = Double((clock.now - start) / .microseconds(1)) / 1000 / Double(iterations)

        let uncachedStart = clock.now
        for _ in 0..<iterations {
            _ = buildUncachedAnnotations(snapshot)
        }
        let uncachedMs = Double((clock.now - uncachedStart) / .microseconds(1)) / 1000
            / Double(iterations)
        print("[perf] 120 elements: cached \(cachedMs) ms/iter, uncached \(uncachedMs) ms/iter"
            + " (avg of \(iterations))")
    }

    // MARK: - 出力は1バイトも変えない(実アプリのコーパス全数)

    /// **既知の罠**: `duplicateIDsNote`/`ambiguousLabelsNote` は件数が同数タイの群が複数あると、
    /// キャッシュとは無関係に(cache: nil の素の呼び出し同士でも)並び順が入れ替わることがある
    /// (2026-08-12 に `and-home` フィクスチャで実測・原因未特定・本タスクのスコープ外)。
    /// そのため全文字列の一致ではなく**行の集合**で比較する——並び順に依らず、
    /// 内容(どの選択子・どの ref・どの件数を報告したか)の一致だけを見る
    private func lineSet(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: "\n"))
    }

    /// キャッシュの有無で報告内容が変わらないこと。**全フィクスチャ**に当てる
    /// (誤検知0の確認は特定の1枚では足りない——CLAUDE.md の検証規律)
    func testCachedAnnotationsMatchUncachedContent() throws {
        var checked = 0
        for name in try fixtureNames() {
            let snapshot = try fixture(name)
            let withoutCache = buildUncachedAnnotations(snapshot)
            let withCache = buildCachedAnnotations(snapshot, cache: MCPServer.SnapshotAnnotationCache())
            XCTAssertEqual(lineSet(withCache), lineSet(withoutCache),
                           "\(name): cache 有無で報告内容が変わった")
            checked += 1
        }
        XCTAssertEqual(checked, try fixtureNames().count)
    }

    /// ghostFlags/foldedGroups は Dictionary なので `==` は並び順に依らない——上の行集合比較より
    /// 強く、cache 経由の値が素の計算と**完全一致**することを直接確かめる
    func testCachedGhostFlagsAndFoldedGroupsMatchUncachedAcrossAllFixtures() throws {
        for name in try fixtureNames() {
            let snapshot = try fixture(name)
            let cache = MCPServer.SnapshotAnnotationCache()
            XCTAssertEqual(cache.ghostFlags(snapshot), MCPServer.ghostFlags(snapshot), name)
            let flags = cache.ghostFlags(snapshot)
            XCTAssertEqual(cache.foldedGroups(snapshot, flagging: flags, collapsingBulk: true),
                           SnapshotRenderer.foldedGroups(snapshot, flagging: flags, collapsingBulk: true),
                           name)
        }
    }

    /// 共有 SelectorNaming 経由の graded が、要素1件ずつ独立に採番したときと同じ結果を返すこと
    func testCachedGradedResultsMatchUncachedAcrossAllFixtures() throws {
        var compared = 0
        for name in try fixtureNames() {
            let snapshot = try fixture(name)
            let cache = MCPServer.SnapshotAnnotationCache()
            let naming = cache.selectorNaming(snapshot)
            let freshNaming = MCPServer.SelectorNaming(snapshot)
            for element in snapshot.elements {
                let cached = naming.graded(for: element, in: snapshot)
                let fresh = freshNaming.graded(for: element, in: snapshot)
                XCTAssertEqual(cached?.selector, fresh?.selector, "\(name) [\(element.ref)]")
                XCTAssertEqual(cached?.durability, fresh?.durability, "\(name) [\(element.ref)]")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 100, "1件も比較していない — このテストは何も検証していない")
    }

    // MARK: - 同じ要素の graded は1回(ambiguousLabelsNote と duplicateIDsNote の共有)

    /// 要素 [1] を「重複 id」の群と「曖昧ラベル」の群の**両方**に置く(実アプリで実測した形の再現)。
    /// **件数を厳密に固定する**(「独立計算より少ない」という緩い比較だと、どちらかの note が
    /// cache を丸ごと無視していても — その分の計算が cache に一切現れないので —
    /// 見かけ上「少ない」ままになり検出できない):
    /// - ambiguousLabelsNote だけで 3 (経路群 [1][4][5])
    /// - duplicateIDsNote を続けると +2 だけ (dup 群の新顔 [2][3]。[1] は再利用で 0 件増)
    func testSharedSelectorNamingSkipsElementsAlreadyGradedByTheOtherNote() throws {
        let snap = snapshot([
            // 重複 id の群(id="dup" ×3)。[1] は曖昧ラベルの群とも重なる
            element(1, id: "dup", label: "経路", y: 100),
            element(2, id: "dup", label: "A", y: 200),
            element(3, id: "dup", label: "B", y: 300),
            // 曖昧ラベルの群("経路" ×3)。[1] を再利用
            element(4, label: "経路", y: 400),
            element(5, label: "経路", y: 500),
        ])

        let shared = MCPServer.SnapshotAnnotationCache()
        _ = MCPServer.ambiguousLabelsNote(snap, cache: shared)
        XCTAssertEqual(shared.gradedComputeCount, 3,
                       "ambiguousLabelsNote が cache 経由で採番していない(想定: 経路群3件)")

        _ = MCPServer.duplicateIDsNote(snap, cache: shared)
        XCTAssertEqual(shared.gradedComputeCount, 5,
                       "duplicateIDsNote 後の総採番数が想定と違う(想定: +2 のみ。[1] の再採番"
                           + "= 共有していない、+3 未満 = duplicateIDsNote が cache を使っていない)")
    }

    // MARK: - foldedGroups は collapsingBulk ごとに別の答え(キーを混同していないか)

    /// collapsingBulk: false は常に空辞書を返す(SnapshotRenderer.foldedGroups の宣言)。
    /// true の結果を false のキーへ取り違えて返す・その逆をしていないかを両方向で確かめる
    func testFoldedGroupsCacheIsKeyedByCollapsingBulk() throws {
        // **type: "other" でなければ畳み対象にならない**(SnapshotRenderer.isDecorativeLeaf)
        let elements = (0..<25).map { element($0, type: "other", id: "bulk", y: Double($0) * 10) }
        let snap = snapshot(elements)
        let cache = MCPServer.SnapshotAnnotationCache()
        let flags = cache.ghostFlags(snap)

        let collapsed = cache.foldedGroups(snap, flagging: flags, collapsingBulk: true)
        XCTAssertFalse(collapsed.isEmpty, "25件同一 id は畳まれるはず — 前提が崩れている")

        let expanded = cache.foldedGroups(snap, flagging: flags, collapsingBulk: false)
        XCTAssertTrue(expanded.isEmpty, "collapsingBulk: false はキャッシュ越しでも空のはず")

        // 2回目の true 引きはキャッシュヒットで、内容は変わらない
        XCTAssertEqual(cache.foldedGroups(snap, flagging: flags, collapsingBulk: true), collapsed)
        XCTAssertEqual(cache.foldedGroupsComputeCount, 2, "true/false の2キーぶんだけ計算するはず")
    }

    // MARK: - snapshotBody(本物の呼び出し口)がすべての建て手へ cache を通していること

    /// 上のテストは静的関数を手で組み合わせた `buildCachedAnnotations` を通すが、それだけでは
    /// **production の組み立て口である `snapshotBody` 自身が cache を配線しているか**は見ない。
    /// ここは `MCPServer.snapshotBody` を直接呼び、ghostNote/ambiguousLabelsNote/duplicateIDsNote/
    /// render(の flagging 引数)の**全呼び出し経由**で1つの cache が使われることを固定する
    func testSnapshotBodyThreadsOneCacheThroughAllNoteBuilders() async throws {
        let driver = FakeDriver()
        driver.foregroundBundleID = "com.example.app"   // 無関係な note を黙らせる
        let snap = snapshot([
            element(1, id: "dup", label: "経路", y: 100),
            element(2, id: "dup", label: "A", y: 200),
            element(3, id: "dup", label: "B", y: 300),
            element(4, label: "経路", y: 400),
            element(5, label: "経路", y: 500),
        ])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let cache = MCPServer.SnapshotAnnotationCache()
        MCPServer.ghostFlagsComputations = 0
        let body = await server.snapshotBody(snap, driver: driver, args: [:], cache: cache)
        XCTAssertTrue(body.contains("#dup"), body)

        // **cache のカウンタではなく実計算の総数を見る**: cache 側だけを数えると、cache を
        // 渡し忘れた呼び出し(静的な ghostFlags へ直接落ちる)が1つあっても 1 のままになる
        XCTAssertEqual(MCPServer.ghostFlagsComputations, 1,
                       "snapshotBody の中で ghostFlags が複数回計算された"
                           + "(cache を渡していない呼び出しがある)")
        XCTAssertEqual(cache.ghostFlagsComputeCount, 1,
                       "snapshotBody 経由で ghostFlags が複数回計算された")
        XCTAssertEqual(cache.foldedGroupsComputeCount, 1,
                       "snapshotBody 経由で foldedGroups が複数回計算された")
        // 想定は testSharedSelectorNamingSkipsElementsAlreadyGradedByTheOtherNote と同じ内訳
        // (経路群3 + dup群の新顔2 = 5)。ambiguousLabelsNote/duplicateIDsNote のどちらかが
        // snapshotBody から cache を受け取れていなければここが動く
        XCTAssertEqual(cache.gradedComputeCount, 5,
                       "snapshotBody 経由で ambiguousLabelsNote/duplicateIDsNote が"
                           + " cache を共有していない")
    }

    /// **カウンタでは検出できない配線漏れの対策**(2026-08-12: mutation-check で発覚)。
    /// 「snapshotBody 内のある呼び手だけが cache 引数を渡し忘れる」変異は、後続の呼び手が
    /// 正しく同じ cache を使えばカウンタのつじつまが合ってしまい、上のテストをすり抜ける
    /// (ghostNote が cache を渡されず生計算→その後 duplicateIDsNote が正しく cache を引いて
    /// 1回ぶんだけ記録される、で合計は結局 1 のまま)。**値の出所**で確かめる:
    /// 明らかに間違った値を cache へ直接仕込み、応答にその値が現れるかで
    /// 「本当にこの cache インスタンスを読んだか」を見る
    func testSnapshotBodyGhostNoteAndRenderBothReadFromTheGivenCacheInstance() async throws {
        let driver = FakeDriver()
        driver.foregroundBundleID = "com.example.app"
        // ref 1 は画面内の普通の要素 — 素の計算では絶対に ⚠️offscreen が付かない
        let snap = snapshot([element(1, id: "solo", label: "X", y: 100)])
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        let cache = MCPServer.SnapshotAnnotationCache()
        cache.primeGhostFlagsForTesting([1: MCPServer.offscreenMark])

        let body = await server.snapshotBody(snap, driver: driver, args: [:], cache: cache)

        // ghostNote 自身の note に出る(ghostNote が cache.ghostFlags を読んだ証拠)
        XCTAssertTrue(body.contains("⚠️offscreen rows below"), body)
        // render の行末にも付く(render が cache.ghostFlags(...) を読んだ証拠——
        // 生の MCPServer.ghostFlags を直呼びしていたら、この要素は画面内なので印が付かない)
        XCTAssertTrue(body.contains("id=solo (0,100 100x40) ⚠️offscreen"), body)
    }

    // MARK: - キャッシュの寿命は1回の応答組み立てだけ(陽性対照)

    /// 木を変えて2回続けて組み立て、2回目が**新しい木**の答えを返すこと。
    /// snapshotBody は呼ばれるたびに新しい SnapshotAnnotationCache を作る(既定 cache: nil)ので、
    /// ここは production の経路(MCPServer + ft_snapshot)をそのまま通して確かめる
    func testConsecutiveSnapshotsDoNotLeakThePreviousTreesAnnotations() async throws {
        let driver = FakeDriver()
        driver.foregroundBundleID = "com.example.app"   // 無関係な note を黙らせる
        let treeWithDuplicateIDs = snapshot([
            element(1, id: "dup", label: "A", y: 100),
            element(2, id: "dup", label: "B", y: 200),
        ])
        let treeWithoutDuplicates = snapshot([
            element(1, id: "unique_a", label: "A", y: 100),
            element(2, id: "unique_b", label: "B", y: 200),
        ])
        driver.scriptedSnapshots = [treeWithDuplicateIDs, treeWithoutDuplicates]
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })

        func bodyText(_ content: [[String: Any]]) -> String {
            content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }

        let first = bodyText(try await server.call(tool: "ft_snapshot", args: [:]))
        XCTAssertTrue(first.contains("#dup ×2"), first)

        let second = bodyText(try await server.call(tool: "ft_snapshot", args: [:]))
        XCTAssertFalse(second.contains("#dup"),
                       "2回目の応答に1回目の木の重複 id 注記が残っている(キャッシュが応答を跨いだ)")
        XCTAssertTrue(second.contains("id=unique_a"), second)
    }
}
