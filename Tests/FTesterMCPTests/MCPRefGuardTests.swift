// ref を撃つ直前の照合(RefGuard と MCPServer.verifiedRef / freshSnapshot)。
//
// ここが未検証だと、2026-08-06 に Simulator/Emulator 上で決定的に再現した3形が戻る:
//   - Android/Compose のスクロール後、木が古いまま固まり ref が別要素を叩く
//   - Compose iOS の容器外 ghost を xcuitest が座標で叩き、下部タブを踏む
//   - どちらもツールは "tap done" を返す(沈黙した誤操作)

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPRefGuardTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    private func element(ref: Int, type: String = "Button", id: String? = nil,
                         label: String? = nil, x: Double, y: Double,
                         w: Double = 100, h: Double = 40, depth: Int = 2) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: depth)
    }

    /// 前面判定(backgroundedSessionNote)の往復は本題ではないので落とす
    private var actions: [String] { driver.calls.filter { !$0.hasPrefix("isAppForeground") } }

    private func screen(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                         elements: elements, truncatedCount: 0)
    }

    // MARK: - キャッシュを捨てて撮る(A-1)

    /// **MCP の snapshot は必ずキャッシュを捨てる**。Android の a11y ツリーは Compose の
    /// スクロール後に古いまま固まり、撮り直しても直らない(実測)
    func testSnapshotAlwaysBypassesTheCacheWhenTheDriverSupportsIt() async throws {
        driver.supportsCacheBypass = true
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        XCTAssertEqual(actions, ["snapshot(fresh)"])
    }

    /// 対応しないドライバ(iOS)では素通し = 無駄な往復を増やさない
    func testSnapshotDoesNotAskForABypassWhenTheDriverCannotDoIt() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        XCTAssertEqual(actions, ["snapshot"])
    }

    // MARK: - 撃つ直前の照合(A-1 / A-2)

    /// 前回の木を覚えていなければ素通し(照合の起点が無いので嘘の判断をしない)
    func testTapWithoutAPriorSnapshotPassesTheRefStraightThrough() async throws {
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
        XCTAssertEqual(actions, ["tap(ref:1)"])
    }

    /// **要素が動いていたら新しい ref へ撃ち直す**。ref はスナップショットごとに振り直されるので、
    /// 覚えた番号のまま撃つと別の要素に当たる(Android/Compose のスクロール後に決定的に起きる)
    func testTapRetargetsToTheFreshRefWhenTheElementMoved() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, id: "row_01", label: "行 01", x: 10, y: 100),
            element(ref: 2, id: "row_02", label: "行 02", x: 10, y: 200),
        ])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        // スクロールして番号も位置も変わった木
        driver.snapshotResponse = screen([
            element(ref: 1, id: "row_02", label: "行 02", x: 10, y: 100),
            element(ref: 2, id: "row_03", label: "行 03", x: 10, y: 200),
        ])
        let result = try await server.call(tool: "ft_tap", args: ["ref": 2])
        XCTAssertEqual(actions, ["snapshot", "snapshot", "tap(ref:1)"],
                       "撮り直して #row_02 の新しい ref(1)へ撃ち直すこと")
        XCTAssertTrue(Self.text(result).contains("had moved"), "動いたことを応答に載せること")
    }

    /// 消えた要素は**撃たずに**理由を返す(黙って別の要素を叩かない)
    func testTapRefusesWhenTheElementIsGone() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "row_01", label: "行 01", x: 10, y: 100)])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.snapshotResponse = screen([element(ref: 1, id: "row_99", label: "行 99", x: 10, y: 100)])
        do {
            _ = try await server.call(tool: "ft_tap", args: ["ref": 1])
            XCTFail("消えた要素へのタップは throw するはず")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("#row_01"))
            XCTAssertTrue(error.localizedDescription.contains("no longer in the tree"))
        }
        XCTAssertFalse(actions.contains { $0.hasPrefix("tap") }, "撃ってはいけない")
    }

    /// **容器の外に居る要素も撃つ。ただし黙って撃たない**(2026-08-06 に拒否から後退)。
    /// 木の幾何だけでは「実際に描かれているか」を決められず、押せる要素を押せなくする害が
    /// 5形続いた。情報を渡して判断はエージェントに委ねる
    func testTapWarnsInsteadOfRefusingForAScrollLeftover() async throws {
        let tree = [
            element(ref: 1, type: "Other", id: "list", label: nil, x: 0, y: 100, w: 390, h: 200, depth: 1),
            element(ref: 2, id: "row_01", label: "行 01", x: 10, y: 110, depth: 2),
            element(ref: 3, id: "row_02", label: "行 02", x: 10, y: 160, depth: 2),
            element(ref: 4, id: "row_09", label: "行 09", x: 10, y: 700, w: 370, h: 40, depth: 2),
            element(ref: 5, id: "tab_home", label: "ホーム", x: 130, y: 700, w: 130, h: 48, depth: 1),
        ]
        driver.snapshotResponse = screen(tree)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let result = try await server.call(tool: "ft_tap", args: ["ref": 4])
        XCTAssertTrue(actions.contains { $0.hasPrefix("tap") }, "撃つこと")
        let text = Self.text(result)
        XCTAssertTrue(text.contains("#row_09"), text)
        XCTAssertTrue(text.contains("#tab_home"), "何に当たったかもしれないかを言うこと")
        XCTAssertTrue(text.contains("ft_screenshot"), "確かめ方を出すこと")
    }

    /// 一覧そのものからは ghost を見分けられないので、**撮った時点で名指しする**
    func testSnapshotNamesGhostsAtTheTop() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "Other", id: "list", label: nil, x: 0, y: 100, w: 390, h: 200, depth: 1),
            element(ref: 2, id: "row_01", label: "行 01", x: 10, y: 110, depth: 2),
            element(ref: 3, id: "row_02", label: "行 02", x: 10, y: 160, depth: 2),
            element(ref: 4, id: "row_09", label: "行 09", x: 10, y: 700, w: 370, h: 40, depth: 2),
            // 実機と同じ形にする: **タブは行の一部にしか重ならない**(丸ごと包む相手は容器なので
            // 遮蔽に数えない。包む形にすると、この防御が何も検出しないテストになる)
            element(ref: 5, id: "tab_home", label: "ホーム", x: 130, y: 700, w: 130, h: 48, depth: 1),
        ])
        let rendered = Self.text(try await server.call(tool: "ft_snapshot", args: [:]))
        XCTAssertTrue(rendered.contains("outside their scroll container"))
        XCTAssertTrue(rendered.contains("[4] #row_09"))
        XCTAssertFalse(rendered.contains("[2] #row_01"), "容器の中の行を ghost 扱いしない")
    }

    /// **容器の外に居るだけでは拒否しない**。ホーム画面の dock がこの形で、
    /// 容器の推測から外れた位置に出るが、その座標にはそれ自身しか無いので普通に押せる
    /// (2026-08-06 の外部フィードバックで、dock が押せなくなっていたのが発覚)
    func testElementOutsideItsContainerIsTappableWhenNothingCoversIt() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "Other", id: "page", label: nil, x: 0, y: 100, w: 390, h: 400, depth: 1),
            element(ref: 2, id: "icon_a", label: "A", x: 10, y: 110, depth: 2),
            element(ref: 3, id: "icon_b", label: "B", x: 10, y: 160, depth: 2),
            element(ref: 4, id: "Safari", label: "Safari", x: 120, y: 770, w: 68, h: 68, depth: 2),
        ])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 4])
        XCTAssertTrue(actions.contains { $0.hasPrefix("tap") }, "撃てること(残像でないので警告も出ない)")
    }

    /// **自分を丸ごと包む相手は遮蔽ではなく容器**。設定アプリの検索を開いた状態で
    /// 「閉じる」が弾かれた形(覆っていたのは全画面の減光レイヤーと toolbar)。
    /// 座標タップでは正しく閉じられた = 判定が誤りだったことが確定している
    func testFullScreenContainersAreNotOccluders() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "Other", id: "page", label: nil, x: 0, y: 100, w: 390, h: 300, depth: 1),
            element(ref: 2, id: "row_a", label: "A", x: 10, y: 110, depth: 2),
            element(ref: 3, id: "row_b", label: "B", x: 10, y: 160, depth: 2),
            // 容器の外に出た「閉じる」。中心を覆うのは全画面の減光レイヤーだけ
            element(ref: 4, id: "close", label: "閉じる", x: 351, y: 485, w: 38, h: 38, depth: 2),
            element(ref: 5, type: "Other", id: "AdditionalDimmingOverlay", label: nil,
                    x: 0, y: 0, w: 390, h: 844, depth: 1),
        ])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 4])
        XCTAssertTrue(actions.contains { $0.hasPrefix("tap") }, "包む相手しか無いなら撃てること")
    }

    /// **描かれていないものは何も覆えない**。報告された形をそのまま固定する:
    /// 設定アプリの検索で「閉じる」を弾いていたのは、スクロールで画面外へ出たリスト行の容器。
    /// 矩形は包含にもならない位置関係なので、**包含の除外では守れない**
    func testAGhostCannotOccludeAnything() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "Other", id: "list", label: nil, x: 16, y: 100, w: 370, h: 300, depth: 1),
            element(ref: 2, id: "row_a", label: "A", x: 16, y: 110, w: 370, h: 52, depth: 2),
            element(ref: 3, id: "row_b", label: "B", x: 16, y: 170, w: 370, h: 52, depth: 2),
            // 容器(y100..400)の外へ出たリスト行 = それ自身が残像。描かれていない
            element(ref: 4, type: "Clickable", id: nil, label: nil, x: 16, y: 484, w: 370, h: 52, depth: 2),
            // 検索の「閉じる」。中心 (366,497) は ref 4 の矩形の中だが、**包含はされない**
            // (上端が上へはみ出す)ので、「残像は覆えない」規則だけが救う
            element(ref: 5, id: "close", label: "閉じる", x: 347, y: 478, w: 38, h: 38, depth: 2),
        ])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 5])
        XCTAssertTrue(actions.contains { $0.hasPrefix("tap") },
                      "覆っている側が残像なら遮蔽に数えないこと")
    }

    /// 同じラベルの Button と StaticText が並ぶ形で取り違えないこと(型も見る)
    func testRelocateDoesNotSwapAcrossTypesWithTheSameLabel() {
        let target = element(ref: 1, type: "Button", id: nil, label: "共通ラベル", x: 10, y: 100)
        let fresh = [
            element(ref: 1, type: "StaticText", id: nil, label: "共通ラベル", x: 10, y: 100),
            element(ref: 2, type: "Button", id: nil, label: "共通ラベル", x: 10, y: 200),
        ]
        guard case .found(let hit, _) = RefGuard.relocate(target, in: fresh) else {
            return XCTFail("引き直せるはず")
        }
        XCTAssertEqual(hit.ref, 2, "同じ型のほうを採ること")
    }

    /// identifier があるのに新しい木に無ければ**ラベルで拾い直さない**(別要素を掴む)
    func testRelocateDoesNotFallBackToLabelWhenTheIdentifierIsGone() {
        let target = element(ref: 1, id: "btn_a", label: "送信", x: 10, y: 100)
        let fresh = [element(ref: 1, id: "btn_b", label: "送信", x: 10, y: 100)]
        guard case .gone = RefGuard.relocate(target, in: fresh) else {
            return XCTFail("gone を返すはず")
        }
    }

    // MARK: - 応答に載せる助言(外部フィードバック 2026-08-06)

    /// **残像の行そのものに印**が要る。先頭の注記だけだと、一覧から ref をコピーする動作に届かない
    func testGhostFlagsMarkOnlyTheLeftoverRows() {
        let snapshot = screen([
            element(ref: 1, type: "Other", id: "list", label: nil, x: 0, y: 100, w: 390, h: 200, depth: 1),
            element(ref: 2, id: "row_01", label: "行 01", x: 10, y: 110, depth: 2),
            element(ref: 3, id: "row_02", label: "行 02", x: 10, y: 160, depth: 2),
            element(ref: 4, id: "row_09", label: "行 09", x: 10, y: 700, w: 370, h: 40, depth: 2),
            // 実機と同じ形にする: **タブは行の一部にしか重ならない**(丸ごと包む相手は容器なので
            // 遮蔽に数えない。包む形にすると、この防御が何も検出しないテストになる)
            element(ref: 5, id: "tab_home", label: "ホーム", x: 130, y: 700, w: 130, h: 48, depth: 1),
        ])
        let flags = MCPServer.ghostFlags(snapshot)
        XCTAssertEqual(Set(flags.keys), [4], "容器の外の1件だけに印が付くこと")
        XCTAssertTrue(SnapshotRenderer.render(snapshot, flagging: flags)
            .contains("id=row_09 (10,700 370x40) ⚠️scroll-leftover"))
    }

    /// 探索が空振りしたら「そこに何があったか」を返す。**往復を1回省く**のと、
    /// 素のラベルが完全一致であることに気づかせるのが目的
    func testVisibleLabelsHintListsWhatCanActuallyBeSelected() {
        let snapshot = screen([
            element(ref: 1, id: "btn_back", label: "戻る", x: 0, y: 0),
            element(ref: 2, type: "StaticText", id: nil, label: "端末情報を表示", x: 0, y: 50),
            element(ref: 3, type: "Other", id: nil, label: nil, x: 0, y: 90),
        ])
        let hint = MCPServer.visibleLabelsHint(snapshot)
        XCTAssertTrue(hint.contains("#btn_back"))
        XCTAssertTrue(hint.contains("\"端末情報を表示\""), "id が無い要素はラベルで出すこと")
        XCTAssertFalse(hint.contains("()"), "名前を持たない要素は載せない")
    }

    /// 20 件で打ち切る(全部並べると読めない。足りなければ ft_snapshot を撮ればよい)
    func testVisibleLabelsHintIsCapped() {
        let many = (1...40).map { element(ref: $0, id: "id_\($0)", label: nil, x: 0, y: Double($0)) }
        let hint = MCPServer.visibleLabelsHint(screen(many))
        XCTAssertEqual(hint.components(separatedBy: "#id_").count - 1, 20)
        XCTAssertTrue(hint.hasSuffix("…."))
    }

    private static func text(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
