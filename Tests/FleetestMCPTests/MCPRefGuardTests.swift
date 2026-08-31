// ref を撃つ直前の照合(RefGuard と MCPServer.verifiedRef / freshSnapshot)。
//
// ここが未検証だと、2026-08-06 に Simulator/Emulator 上で決定的に再現した3形が戻る:
//   - Android/Compose のスクロール後、木が古いまま固まり ref が別要素を叩く
//   - Compose iOS の容器外 ghost を xcuitest が座標で叩き、下部タブを踏む
//   - どちらもツールは "tap done" を返す(沈黙した誤操作)

import XCTest
import FTCore
@testable import fleetest_mcp

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
    private var actions: [String] { driver.calls.filter { !$0.hasPrefix("isAppForeground") && !$0.hasPrefix("hitTest") && !$0.hasPrefix("systemUICovering") } }

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
        // systemAlert は verifiedRef の screenNotRepresentedWarning が毎タップ聞く探針(撃つ前に1回)
        XCTAssertEqual(actions, ["snapshot", "snapshot", "systemAlert", "tap(ref:1)"],
                       "撮り直して #row_02 の新しい ref(1)へ撃ち直すこと")
        XCTAssertTrue(Self.text(result).contains("had moved"), "動いたことを応答に載せること")
    }

    // MARK: - 再ターゲット時のラベル変化(2026-08-10 の実アプリ監査)

    /// **同一 id で再ターゲットしたら、ラベルが変わっていないかも見る**。identifier だけで
    /// 引き直すと、検索候補が更新された画面では同じ id・別の行を掴むことがある
    /// (実測: 「立川駅、最近表示した項目」を狙ったタップが「立川駅 南口、立川市」に化けた)
    func testTapWarnsWhenTheRetargetedElementHasADifferentLabel() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, id: "row", label: "立川駅、最近表示した項目", x: 10, y: 100),
        ])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.snapshotResponse = screen([
            element(ref: 1, id: "row", label: "立川駅 南口、立川市", x: 10, y: 200),
        ])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("label has changed"), text)
        XCTAssertTrue(text.contains("立川駅、最近表示した項目"), text)
        XCTAssertTrue(text.contains("立川駅 南口、立川市"), text)
    }

    /// ラベルが同じままなら何も言わない(誤検知を増やさない)
    func testTapStaysQuietWhenTheRetargetedElementHasTheSameLabel() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "row", label: "行 01", x: 10, y: 100)])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.snapshotResponse = screen([element(ref: 1, id: "row", label: "行 01", x: 10, y: 200)])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertFalse(text.contains("label has changed"), text)
    }

    /// **動いていなくても出す**: ラベルだけ変わって位置が同じ形も同じ危険
    func testTapWarnsOnLabelChangeEvenWithoutMovement() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "row", label: "行 01", x: 10, y: 100)])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.snapshotResponse = screen([element(ref: 1, id: "row", label: "行 99", x: 10, y: 100)])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("label has changed"), text)
        XCTAssertFalse(text.contains("had moved"), text)
    }

    /// **同型の掃討**: double_tap/pinch/drag(fromRef) も再ターゲットして実際に操作を撃つ経路
    /// なので、同じ警告が要る(verifiedElement 経由)
    func testDoubleTapWarnsWhenTheRetargetedElementHasADifferentLabel() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "row", label: "行 01", x: 10, y: 100)])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.snapshotResponse = screen([element(ref: 1, id: "row", label: "行 99", x: 10, y: 100)])
        let text = Self.text(try await server.call(tool: "ft_double_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("label has changed"), text)
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

    // MARK: - 欠陥③④(2026-08-07 の Android Emulator 探索)

    /// **欠陥③**: 何も描いていない葉コンテナ(label/value 空・子孫なし・type=other)は
    /// 遮蔽候補から除外する。実測: `#compass_container`(全幅・非 clickable・葉)が起動直後の
    /// 「スキップ」ボタンを遮蔽扱いしたが、タップは正常に成功していた
    func testBlankLeafContainerDoesNotOccludeAnything() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, id: "btn_skip", label: "スキップ", x: 150, y: 700, w: 100, h: 40, depth: 1),
            // 何も描いていない葉コンテナ。ボタンの中心を覆うが、完全には包まない
            // (包む形にすると欠陥④側の面積判定だけで救われてしまい、③の検証にならない)
            element(ref: 2, type: "Other", id: "compass_container", label: nil,
                    x: 0, y: 680, w: 200, h: 80, depth: 1),
        ])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertFalse(text.contains("warning"), "空の葉コンテナは遮蔽に数えないこと: \(text)")
    }

    /// 葉コンテナでも label を持てば除外しない(実際に何か描いている可能性を捨てない)。
    /// ③の除外条件が広すぎないことの確認
    func testLeafContainerWithLabelStillOccludes() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, id: "btn_skip", label: "スキップ", x: 150, y: 700, w: 100, h: 40, depth: 1),
            element(ref: 2, type: "Other", id: "banner", label: "広告",
                    x: 0, y: 680, w: 200, h: 80, depth: 1),
        ])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("warning"), "label を持つ葉は除外しないこと: \(text)")
    }

    /// **欠陥④**: 完全包含でも画面の半分未満の相手は容器ではなく遮蔽として拾う。実測:
    /// app bar (0,0 1080x290) が画面(1080x2424)の 12% しかないのに、下に潜った行
    /// `#transit_station_title_name` への遮蔽が「丸ごと包む相手は容器」規則で無警告になっていた。
    /// header_container に子(#btn_back)を持たせて③の葉除外を経由しないことを保証する
    func testPartialCoverageContainerBelowThresholdOccludes() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 1080, height: 2424),
            elements: [
                element(ref: 1, id: "transit_station_title_name", label: "東京駅",
                        x: 285, y: 0, w: 510, h: 85, depth: 1),
                element(ref: 2, type: "Other", id: "header_container", label: nil,
                        x: 0, y: 0, w: 1080, h: 290, depth: 1),
                element(ref: 3, id: "btn_back", label: "戻る", x: 20, y: 20, w: 60, h: 60, depth: 2),
            ],
            truncatedCount: 0)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("#header_container"),
                      "画面の一部でしかない app bar は遮蔽として拾うこと: \(text)")
    }

    /// 画面規模(閾値以上)の相手は従来どおり容器のまま(退行防止)。
    /// `testFullScreenContainersAreNotOccluders` の 390x844 全画面 overlay と同じ形を、
    /// 閾値ちょうど上のケースとしてもう一度固定する
    func testScreenScaleContainerStaysSuppressedAboveThreshold() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 1080, height: 2424),
            elements: [
                element(ref: 1, id: "row", label: "行", x: 100, y: 100, w: 200, h: 60, depth: 1),
                // 画面の 60% を占める大きな容器(子を持つので③の葉除外は経由しない)
                element(ref: 2, type: "Other", id: "sheet", label: nil,
                        x: 0, y: 0, w: 1080, h: 1500, depth: 1),
                element(ref: 3, id: "sheet_title", label: "見出し", x: 40, y: 40, w: 200, h: 40, depth: 2),
            ],
            truncatedCount: 0)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertFalse(text.contains("warning"), "画面規模の相手は容器のままにすること: \(text)")
    }

    /// **欠陥⑤**: 同一矩形のラッパー連鎖は「描画内容を持つもの」だけを数える。実測:
    /// `#expandingscrollview_container`/`#cardui_cardlist`/`#recycler_view`/
    /// `#home_bottom_sheet_container`(全部同じ矩形・全部 label/value 空)の4件が
    /// leftover 扱いされたが、実際は普通のボトムシートだった。**入れ子ではなく兄弟**にして
    /// 一本鎖の除外(既存規則)を経由せず、新しい「描画内容を数える」規則だけを試す
    func testBlankWrapperStackDoesNotFlagAsLeftover() async throws {
        let ids = ["expandingscrollview_container", "cardui_cardlist",
                   "recycler_view", "home_bottom_sheet_container"]
        let wrappers = ids.enumerated().map { index, id in
            element(ref: index + 1, type: "Other", id: id, label: nil,
                    x: 0, y: 565, w: 1080, h: 1859, depth: 1)
        }
        driver.snapshotResponse = screen(wrappers)
        let rendered = Self.text(try await server.call(tool: "ft_snapshot", args: [:]))
        XCTAssertFalse(rendered.contains("⚠️"), rendered)
    }

    /// 同じラベルの Button と StaticText が並ぶ形で取り違えないこと(型も見る)
    func testRelocateDoesNotSwapAcrossTypesWithTheSameLabel() {
        let target = element(ref: 1, type: "Button", id: nil, label: "共通ラベル", x: 10, y: 100)
        let fresh = [
            element(ref: 1, type: "StaticText", id: nil, label: "共通ラベル", x: 10, y: 100),
            element(ref: 2, type: "Button", id: nil, label: "共通ラベル", x: 10, y: 200),
        ]
        let testScreen = FTRect(x: 0, y: 0, width: 390, height: 844)
        guard case .found(let hit, _) = RefGuard.relocate(target, in: fresh, screen: testScreen) else {
            return XCTFail("引き直せるはず")
        }
        XCTAssertEqual(hit.ref, 2, "同じ型のほうを採ること")
    }

    /// identifier があるのに新しい木に無ければ**ラベルで拾い直さない**(別要素を掴む)
    func testRelocateDoesNotFallBackToLabelWhenTheIdentifierIsGone() {
        let target = element(ref: 1, id: "btn_a", label: "送信", x: 10, y: 100)
        let fresh = [element(ref: 1, id: "btn_b", label: "送信", x: 10, y: 100)]
        let testScreen = FTRect(x: 0, y: 0, width: 390, height: 844)
        guard case .gone = RefGuard.relocate(target, in: fresh, screen: testScreen) else {
            return XCTFail("gone を返すはず")
        }
    }

    /// **同一 id の複数候補は「元の frame に最も近い」ほうを採る**(隣の行へ化けない)。
    /// `RefGuard.match` は identifier 一致の候補から nearest(frame 中心距離)を選ぶ ——
    /// index ではないので、同じ操作(画面の微小な再構成)で両方向とも自分の行へ戻ることを固定する
    /// (2026-08-10。RefGuard.match/nearest の調査結果を固定するリグレッションテスト)
    func testRelocateWithDuplicateIdPicksTheNearestFrameNotTheOtherRow() {
        let originTarget = element(ref: 1, id: "route_candidate", label: "経路A", x: 10, y: 100)
        let destinationTarget = element(ref: 2, id: "route_candidate", label: "経路B", x: 10, y: 300)
        // 画面再構成で両行とも少しだけ動く(+5pt)。元の位置に近いほうを採ること
        let fresh = [
            element(ref: 10, id: "route_candidate", label: "経路A", x: 10, y: 105),
            element(ref: 11, id: "route_candidate", label: "経路B", x: 10, y: 305),
        ]
        let testScreen = FTRect(x: 0, y: 0, width: 390, height: 844)
        guard case .found(let hitFromOrigin, _) = RefGuard.relocate(
            originTarget, in: fresh, screen: testScreen) else {
            return XCTFail("引き直せるはず")
        }
        XCTAssertEqual(hitFromOrigin.ref, 10, "旧 frame(y=100)に近い上の行に着地すること")
        guard case .found(let hitFromDestination, _) = RefGuard.relocate(
            destinationTarget, in: fresh, screen: testScreen) else {
            return XCTFail("引き直せるはず")
        }
        XCTAssertEqual(hitFromDestination.ref, 11, "旧 frame(y=300)に近い下の行に着地すること")
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

    /// **chrome-pinned な下部タブは ⚠️scroll-leftover を出さない**(and-sutec_home の witness。
    /// Android ブリッジが無ラベルの NavigationBar を間引き、タブが `#screen_home` の子に
    /// 再配線される形。StepExecutor.isChromePinnedOutside の doc を参照)
    func testChromePinnedBottomTabsAreNotFlaggedAsScrollLeftovers() {
        let testScreen = FTRect(x: 0, y: 0, width: 1080, height: 2340)
        let scroller = ElementInfo(ref: 1, type: "scrollView", identifier: "screen_home",
                                   label: nil, value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 136, width: 1080, height: 1918), depth: 9,
                                   scrollable: true)
        let headingA = element(ref: 2, type: "StaticText", label: "SUT Store",
                              x: 44, y: 180, w: 269, h: 71, depth: 10)
        let headingB = element(ref: 7, type: "StaticText", label: "カテゴリ",
                              x: 44, y: 867, w: 176, h: 64, depth: 10)
        let tabHome = element(ref: 46, type: "Other", id: "tab_home",
                              x: 0, y: 2054, w: 199, h: 220, depth: 10)
        let tabSearch = element(ref: 48, id: "tab_search", label: "検索",
                                x: 221, y: 2054, w: 199, h: 220, depth: 10)
        let snapshot = SnapshotResponse(sessionBundleID: nil, screen: testScreen,
                                        elements: [scroller, headingA, headingB, tabHome, tabSearch],
                                        truncatedCount: 0)

        XCTAssertEqual(RefGuard.scrolledOutWarning(tabHome, in: snapshot.elements,
                                                   screen: snapshot.screen), "")
        let flags = MCPServer.ghostFlags(snapshot)
        XCTAssertNil(flags[tabHome.ref], "下部タブに ⚠️scroll-leftover が付いていないこと")
    }

    // MARK: - offscreen 注記の方向分け

    /// 主方向は**はみ出し量が大きい軸**で決まる(斜めにはみ出す要素も1方向へ丸める)
    func testOffscreenDirectionPicksTheAxisWithTheLargerOverflow() {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertEqual(MCPServer.offscreenDirection(
            of: element(ref: 1, x: 100, y: 850, w: 10, h: 10), screen: screen), .below)
        XCTAssertEqual(MCPServer.offscreenDirection(
            of: element(ref: 2, x: 100, y: -60, w: 10, h: 10), screen: screen), .above)
        XCTAssertEqual(MCPServer.offscreenDirection(
            of: element(ref: 3, x: 401, y: 100, w: 10, h: 10), screen: screen), .right)
        XCTAssertEqual(MCPServer.offscreenDirection(
            of: element(ref: 4, x: -60, y: 100, w: 10, h: 10), screen: screen), .left)
        // 斜め: 右への超過(centre 405-400=5)より下への超過(centre 830-800=30)のほうが大きい
        XCTAssertEqual(MCPServer.offscreenDirection(
            of: element(ref: 5, x: 400, y: 825, w: 10, h: 10), screen: screen), .below)
    }

    /// スクロール容器を明示宣言した矩形(`outsideDeclaredScroller` が拾う形。ghostFlags が
    /// 印を付けるにはまず ghost/容器外と判定される必要があり、単に画面外というだけでは
    /// 印が付かない — 既存の testScrolledOutRowsAreFlaggedInTheListing と同じ組み方)
    private func scroller(ref: Int, frame: FTRect, depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: "Other", identifier: "scroller", label: nil, value: nil,
                    placeholder: nil, enabled: true, frame: frame, depth: depth, scrollable: true)
    }

    /// 実例(Apple マップの経路候補・横ページャ): 第2候補は一度も表示していないのに
    /// 旧文言「scrolled past」は不正確だった。方向見出しを出し、その語は使わない
    func testGhostNoteOffscreenSectionNamesTheDirectionInsteadOfScrolledPast() {
        let snapshot = screen([
            scroller(ref: 1, frame: FTRect(x: 0, y: 100, width: 390, height: 600)),
            element(ref: 2, id: "row_a", label: "行A", x: 10, y: 110),
            element(ref: 3, id: "row_b", label: "行B", x: 10, y: 160),
            // 右隣ページ(横ページャ)。scroller と交差しない(x が重ならない)= 容器の外、
            // かつ画面の外(x=401 > 画面幅390)
            element(ref: 4, id: "route_b", label: "経路B", x: 401, y: 110),
        ])
        let note = MCPServer.ghostNote(snapshot)
        XCTAssertFalse(note.contains("scrolled past"), note)
        XCTAssertTrue(note.contains("to the right:"), note)
        XCTAssertTrue(note.contains("direction: right"), note)
        XCTAssertTrue(note.contains("[4] #route_b"), note)
    }

    /// 複数方向にはみ出す画面では方向ごとに列挙し、direction もその集合だけ出す
    func testGhostNoteOffscreenSectionGroupsMultipleDirections() {
        let snapshot = screen([
            scroller(ref: 1, frame: FTRect(x: 0, y: 100, width: 390, height: 600)),
            element(ref: 2, id: "row_a", label: "行A", x: 10, y: 110),
            element(ref: 3, id: "row_b", label: "行B", x: 10, y: 160),
            element(ref: 4, id: "below_a", label: "下A", x: 10, y: 900),
            element(ref: 5, id: "below_b", label: "下B", x: 10, y: 950),
            element(ref: 6, id: "right_a", label: "右A", x: 401, y: 110),
        ])
        let note = MCPServer.ghostNote(snapshot)
        XCTAssertTrue(note.contains("below: [4] #below_a [5] #below_b"), note)
        XCTAssertTrue(note.contains("to the right: [6] #right_a"), note)
        XCTAssertTrue(note.contains("direction: down / right"), note)
    }

    /// pageIndicator を模す要素(型は `#id` を持たない前提と揃え、value を「n of m」表示に見立てる)
    private func pager(value: String, ref: Int = 10) -> ElementInfo {
        ElementInfo(ref: ref, type: "pageIndicator", identifier: nil, label: nil, value: value,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 150, y: 780, width: 90, height: 20), depth: 1)
    }

    /// 横ページャの誘導。実例(Apple マップの経路候補・横ページャ): 右隣ページの行は
    /// 「消えた」のではなく他のページに居るだけで、pageIndicator が実在するときだけ言い換えを添える
    func testGhostNoteOffscreenSectionMentionsAPageIndicatorForARightOffscreenRow() {
        let snapshot = screen([
            scroller(ref: 1, frame: FTRect(x: 0, y: 100, width: 390, height: 600)),
            element(ref: 2, id: "row_a", label: "行A", x: 10, y: 110),
            element(ref: 3, id: "row_b", label: "行B", x: 10, y: 160),
            element(ref: 4, id: "route_b", label: "経路B", x: 401, y: 110),
            pager(value: "2 of 5"),
        ])
        let note = MCPServer.ghostNote(snapshot)
        XCTAssertTrue(note.contains("horizontal pager"), note)
        XCTAssertTrue(note.contains("\"2 of 5\""), note)
        XCTAssertTrue(note.contains("ft_scroll_to (direction: right)"), note)
    }

    /// pageIndicator が無い画面では言い換えを足さない(断定材料が無い)
    func testGhostNoteOffscreenSectionStaysQuietWithoutAPageIndicator() {
        let snapshot = screen([
            scroller(ref: 1, frame: FTRect(x: 0, y: 100, width: 390, height: 600)),
            element(ref: 2, id: "row_a", label: "行A", x: 10, y: 110),
            element(ref: 3, id: "row_b", label: "行B", x: 10, y: 160),
            element(ref: 4, id: "route_b", label: "経路B", x: 401, y: 110),
        ])
        let note = MCPServer.ghostNote(snapshot)
        XCTAssertFalse(note.contains("horizontal pager"), note)
    }

    /// below だけの offscreen(縦方向)では、pageIndicator が居ても足さない —— 横ページャの話とは無関係
    func testGhostNoteOffscreenSectionIgnoresAPageIndicatorForVerticalOnlyOffscreen() {
        // outsideDeclaredScroller は「容器の中に同じ depth の兄弟が2件以上」を要求する
        // (hasSiblingsInside)。row_a 単独では below_a がそもそも ghost 判定されないので、
        // 既存の testGhostNoteOffscreenSectionGroupsMultipleDirections と同じく row_b も置く
        let snapshot = screen([
            scroller(ref: 1, frame: FTRect(x: 0, y: 100, width: 390, height: 600)),
            element(ref: 2, id: "row_a", label: "行A", x: 10, y: 110),
            element(ref: 3, id: "row_b", label: "行B", x: 10, y: 160),
            element(ref: 4, id: "below_a", label: "下A", x: 10, y: 900),
            pager(value: "2 of 5"),
        ])
        let note = MCPServer.ghostNote(snapshot)
        XCTAssertTrue(note.contains("below:"), note) // 前提: below の offscreen 自体は出ている
        XCTAssertFalse(note.contains("horizontal pager"), note)
    }

    // MARK: - 探索そのものが画面を変えたら成功と言わない

    /// 探索のスワイプは**タップ可能な行を発火させることがある**(SwiftUI の SUT で実測)。
    /// そのとき executor は途中の観測で passed のまま、撮り直した木は別画面になる。
    /// 決定的再現: E2E-iOS のホームで `ft_scroll_to #nav_diagnostics` が
    /// 「scrolled to "#nav_diagnostics"」+ その id が居ない診断画面の木、を返していた
    func testScrollToFailsWhenTheTargetIsGoneFromTheTreeItReturns() async throws {
        let onScreen = screen([element(ref: 1, id: "nav_diagnostics", label: "診断", x: 16, y: 100)])
        let afterNavigation = screen([element(ref: 1, type: "StaticText", id: "txt_build_info",
                                              label: "build=1.0.0", x: 16, y: 100)])
        // **枚数は実測で固定**: scrollTo は executor が 2 枚 + 撮り直し 1 枚の計 3 枚撮る。
        // 台本は尽きると最後の1枚を返し続けるので、3枚目に別画面を置けば
        // 「executor は見つけた / 返す木には居ない」を作れる
        driver.scriptedSnapshots = [onScreen, onScreen, afterNavigation]
        do {
            _ = try await server.call(tool: "ft_scroll_to", args: ["selector": "#nav_diagnostics"])
            XCTFail("対象が居ない木を「到達した」と返してはいけない")
        } catch let error as MCPError {
            XCTAssertTrue(error.localizedDescription.contains("gone from"),
                          error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("scrollFrame"),
                          "逃げ道まで出すこと: \(error.localizedDescription)")
        }
    }

    /// 素直に到達したときは今までどおり成功を返す(上の検査で通常経路を潰していないこと)
    func testScrollToStillSucceedsWhenTheTargetIsThere() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "row_40", label: "行 40", x: 16, y: 100)])
        let text = Self.text(try await server.call(tool: "ft_scroll_to", args: ["selector": "#row_40"]))
        XCTAssertTrue(text.contains("scrolled to \"#row_40\""), text)
    }

    // MARK: - 容器の中でも別の物に当たる2形(2026-08-06 の探索で実測)

    /// **容器の中に居るのに下部タブに覆われている**形。`isUntappableGhost` は
    /// 「容器の外」を入口条件にしているので1つも捕まえない —— 実測では E2E-iOS のホームで
    /// `#nav_heal` を叩くと**コントロールタブへ遷移**し、それでも "tap done" が返っていた
    func testTapWarnsWhenAnOverlayIsDrawnOverTheElement() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "Other", id: "home_list", label: nil,
                    x: 16, y: 100, w: 370, h: 760, depth: 1),
            element(ref: 2, id: "nav_a", label: "A", x: 16, y: 110, w: 370, h: 62, depth: 2),
            element(ref: 3, id: "nav_heal", label: "自己修復", x: 16, y: 788, w: 370, h: 62, depth: 2),
            // タブは行の一部にしか重ならない(丸ごと包む相手は容器なので遮蔽に数えない)
            element(ref: 4, id: "tab_controls", label: "コントロール",
                    x: 134, y: 778, w: 134, h: 62, depth: 1),
        ])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 3]))
        XCTAssertTrue(text.contains("#tab_controls"), "何に当たったかもしれないかを名指しすること: \(text)")
        XCTAssertTrue(actions.contains { $0.hasPrefix("tap") }, "拒否ではなく警告して撃つこと")
    }

    /// **中心が画面の外にある要素へのタップは警告する**(拒否はしない)。
    /// 実測(2026-08-08・Compose iOS のカレンダー): スクロールでヘッダ裏へ抜けた
    /// `#slot_07` (0,-46 402x56) への ft_tap が無警告の "done" を返し、画面は無変化だった。
    /// ウィンドウ外のタッチは hitTest に乗らず黙って落ちる
    func testTapWarnsWhenTheCentreIsOffscreen() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, id: "slot_07", label: nil, x: 0, y: -46, w: 390, h: 56, depth: 2),
            element(ref: 2, id: "slot_11", label: "11:00", x: 0, y: 182, w: 390, h: 56, depth: 2),
        ])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("outside the visible screen"),
                      "画面外の中心を警告すること: \(text)")
        XCTAssertTrue(actions.contains { $0.hasPrefix("tap") }, "拒否ではなく警告して撃つこと")
        // 画面内の要素では黙る
        let ok = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 2]))
        XCTAssertFalse(ok.contains("outside the visible screen"), ok)
    }

    /// **先に並ぶ大きな要素は遮蔽に数えない**(木の順序 = 描画順)。ここを緩めると、
    /// 2026-08-06 に拒否をやめる原因になった誤検知(背景パネルが端の要素を「覆う」)へ逆戻りする
    func testAnEarlierSiblingIsNotTreatedAsAnOverlay() async throws {
        driver.snapshotResponse = screen([
            // 背景パネルが先に並ぶ。ボタンの中心を含むが、包んではいない(端で切れている)
            element(ref: 1, type: "Other", id: "panel", label: nil,
                    x: 0, y: 100, w: 300, h: 300, depth: 1),
            element(ref: 2, id: "btn", label: "押す", x: 250, y: 200, w: 120, h: 40, depth: 1),
        ])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 2]))
        XCTAssertFalse(text.contains("warning"), "後ろに描かれた物だけを遮蔽とみなすこと: \(text)")
    }

    /// **同じ矩形に積まれた要素**。容器の内側なので ghost 判定は素通しする。
    /// 実測(E2E-iOS のスクロール画面): `行 09`〜`行 40` の staticText 29 個が全部
    /// `行 01` の位置に畳まれ、無印で出ていた。ref を叩くと `selected=row_01` になる
    func testStackedFramesAreFlaggedAndWarnOnTap() async throws {
        var rows: [ElementInfo] = [
            element(ref: 1, type: "Table", id: "list_rows", label: nil,
                    x: 16, y: 270, w: 370, h: 400, depth: 1),
            element(ref: 2, type: "StaticText", id: nil, label: "行 01",
                    x: 36, y: 270, w: 330, h: 56, depth: 2),
        ]
        // 3個以上が同じ矩形 = そこに全部は描かれていない
        for n in 9...12 {
            rows.append(element(ref: n - 6, type: "StaticText", id: nil, label: "行 \(n)",
                                x: 16, y: 270, w: 330, h: 56, depth: 2))
        }
        driver.snapshotResponse = screen(rows)
        let rendered = Self.text(try await server.call(tool: "ft_snapshot", args: [:]))
        XCTAssertTrue(rendered.contains("clamped onto another row's frame"), rendered)
        XCTAssertTrue(rendered.contains("\"行 12\" (16,270 330x56) ⚠️scroll-leftover"), rendered)
        XCTAssertFalse(rendered.contains("\"行 01\" (36,270 330x56) ⚠️"),
                       "本当にそこに描かれている行は巻き込まないこと")
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 6]))
        XCTAssertTrue(text.contains("stacked on the same spot"), text)
    }

    /// **入れ子の一本鎖は積み重なりではない**。Android のダイアログは
    /// `action_bar_root`→`content`→`parentPanel`→`customPanel`→`custom` が全部同じ矩形で、
    /// これを弾くと正常な木が丸ごと警告になる
    func testANestedChainSharingOneFrameIsNotFlagged() async throws {
        let names = ["action_bar_root", "content", "parentPanel", "customPanel", "custom"]
        let chain = names.enumerated().map { index, id in
            element(ref: index + 1, type: "Other", id: id, label: nil,
                    x: 70, y: 1077, w: 940, h: 343, depth: index + 1)
        }
        driver.snapshotResponse = screen(chain)
        let rendered = Self.text(try await server.call(tool: "ft_snapshot", args: [:]))
        XCTAssertFalse(rendered.contains("⚠️"), rendered)
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

    /// id とラベルが両方ある要素は両方出す(id だけだと、同じ id を複数のラベルが共有する
    /// 画面で見分けが付かない。2026-08-10)
    func testVisibleLabelsHintCombinesIdAndLabelWhenBothArePresent() {
        let snapshot = screen([
            element(ref: 1, id: "btn_action", label: "削除", x: 0, y: 0),
        ])
        let hint = MCPServer.visibleLabelsHint(snapshot)
        XCTAssertTrue(hint.contains("#btn_action \"削除\""), hint)
    }

    /// 20 件で打ち切る(全部並べると読めない。足りなければ ft_snapshot を撮ればよい)
    func testVisibleLabelsHintIsCapped() {
        let many = (1...40).map { element(ref: $0, id: "id_\($0)", label: nil, x: 0, y: Double($0)) }
        let hint = MCPServer.visibleLabelsHint(screen(many))
        XCTAssertEqual(hint.components(separatedBy: "#id_").count - 1, 20)
        XCTAssertTrue(hint.hasSuffix("…."))
    }

    // MARK: - 欠陥①a: 打ち切りを失敗文に出す

    /// 打ち切りは配列そのものからの脱落であって描画の省略ではないので、waitFor/scrollTo は
    /// 打ち切られた要素を一生探し続ける。件数を失敗文に明記すること
    func testTruncationHintExplainsOmittedElements() {
        let intact = screen([element(ref: 1, id: "a", label: "A", x: 0, y: 0)])
        var truncated = intact
        truncated.truncatedCount = 5
        let hint = MCPServer.truncationHint(truncated)
        XCTAssertTrue(hint.contains("5"), hint)
        XCTAssertTrue(hint.contains("truncated"), hint)
        XCTAssertEqual(MCPServer.truncationHint(intact), "", "打ち切りが無ければ黙ること")
    }

    /// ft_snapshot の waitFor 失敗に打ち切りが載ること。実測: 画面に描画されている
    /// `#nav_button` を「did not appear」としか言わず、存在しない要素を探し続けることになっていた
    func testWaitForFailureMentionsTruncation() async throws {
        var truncated = screen([element(ref: 1, id: "other_row", label: "他の要素", x: 0, y: 0)])
        truncated.truncatedCount = 3
        driver.snapshotResponse = truncated
        let text = Self.text(try await server.call(
            tool: "ft_snapshot", args: ["waitFor": "#missing", "timeout": 0.3]))
        XCTAssertTrue(text.contains("did not appear"), text)
        XCTAssertTrue(text.contains("truncated"), text)
    }

    /// 実例: 経路ボタンを `waitFor "経路"` と推測したが実ラベルは「計画」だった。
    /// 空振りの応答に近いラベルを添えること
    func testWaitForFailureMentionsASimilarLabel() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "btn_plan", label: "計画", x: 0, y: 0)])
        let text = Self.text(try await server.call(
            tool: "ft_snapshot", args: ["waitFor": "経路", "timeout": 0.3]))
        XCTAssertTrue(text.contains("did not appear"), text)
        XCTAssertTrue(text.contains("similar labels on screen"), text)
        XCTAssertTrue(text.contains("計画"), text)
    }

    /// 似た物が無い画面では何も足さない
    func testWaitForFailureStaysQuietWithoutASimilarLabel() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "btn_settings", label: "設定確認画面", x: 0, y: 0)])
        let text = Self.text(try await server.call(
            tool: "ft_snapshot", args: ["waitFor": "経路", "timeout": 0.3]))
        XCTAssertTrue(text.contains("did not appear"), text)
        XCTAssertFalse(text.contains("similar labels"), text)
    }

    /// scrollTo の「届かなかった」失敗にも打ち切りを明記すること
    func testScrollToFailureMentionsTruncationWhenTreeWasTruncated() async throws {
        var truncated = screen([element(ref: 1, id: "other_row", label: "他の要素", x: 0, y: 0)])
        truncated.truncatedCount = 7
        driver.snapshotResponse = truncated
        do {
            _ = try await server.call(tool: "ft_scroll_to", args: ["selector": "#missing_row"])
            XCTFail("見つからないセレクタは throw するはず")
        } catch let error as MCPError {
            XCTAssertTrue(error.localizedDescription.contains("truncated"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("7"), error.localizedDescription)
        }
    }

    // MARK: - 欠陥⑨: ラベルも id も無い clickable

    /// ref か座標でしか指定できない要素を名指しする。実測: 経路の移動手段タブ(アイコンのみ)が
    /// id もラベルも無い `clickable` 3個として出て、書ける手段が何も無いことに気付けなかった
    func testUnlabeledClickablesNoteListsThemByRef() {
        let snapshot = screen([
            element(ref: 1, type: "Clickable", id: nil, label: nil, x: 10, y: 10, w: 40, h: 40),
            element(ref: 2, type: "Clickable", id: nil, label: nil, x: 60, y: 10, w: 40, h: 40),
            element(ref: 3, id: "btn_ok", label: "OK", x: 110, y: 10),
        ])
        let note = MCPServer.unlabeledClickablesNote(snapshot)
        XCTAssertTrue(note.contains("2 clickable"), note)
        XCTAssertTrue(note.contains("[1]"), note)
        XCTAssertTrue(note.contains("[2]"), note)
        XCTAssertFalse(note.contains("[3]"), "id/label を持つ要素は数えないこと: \(note)")
    }

    func testUnlabeledClickablesNoteStaysQuietWhenNone() {
        XCTAssertEqual(MCPServer.unlabeledClickablesNote(
            screen([element(ref: 1, id: "btn_ok", label: "OK", x: 0, y: 0)])), "")
    }

    // MARK: - ft_drag を ref から始める

    /// **半開きシートを広げる操作**が座標の手計算になっていた(実測: `#Card grabber` の
    /// frame を読んで `ft_drag (200,664) → (200,120)` を人が組んだ)。ref と dy で書けること
    func testDragStartsFromARefAndMovesByDelta() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "Button", id: "Card grabber", label: "カードコントローラ",
                    x: 150, y: 650, w: 100, h: 24),
        ])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_drag", args: ["fromRef": 1, "dy": -540.0]))
        XCTAssertTrue(actions.contains("drag(200.0,662.0->200.0,122.0,duration:1.5)"),
                      "ref の中心から dy だけ動かしていない: \(actions)")
        XCTAssertTrue(text.contains("sent"), text)
    }

    /// 座標形は従来どおり(既存のシナリオ・呼び出しを壊さない)
    func testDragStillAcceptsPlainCoordinates() async throws {
        _ = try await server.call(tool: "ft_drag",
                                  args: ["fromX": 10.0, "fromY": 20.0, "toX": 30.0, "toY": 40.0])
        XCTAssertTrue(actions.contains("drag(10.0,20.0->30.0,40.0,duration:1.5)"), "\(actions)")
    }

    /// **動かないドラッグは撃たない**(0px のドラッグを成功と記録すると書き間違いに気付けない)
    func testDragWithoutAnyTravelIsRefused() async throws {
        do {
            _ = try await server.call(tool: "ft_drag", args: ["fromX": 10.0, "fromY": 20.0])
            XCTFail("移動量ゼロのドラッグが通った")
        } catch {
            XCTAssertTrue("\(error)".contains("does not move"), "\(error)")
        }
    }

    func testSnapshotSurfacesUnlabeledClickables() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "Clickable", id: nil, label: nil, x: 10, y: 10, w: 40, h: 40),
        ])
        let text = Self.text(try await server.call(tool: "ft_snapshot", args: [:]))
        XCTAssertTrue(text.contains("neither a label nor an id"), text)
    }

    // MARK: - 欠陥⑩: 曖昧なラベルの要約注記

    /// 同一ラベルが複数あると素のラベルでは一意に指せない。実測: 経路検索の候補一覧で
    /// 「東京駅」が9件一致した。id の重複は別パッケージの `×N` が扱うので、ここはラベルだけ
    func testAmbiguousLabelsNoteSummarizesRepeatedLabels() {
        var elements = (1...9).map { element(ref: $0, id: nil, label: "東京駅", x: 0, y: Double($0)) }
        elements.append(element(ref: 10, id: "btn_ok", label: "OK", x: 0, y: 100))
        let note = MCPServer.ambiguousLabelsNote(screen(elements))
        XCTAssertTrue(note.contains("\"東京駅\" ×9"), note)
        XCTAssertFalse(note.contains("\"OK\""), "1件だけのラベルは対象外: \(note)")
    }

    /// **2件でも報告する**(2026-08-09 に下限を3から2へ)。実測(Google マップの検索結果)では
    /// 別 frame の `"他のフィルタ"` が2件あるのに黙っており、`tap("他のフィルタ")` が
    /// 一意に選べないことに気付けなかった
    func testAmbiguousLabelsNoteReportsExactlyTwoDistinctElements() {
        let elements = [element(ref: 1, id: nil, label: "他のフィルタ", x: 0, y: 10),
                        element(ref: 2, id: nil, label: "他のフィルタ", x: 200, y: 10)]
        XCTAssertTrue(MCPServer.ambiguousLabelsNote(screen(elements)).contains("\"他のフィルタ\" ×2"))
    }

    // MARK: - sliver 注記は操作可能型に限る

    /// 縁で細帯に切れた**操作可能要素**は従来どおり列挙する(2026-08-08 の初出事例:
    /// 右端で 9x137 に切れたタブ)
    func testSliverNoteListsAnOperableSliver() {
        let tab = element(ref: 1, type: "tab", id: nil, label: "サンライズ瀬戸",
                          x: 393, y: 100, w: 9, h: 137)
        let note = MCPServer.sliverNote(screen([tab]))
        XCTAssertTrue(note.contains("[1]"), note)
        XCTAssertTrue(note.contains("extremely thin"), note)
    }

    /// タップ対象にならない型(image 等)は細くても列挙しない(2026-08-10 実測: 画面下端で
    /// 84x9 に切れた「IC 運賃」アイコンに「タップに失敗するかも」が出て空振りの注意になった)
    func testSliverNoteSkipsANonOperableSliver() {
        let icon = element(ref: 1, type: "image", id: nil, label: "IC 運賃",
                           x: 852, y: 2415, w: 84, h: 9)
        XCTAssertEqual(MCPServer.sliverNote(screen([icon])), "")
    }

    /// **全員が飾りの葉(型なし・操作不能・中身なし)の群は列挙しない**。
    /// 実測: 地図 POI の「東武鉄道 TJの路線」×3(全員 #VKPointFeature の other)が
    /// セレクタの書き先にならないのに注記の行を占めていた
    func testAmbiguousLabelsNoteSkipsAGroupOfOnlyDecorativeLeaves() {
        let elements = [
            element(ref: 1, type: "other", id: "VKPointFeature", label: "東武鉄道 TJの路線",
                    x: 10, y: 10, w: 30, h: 30),
            element(ref: 2, type: "other", id: "VKPointFeature", label: "東武鉄道 TJの路線",
                    x: 100, y: 10, w: 30, h: 30),
            element(ref: 3, type: "other", id: "VKPointFeature", label: "東武鉄道 TJの路線",
                    x: 200, y: 10, w: 30, h: 30),
            element(ref: 4, id: "btn_ok", label: "OK", x: 0, y: 200),
        ]
        XCTAssertEqual(MCPServer.ambiguousLabelsNote(screen(elements)), "")
    }

    /// 1件でも操作対象・型付きが混じる群は従来どおり**全員**出す(片側だけ隠すと
    /// ×N の数と明細が食い違う)
    func testAmbiguousLabelsNoteKeepsAMixedGroupIntact() {
        let elements = [
            element(ref: 1, type: "other", id: "VKPointFeature", label: "立川駅",
                    x: 10, y: 10, w: 30, h: 30),
            element(ref: 2, type: "Button", id: nil, label: "立川駅", x: 100, y: 200),
        ]
        let note = MCPServer.ambiguousLabelsNote(screen(elements))
        XCTAssertTrue(note.contains("\"立川駅\" ×2"), note)
    }

    /// **容器とその中身が同じラベルを名乗る形は曖昧ではない**(どちらを掴んでも同じもの)。
    /// 下限を2へ下げたときにラッパー対が全部鳴らないようにする除外
    func testAmbiguousLabelsNoteIgnoresAWrapperChain() {
        let outer = element(ref: 1, type: "Button", id: "tile", label: "自宅、追加",
                            x: 0, y: 10, w: 80, h: 80, depth: 2)
        let inner = element(ref: 2, type: "StaticText", id: nil, label: "自宅、追加",
                            x: 0, y: 10, w: 80, h: 80, depth: 3)
        XCTAssertEqual(MCPServer.ambiguousLabelsNote(screen([outer, inner])), "")
    }

    /// **ゼロ幅文字は落としてから数えて表示する**。一覧の行は除去済みの形で
    /// 出るので、生ラベルのまま注記に出すと同じラベルが1応答の中で2表記になる
    /// (実測: Google マップの `"​​埼京線​"`)
    func testAmbiguousLabelsNoteStripsZeroWidthCharacters() {
        let elements = [element(ref: 1, id: nil, label: "\u{200B}埼京線", x: 0, y: 10),
                        element(ref: 2, id: nil, label: "埼京線\u{FEFF}", x: 200, y: 10)]
        let note = MCPServer.ambiguousLabelsNote(screen(elements))
        XCTAssertTrue(note.contains("\"埼京線\" ×2"), note)
        XCTAssertFalse(note.contains("\u{200B}"), note)
        XCTAssertFalse(note.contains("\u{FEFF}"), note)
    }

    func testSnapshotSurfacesAmbiguousLabels() async throws {
        driver.snapshotResponse = screen(
            (1...3).map { element(ref: $0, id: nil, label: "重複ラベル", x: 0, y: Double($0)) })
        let text = Self.text(try await server.call(tool: "ft_snapshot", args: [:]))
        XCTAssertTrue(text.contains("cannot pick one uniquely"), text)
    }

    // MARK: - 欠陥⑪: 複数スクロール領域の注記が ft_scroll_to に出ない

    /// `ScrollFrameCandidates` の「N scroll areas」注記は ft_snapshot にしか出ていなかった。
    /// scrollFrame: を渡すべき当人である ft_scroll_to の成功文にも出すこと
    func testScrollToNamesMultipleScrollAreasWhenNotSpecified() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [
                ElementInfo(ref: 1, type: "ScrollView", identifier: "chips", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 60, width: 390, height: 60), depth: 1,
                            scrollable: true),
                ElementInfo(ref: 2, type: "Table", identifier: "list_rows", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 120, width: 390, height: 600), depth: 1,
                            scrollable: true),
                element(ref: 3, id: "row_40", label: "行 40", x: 16, y: 100),
            ],
            truncatedCount: 0)
        let text = Self.text(try await server.call(tool: "ft_scroll_to", args: ["selector": "#row_40"]))
        XCTAssertTrue(text.contains("2 scroll areas"), text)
    }

    /// scrollFrame: を既に渡していれば黙る(選んだ後なので不要)
    func testScrollToStaysQuietAboutScrollAreasWhenScrollFrameIsGiven() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [
                ElementInfo(ref: 1, type: "ScrollView", identifier: "chips", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 60, width: 390, height: 60), depth: 1,
                            scrollable: true),
                ElementInfo(ref: 2, type: "Table", identifier: "list_rows", label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 120, width: 390, height: 600), depth: 1,
                            scrollable: true),
                element(ref: 3, id: "row_40", label: "行 40", x: 16, y: 100),
            ],
            truncatedCount: 0)
        let text = Self.text(try await server.call(
            tool: "ft_scroll_to", args: ["selector": "#row_40", "scrollFrame": "#list_rows"]))
        XCTAssertFalse(text.contains("scroll areas"), text)
    }

    // MARK: - scrollFrame に ref(整数)を渡せる
    //
    // id が重複・欠落した容器はセレクタで一意に指せない。ft_snapshot が返した ref を
    // そのまま scrollFrame へ渡せる逃げ道(既存の stale-ref 再照合を通す)

    /// id もラベルも無い容器でも ref なら渡せて、探索は成立すること
    func testScrollToAcceptsARefAsScrollFrame() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [
                ElementInfo(ref: 1, type: "ScrollView", identifier: nil, label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 120, width: 390, height: 600), depth: 1,
                            scrollable: true),
                element(ref: 2, id: "row_40", label: "行 40", x: 16, y: 100),
            ],
            truncatedCount: 0)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(
            tool: "ft_scroll_to", args: ["selector": "#row_40", "scrollFrame": 1]))
        XCTAssertTrue(text.contains("#row_40"), text)
    }

    /// 過去5世代にも無い ref は明確に拒否する(黙って全画面へ退化しない)
    func testScrollToRefusesAnUnknownScrollFrameRef() async throws {
        driver.snapshotResponse = screen([element(ref: 1, id: "row_40", label: "行 40", x: 16, y: 100)])
        do {
            _ = try await server.call(
                tool: "ft_scroll_to", args: ["selector": "#row_40", "scrollFrame": 999])
            XCTFail("未知の ref は拒否するはず")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("scrollFrame ref"),
                          error.localizedDescription)
        }
    }

    /// 撮った時点から容器が消えていれば、古い座標を黙って使わず拒否する
    /// (verifiedRef と同じ stale-ref 再照合の規律)
    func testScrollToRefusesAScrollFrameRefThatDisappeared() async throws {
        driver.snapshotResponse = SnapshotResponse(
            sessionBundleID: "com.example.app",
            screen: FTRect(x: 0, y: 0, width: 390, height: 844),
            elements: [
                ElementInfo(ref: 1, type: "ScrollView", identifier: nil, label: nil,
                            value: nil, placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 120, width: 390, height: 600), depth: 1,
                            scrollable: true),
                element(ref: 2, id: "row_40", label: "行 40", x: 16, y: 100),
            ],
            truncatedCount: 0)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        // 容器が消えた木(row_40 だけが残る)
        driver.snapshotResponse = screen([element(ref: 1, id: "row_40", label: "行 40", x: 16, y: 100)])
        do {
            _ = try await server.call(
                tool: "ft_scroll_to", args: ["selector": "#row_40", "scrollFrame": 1])
            XCTFail("消えた ref は拒否するはず")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no longer in the tree"),
                          error.localizedDescription)
        }
    }

    // MARK: - キーボード被覆

    /// **中心がソフトキーボードの下にある要素へのタップは警告する**(拒否はしない)。
    /// 判定は RefGuard.keyboardWarning → TapTargetGeometry.keyboardCoveredAdvisory への転送
    /// (SweepHarnessTests が RefGuard 経由で数える規約のため転送を必ず置く)。
    /// 実測(2026-08-08・iOS): キーボード下の候補行 ref タップが警告なしで顔文字キーに当たった
    /// (inputView は空葉になり、既存の空葉コンテナ除外で遮蔽候補から漏れる)
    func testTapWarnsWhenTheCentreIsUnderTheKeyboard() async throws {
        var withKeyboard = screen([
            element(ref: 1, id: "suggestion_row", label: "候補", x: 16, y: 620, w: 358, h: 40),
        ])
        withKeyboard.keyboardFrame = FTRect(x: 0, y: 600, width: 390, height: 244)
        driver.snapshotResponse = withKeyboard
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("soft keyboard"), "キーボード被覆を警告すること: \(text)")
        XCTAssertTrue(actions.contains { $0.hasPrefix("tap") }, "拒否ではなく警告して撃つこと")
    }

    /// **木に出ないオーバーレイ・ウィンドウ**の下を撃とうとしたら警告すること
    /// (実機 Pixel 4a の Chrome で実害確認。判定は OverlayWindowOcclusion = DSL と共有)。
    /// この経路(ft_tap → verifiedRef → RefGuard.preTapWarnings)が申告を読まなくなると落ちる
    func testTapWarnsWhenTheCentreIsUnderAnOverlayWindow() async throws {
        var withOverlay = screen([
            element(ref: 1, id: "content", label: "本文", x: 22, y: 136, w: 1036, h: 266),
        ])
        // 実機の実測(テキスト選択のフローティングツールバー)。中心 (540,269) を覆う
        withOverlay.overlayWindowFrames = [FTRect(x: 96, y: 251, width: 950, height: 124)]
        driver.snapshotResponse = withOverlay
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("overlay window"), "オーバーレイ被覆を警告すること: \(text)")
        XCTAssertTrue(actions.contains { $0.hasPrefix("tap") }, "拒否ではなく警告して撃つこと")
    }

    /// **申告があっても中心が外なら黙る**。この画面で毎回警告が付くと、実機の通常操作が濁る
    func testTapStaysQuietWhenTheOverlayMissesTheCentre() async throws {
        var withOverlay = screen([
            element(ref: 1, id: "content", label: "本文", x: 22, y: 732, w: 1036, h: 333),
        ])
        withOverlay.overlayWindowFrames = [FTRect(x: 96, y: 710, width: 950, height: 131)]
        driver.snapshotResponse = withOverlay
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertFalse(text.contains("overlay window"), "中心が外なら黙ること: \(text)")
    }

    /// **木が画面を代表していないことを、木の外から知る**(iOS xcuitest)。SpringBoard の面が
    /// アプリを覆うと `/snapshot` は覆う前と同じ木を返し続け、ライブのヒットテストだけが
    /// 「引き当てられない」と答える。実害の witness は Simulator で ft_tap が成功を返しながら
    /// 別アプリへ切り替わったこと(2026-08-28)
    func testTapWarnsWhenThePlatformCannotResolveAnElementTheTreeListed() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "button", id: "com.apple.settings.primaryAppleAccount",
                    label: "Apple Account", x: 16, y: 168, w: 370, h: 108),
        ])
        driver.hitTestAnswer = .unresolvable
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("cannot find"), "引き当て不能を警告すること: \(text)")
        XCTAssertTrue(text.contains("no longer the one being queried"), text)
        // **拾えない形を名乗らない**: コントロールセンター / 通知センターはこの信号を出さない
        // (実測。名乗ると読み手が「出ていない = 覆いは無い」と誤読する)
        XCTAssertFalse(text.contains("Control Center"), text)
        XCTAssertTrue(actions.contains { $0.hasPrefix("tap") }, "拒否ではなく警告して撃つこと")
    }

    /// **引き当てられたときは黙る**(検出器が常時発火していないこと)
    func testTapStaysQuietWhenThePlatformResolvesTheElement() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "button", id: "btn_ok", label: "OK",
                    x: 16, y: 168, w: 370, h: 108),
        ])
        driver.hitTestAnswer = .hittable(true)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertFalse(text.contains("cannot find"), text)
    }

    /// **答えられない口(旧ブリッジ・in-app・Android)では黙る** —— 「聞けなかった」を
    /// 「覆われている」と読み替えない
    func testTapStaysQuietWhenTheBridgeCannotAnswer() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "button", id: "btn_ok", label: "OK",
                    x: 16, y: 168, w: 370, h: 108),
        ])
        driver.hitTestAnswer = .unavailable
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertFalse(text.contains("cannot find"), text)
    }

    /// **名前を持たない容器には言わない**。覆いが無くても引き当てられないので、
    /// ここを絞らないと誤検知だらけになる(実測: 覆い無しの設定 root で 53 中 12 件)
    func testTapStaysQuietForAnUnnamedContainerThatCannotBeResolved() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "other", x: 16, y: 168, w: 370, h: 108),
        ])
        driver.hitTestAnswer = .unresolvable
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertFalse(text.contains("cannot find"), text)
    }

    /// **コントロールセンターが覆っているときは SpringBoard の答えで警告する**。
    /// 木も `/hittable` も「正常」を返すので、これ以外に知る手段が無い(実機で実測)
    func testTapWarnsWhenControlCentreCoversTheApp() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "button", id: "btn_ok", label: "OK",
                    x: 16, y: 168, w: 370, h: 108),
        ])
        driver.hitTestAnswer = .hittable(true)   // アプリ側は「正常」と答える
        driver.systemUICoveringResponse = SystemUICoveringResponse(
            covering: true, marker: "cc-brightness-slider")
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("Control Center"), text)
        XCTAssertTrue(actions.contains { $0.hasPrefix("tap") }, "拒否ではなく警告して撃つこと")
    }

    /// **両方が発火しうるときは覆いのほうだけを言う**。通知センターはアプリを背面へ回すので
    /// hitTest も unresolvable になるが、その文言は「アプリスイッチャーが開いている」と
    /// **誤った説明**をする(実機で実測)
    func testCoveringWarningWinsOverTheGenericUnresolvableOne() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "button", id: "btn_ok", label: "OK",
                    x: 16, y: 168, w: 370, h: 108),
        ])
        driver.hitTestAnswer = .unresolvable
        driver.systemUICoveringResponse = SystemUICoveringResponse(
            covering: true, marker: "SBCoverSheetWindow")
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("notification centre"), text)
        XCTAssertFalse(text.contains("app switcher is open"),
                       "面が分かっているのに一般論の誤った説明を並べないこと: \(text)")
    }

    /// 通知センター(カバーシート)は別の面として名指しする
    func testTapNamesTheNotificationCentreWhenThatIsWhatCovers() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "button", id: "btn_ok", label: "OK",
                    x: 16, y: 168, w: 370, h: 108),
        ])
        driver.systemUICoveringResponse = SystemUICoveringResponse(
            covering: true, marker: "SBCoverSheetWindow")
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("notification centre"), text)
    }

    /// **覆っていないときは黙る**(常時発火していないこと)
    func testTapStaysQuietWhenNothingCoversTheApp() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "button", id: "btn_ok", label: "OK",
                    x: 16, y: 168, w: 370, h: 108),
        ])
        driver.systemUICoveringResponse = SystemUICoveringResponse(covering: false)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertFalse(text.contains("drawn over the app"), text)
    }

    /// **答えられない口(旧ブリッジ・in-app・Android)では黙る**
    func testTapStaysQuietWhenTheBridgeCannotAnswerAboutCovering() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "button", id: "btn_ok", label: "OK",
                    x: 16, y: 168, w: 370, h: 108),
        ])
        driver.systemUICoveringResponse = nil
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertFalse(text.contains("drawn over the app"), text)
    }

    /// **申告 keyboardFrame はキー面だけ**(TapTargetGeometry.effectiveKeyboardFrame の doc)。
    /// この経路(ft_tap → verifiedRef → RefGuard.preTapWarnings)が申告のまま渡すよう後退すると、
    /// このテストは警告が付かず落ちる ——「拡張後の矩形を使っているか」の配線テスト
    /// (`effectiveKeyboardFrame` 自体の単体テストは TapTargetAdvisoryTests にある)
    func testTapWarnsWhenTheCentreIsOnlyUnderTheExpandedKeyboardChrome() async throws {
        var withKeyboard = screen([
            element(ref: 1, id: "tab_home", label: "ホーム", x: 0, y: 548, w: 134, h: 62),
            element(ref: 2, type: "other", id: "inputView", x: 0, y: 546, w: 390, h: 328),
            element(ref: 3, type: "other", id: "SystemInputAssistantView", x: 0, y: 546, w: 390, h: 44),
        ])
        // 申告は 590..816 —— ref 1 の中心 y=579 はこの外(修正前は無警告)
        withKeyboard.keyboardFrame = FTRect(x: 0, y: 590, width: 390, height: 226)
        driver.snapshotResponse = withKeyboard
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = Self.text(try await server.call(tool: "ft_tap", args: ["ref": 1]))
        XCTAssertTrue(text.contains("soft keyboard"),
                      "chrome で広げた実効矩形(546..874)なら中心 579 を拾って警告すること: \(text)")
    }

    /// `keyboardCoverageNote` の見出し座標と一覧も拡張後の実効矩形を使うこと(判定と表示が
    /// 食い違うと読み手が検算できない)。申告のままだと ref 1 は列挙に載らず
    /// 「nothing tappable is beneath it」になる(修正前の偽の全クリア)
    func testKeyboardCoverageNoteUsesTheExpandedFrameForBothHeaderAndListing() {
        var withKeyboard = screen([
            element(ref: 1, type: "button", id: "tab_home", label: "ホーム", x: 0, y: 548, w: 134, h: 62),
            element(ref: 2, type: "other", id: "inputView", x: 0, y: 546, w: 402, h: 328),
        ])
        withKeyboard.keyboardFrame = FTRect(x: 0, y: 590, width: 402, height: 226)
        let note = MCPServer.keyboardCoverageNote(withKeyboard)
        XCTAssertTrue(note.contains("(0,546 402x328)"), "見出しは拡張後の座標であること: \(note)")
        XCTAssertTrue(note.contains("[1]"), "拡張後は ref 1 を列挙すること: \(note)")
        XCTAssertFalse(note.contains("nothing tappable"), "偽の全クリアへ後退していないこと: \(note)")
    }

    /// **見出しの矩形は拡張後のまま・列挙は chrome の部分木を除く**。
    /// ref 3(chrome=`#inputView` の子、地球儀キー相当)は実効矩形の中に中心があるが、
    /// 覆っている側なので列挙しない。ref 1(chrome の外)は変わらず列挙する
    func testKeyboardCoverageNoteExcludesTheChromeSubtreeFromTheListing() {
        var withKeyboard = screen([
            element(ref: 1, type: "button", id: "tab_home", label: "ホーム", x: 0, y: 548, w: 134, h: 62),
            element(ref: 2, type: "other", id: "inputView", x: 0, y: 546, w: 402, h: 328),
            element(ref: 3, type: "button", id: "globe_key", x: 0, y: 806, w: 134, h: 68, depth: 3),
        ])
        withKeyboard.keyboardFrame = FTRect(x: 0, y: 590, width: 402, height: 226)
        let note = MCPServer.keyboardCoverageNote(withKeyboard)
        XCTAssertTrue(note.contains("(0,546 402x328)"), "見出しは拡張後の座標のまま: \(note)")
        XCTAssertTrue(note.contains("[1]"), "chrome の外にある ref 1 は列挙すること: \(note)")
        XCTAssertFalse(note.contains("[3]"), "chrome の子(地球儀キー相当)は列挙しないこと: \(note)")
    }

    private static func text(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - ft_scroll_to の畳み方は ft_snapshot と同じ規則

    /// **既定**(引数無し)は今までどおり: layout-only の行も出るし、bulk 群は畳まれる
    /// (この形が変わらないことが受け入れ条件)
    func testScrollToDefaultRenderingIsUnchanged() async throws {
        var elements = [element(ref: 1, type: "Button", id: "row_40", label: "行 40", x: 16, y: 100)]
        elements.append(element(ref: 2, type: "Other", id: "deco_1", label: nil,
                                x: 200, y: 100, w: 4, h: 4, depth: 1))
        for i in 0..<20 {
            elements.append(element(ref: 100 + i, type: "Other", id: "poi", label: nil,
                                    x: Double(i), y: 300, w: 4, h: 4, depth: 1))
        }
        driver.snapshotResponse = screen(elements)
        let text = Self.text(try await server.call(tool: "ft_scroll_to", args: ["selector": "#row_40"]))
        XCTAssertTrue(text.contains("deco_1"), "layout-only の行は既定で出ること: \(text)")
        XCTAssertTrue(text.contains("collapsed"), "bulk 群は既定で畳まれること: \(text)")
    }

    /// interactiveOnly は ft_snapshot と同じ意味で layout-only の行を隠す
    func testScrollToInteractiveOnlyHidesLayoutOnlyLines() async throws {
        var elements = [element(ref: 1, type: "Button", id: "row_40", label: "行 40", x: 16, y: 100)]
        elements.append(element(ref: 2, type: "Other", id: "deco_1", label: nil,
                                x: 200, y: 100, w: 4, h: 4, depth: 1))
        driver.snapshotResponse = screen(elements)
        let text = Self.text(try await server.call(
            tool: "ft_scroll_to", args: ["selector": "#row_40", "interactiveOnly": true]))
        XCTAssertFalse(text.contains("deco_1"), "interactiveOnly で隠れること: \(text)")
        XCTAssertTrue(text.contains("row_40"), text)
    }

    /// expandBulk は ft_snapshot と同じ意味で bulk 群を個別行に展開する
    func testScrollToExpandBulkListsTheGroupInFull() async throws {
        var elements = [element(ref: 1, type: "Button", id: "row_40", label: "行 40", x: 16, y: 100)]
        for i in 0..<20 {
            elements.append(element(ref: 100 + i, type: "Other", id: "poi", label: nil,
                                    x: Double(i), y: 300, w: 4, h: 4, depth: 1))
        }
        driver.snapshotResponse = screen(elements)
        let text = Self.text(try await server.call(
            tool: "ft_scroll_to", args: ["selector": "#row_40", "expandBulk": true]))
        XCTAssertFalse(text.contains("collapsed"), "expandBulk で畳まないこと: \(text)")
        XCTAssertEqual(text.components(separatedBy: "id=poi").count - 1, 20,
                       "20件すべてを個別行で出すこと: \(text)")
    }

    // MARK: - ghostNote と render の畳みを揃える(2026-08-10。地図 POI の洪水対策)

    private func poiSnapshotWithAStackedCluster() -> SnapshotResponse {
        var elements = (0..<20).map { i in
            element(ref: i + 1, type: "other", id: "poi", label: "POI\(i)",
                    x: Double(i), y: 10, w: 30, h: 30, depth: 1)
        }
        // 同じ矩形に5個スタック = stackedRefs が leftover として印を付ける対象
        for j in 0..<5 {
            elements.append(element(ref: 21 + j, type: "other", id: "poi", label: "STACK\(j)",
                                    x: 300, y: 300, w: 30, h: 30, depth: 1))
        }
        return screen(elements)
    }

    /// **警告付きも畳んだ ×M 行の中に入り、注記では個別列挙せず件数だけ言う**。
    /// 地図 POI 231件中40件が警告付きというだけで、注記の個別列挙が出力の半分を占めていた実害
    func testGhostNoteFoldsWarnedMembersIntoTheBulkLine() async throws {
        driver.snapshotResponse = poiSnapshotWithAStackedCluster()
        let text = Self.text(try await server.call(tool: "ft_snapshot", args: [:]))
        XCTAssertTrue(text.contains("id=poi ×25 collapsed"), text)
        XCTAssertTrue(text.contains("folded into the ×25 id=poi line below"), text)
        XCTAssertFalse(text.contains("[21] #poi"), "畳まれた ref を注記で個別列挙しないこと: \(text)")
    }

    /// expandBulk: true では従来どおり全件を個別列挙する(collapsingBulk off)
    func testGhostNoteListsIndividuallyWhenBulkIsExpanded() async throws {
        driver.snapshotResponse = poiSnapshotWithAStackedCluster()
        let text = Self.text(try await server.call(tool: "ft_snapshot", args: ["expandBulk": true]))
        XCTAssertFalse(text.contains("folded into the"), text)
        XCTAssertTrue(text.contains("[21] #poi"), text)
    }
}
