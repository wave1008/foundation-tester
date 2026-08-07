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
        XCTAssertTrue(text.contains("shares its exact frame"), text)
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

    func testSnapshotSurfacesUnlabeledClickables() async throws {
        driver.snapshotResponse = screen([
            element(ref: 1, type: "Clickable", id: nil, label: nil, x: 10, y: 10, w: 40, h: 40),
        ])
        let text = Self.text(try await server.call(tool: "ft_snapshot", args: [:]))
        XCTAssertTrue(text.contains("neither a label nor an id"), text)
    }

    // MARK: - 欠陥⑩: 曖昧なラベルの要約注記

    /// 3件以上の同一ラベルは素のラベルでは一意に指せない。実測: 経路検索の候補一覧で
    /// 「東京駅」が9件一致した。id の重複は別パッケージの `×N` が扱うので、ここはラベルだけ
    func testAmbiguousLabelsNoteSummarizesRepeatedLabels() {
        var elements = (1...9).map { element(ref: $0, id: nil, label: "東京駅", x: 0, y: Double($0)) }
        elements.append(element(ref: 10, id: "btn_ok", label: "OK", x: 0, y: 100))
        let note = MCPServer.ambiguousLabelsNote(screen(elements))
        XCTAssertTrue(note.contains("\"東京駅\" ×9"), note)
        XCTAssertFalse(note.contains("\"OK\""), "3件未満のラベルは対象外: \(note)")
    }

    func testAmbiguousLabelsNoteStaysQuietBelowThreshold() {
        let elements = (1...2).map { element(ref: $0, id: nil, label: "重複", x: 0, y: Double($0)) }
        XCTAssertEqual(MCPServer.ambiguousLabelsNote(screen(elements)), "")
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

    private static func text(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
