// 「タップは 200 を返したのに何も起きていない」を**失敗の場で名指しする**証跡の固定。
//
// タップに事後検証は無く(何が起きるべきかをホストは知らない)、飲まれたときに落ちるのは
// 2ステップ先の検証なので原因が遠い。過去の失敗レポート 21 件を突き合わせても、
// 「タップが飲まれた」と「そもそも別の値になった」を注記から見分けられなかった。
// そこで**操作直前の木を基準に、失敗した側が既に持っている木と比べる**(追加のスナップショットは
// 撮らない = 実行中に I/O を足すと事象そのものが消える。docs/verification.md の heisenbug)。
//
// ここで固定するのは3つ:
//  1. 無変化のときだけ注記が出る(変化していれば黙る = 誤検知を出さない側に倒す)
//  2. **ラベルだけの変化を取りこぼさない**(`selected=-` → `selected=row_30` がまさにこれ。
//     settledSignature の署名を流用すると frame しか見ないので黙ってしまう)
//  3. 記録は「次に画面を変える操作」まで生き、`select` では消えない
//     (`tap → select → textIs` が一番ありふれた失敗の形)

import XCTest
@testable import FTCore

/// このファイル専用の最小ドライバ(StepExecutorTests の FakeAppDriver とは別物 —— あちらは
/// private かつ 2,400 行のファイルにあるため、増やさずここに小さいものを置く)。
/// snapshot は「呼び出し回数ぶんの列(尽きたら最後を繰り返す)」規約
private final class ScriptedDriver: AppDriver {
    var frames: [[ElementInfo]]
    /// 全スナップショットに載せるスクロールヒント(scrollToEdge の端判定用)
    var offscreen: [ElementInfo]?
    private(set) var snapshotCount = 0
    private(set) var tapCount = 0
    private(set) var tappedRefs: [Int] = []
    private(set) var tappedPoints: [(x: Double, y: Double)] = []
    private(set) var swipeCount = 0

    init(frames: [[ElementInfo]], offscreen: [ElementInfo]? = nil) {
        self.frames = frames
        self.offscreen = offscreen
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(x: Double, y: Double) async throws { tappedPoints.append((x, y)) }
    func tap(ref: Int) async throws { tapCount += 1; tappedRefs.append(ref) }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { swipeCount += 1 }

    func snapshot() async throws -> SnapshotResponse {
        snapshotCount += 1
        let elements = frames.isEmpty ? [] : frames[min(snapshotCount - 1, frames.count - 1)]
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0, offscreen: offscreen)
    }
}

private func text(_ ref: Int, _ id: String, _ label: String,
                  y: Double = 100, type: String = "staticText") -> ElementInfo {
    ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                placeholder: nil, enabled: true,
                frame: FTRect(x: 16, y: y, width: 200, height: 24), depth: 1)
}

final class SwallowedInteractionTests: XCTestCase {

    // MARK: - 署名(何を「変化」と数えるか)

    /// **ラベルだけ変わった木を「無変化」と言ってはいけない**。飲まれたタップの実例
    /// (`#txt_row_selected` が `selected=-` のままか `selected=row_30` になるか)は
    /// 座標が1ピクセルも動かないので、frame だけの署名では区別が付かない
    func testSignatureSeesLabelOnlyChanges() {
        let before = [text(1, "txt_row_selected", "selected=-")]
        let after = [text(1, "txt_row_selected", "selected=row_30")]
        XCTAssertNotEqual(StepExecutor.contentSignature(before),
                          StepExecutor.contentSignature(after),
                          "ラベルだけの変化を取りこぼすと、飲まれたタップと正しいタップが同じに見える")
        XCTAssertEqual(StepExecutor.contentSignature(before),
                       StepExecutor.contentSignature([text(1, "txt_row_selected", "selected=-")]))
    }

    /// value / enabled / checked も画面の変化(押した結果が値やトグルにしか出ない画面がある)
    func testSignatureSeesValueAndStateChanges() {
        let base = ElementInfo(ref: 1, type: "switch", identifier: "sw", label: "通知", value: "off",
                               placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 0, width: 40, height: 20), depth: 1)
        var valued = base; valued.value = "on"
        var toggled = base; toggled.checked = true
        var disabled = base; disabled.enabled = false
        XCTAssertNotEqual(StepExecutor.contentSignature([base]), StepExecutor.contentSignature([valued]))
        XCTAssertNotEqual(StepExecutor.contentSignature([base]), StepExecutor.contentSignature([toggled]))
        XCTAssertNotEqual(StepExecutor.contentSignature([base]), StepExecutor.contentSignature([disabled]))
    }

    // MARK: - 注記(飲まれたときだけ出る)

    /// tap → textIs の失敗。木が1ピクセルも変わっていないなら「飲まれた可能性」を名指しする。
    /// これが無いと、失敗文言は「expected ... actual ...」だけで**タップまで遡れない**
    func testFailureNamesTheSwallowedTap() async throws {
        let unchanged = [text(1, "row_30", "行 30", y: 300, type: "clickable"),
                         text(2, "txt_row_selected", "selected=-")]
        let driver = ScriptedDriver(frames: [unchanged])
        let executor = StepExecutor(driver: driver)

        guard case .passed = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "row_30"))).status else {
            XCTFail("タップ自体はブリッジが 200 を返す = 成功のはず"); return
        }
        let outcome = await executor.execute(
            FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_row_selected"),
                     expected: "selected=row_30", timeout: 0, occlusionGuard: false))

        guard case .failed(let message) = outcome.status else {
            XCTFail("値が変わっていないので失敗するはず: \(outcome.status)"); return
        }
        XCTAssertTrue(message.contains("did not change the screen at all"),
                      "飲まれたタップを名指しすること: \(message)")
        XCTAssertTrue(message.contains("tap "), "どの操作かを書くこと: \(message)")
    }

    /// **画面が変わっていれば黙る**。タップは効いたが期待値と違う(= セレクタや期待値の誤り)を
    /// 「飲まれた」と言うと調査を誤誘導する。誤検知は出さない側へ倒す
    func testNoHintWhenTheScreenChanged() async throws {
        let before = [text(1, "row_30", "行 30", y: 300, type: "clickable"),
                      text(2, "txt_row_selected", "selected=-")]
        let after = [text(1, "row_30", "行 30", y: 300, type: "clickable"),
                     text(2, "txt_row_selected", "selected=row_29")]
        let driver = ScriptedDriver(frames: [before, after])
        let executor = StepExecutor(driver: driver)

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30")))
        let outcome = await executor.execute(
            FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_row_selected"),
                     expected: "selected=row_30", timeout: 0, occlusionGuard: false))

        guard case .failed(let message) = outcome.status else {
            XCTFail("別の行が選ばれているので失敗するはず"); return
        }
        XCTAssertFalse(message.contains("did not change the screen"),
                       "変化しているのに『飲まれた』と言ってはいけない: \(message)")
    }

    /// `select` はデバイス操作を伴わないので記録を消さない。
    /// **`tap → select → textIs` が実際の失敗の形**(select で掴んで textIs で検証する DSL の定型)で、
    /// ここで消すと肝心なときだけ証跡が無くなる
    func testRecordSurvivesSelect() async throws {
        let unchanged = [text(1, "row_30", "行 30", y: 300, type: "clickable"),
                         text(2, "txt_row_selected", "selected=-")]
        let driver = ScriptedDriver(frames: [unchanged])
        let executor = StepExecutor(driver: driver)

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30")))
        _ = await executor.execute(FlowStep(action: "select",
                                            locator: FlowLocator(id: "txt_row_selected"),
                                            timeout: 0, occlusionGuard: false))
        let outcome = await executor.execute(
            FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_row_selected"),
                     expected: "selected=row_30", timeout: 0, occlusionGuard: false))

        guard case .failed(let message) = outcome.status else {
            XCTFail("失敗するはず"); return
        }
        XCTAssertTrue(message.contains("did not change the screen at all"),
                      "select を挟んでも証跡が残ること: \(message)")
    }

    /// 画面を変える操作(swipe 等)を挟んだら記録は無効。
    /// そこから先の無変化は「そのタップのせい」とは言えない
    func testRecordIsClearedByAnotherAction() async throws {
        let unchanged = [text(1, "row_30", "行 30", y: 300, type: "clickable"),
                         text(2, "txt_row_selected", "selected=-")]
        let driver = ScriptedDriver(frames: [unchanged])
        let executor = StepExecutor(driver: driver)

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30")))
        _ = await executor.execute(FlowStep(action: "swipe", direction: "up"))
        let outcome = await executor.execute(
            FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_row_selected"),
                     expected: "selected=row_30", timeout: 0, occlusionGuard: false))

        guard case .failed(let message) = outcome.status else {
            XCTFail("失敗するはず"); return
        }
        XCTAssertFalse(message.contains("did not change the screen"),
                       "別の操作を挟んだ後は名指ししないこと: \(message)")
    }

    // MARK: - タップ点を取る手前の要素

    /// タップ点が手前の別要素の矩形に入っているなら、それも失敗文言へ添える
    /// (**無変化と同時に成立したときだけ**。画面外要素の frame が容器原点へクランプされる
    /// フレームワークでは、正常なタップでも普通に非 nil になるため単独では出さない)
    func testFrontElementTakingThePointIsNamed() async throws {
        // #row_30 の中心 (116,312) を、後ろに並ぶ(= 手前に描かれる)#row_29 が含む
        let row30 = text(1, "row_30", "行 30", y: 300, type: "clickable")
        let row29 = ElementInfo(ref: 2, type: "clickable", identifier: "row_29", label: nil,
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 16, y: 280, width: 370, height: 56), depth: 1)
        let unchanged = [row30, row29, text(3, "txt_row_selected", "selected=-", y: 500)]
        let driver = ScriptedDriver(frames: [unchanged])
        let executor = StepExecutor(driver: driver)

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30")))
        let outcome = await executor.execute(
            FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_row_selected"),
                     expected: "selected=row_30", timeout: 0, occlusionGuard: false))

        guard case .failed(let message) = outcome.status else {
            XCTFail("失敗するはず"); return
        }
        XCTAssertTrue(message.contains("#row_29"),
                      "タップ点を取っている要素を名指しすること: \(message)")
    }

    // MARK: - 「座標が古くなった」側(2026-08-05 追加)

    /// **対象があの後動いていたら、それを出す**。事後の幾何だけでは「掴んだ時点で壊れていた」と
    /// 「掴んだ後に動いた」を区別できず、実際に取り違えた(探索側を直したが一度も発火しなかった)。
    /// タップ時点の frame を持っているのはここだけなので、この注記が唯一の分け目になる
    func testFailureReportsHowFarTheTargetMovedAfterTheTap() async throws {
        // タップ時 y=300 → 検証時 y=200(= 100pt 上へ動いた)。値も変わるので「無変化」ではない
        let before = [text(1, "row_30", "行 30", y: 300, type: "clickable"),
                      text(2, "txt_row_selected", "selected=-", y: 500)]
        let after = [text(1, "row_30", "行 30", y: 200, type: "clickable"),
                     text(2, "txt_row_selected", "selected=-", y: 500)]
        let driver = ScriptedDriver(frames: [before, after])
        let executor = StepExecutor(driver: driver)

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30")))
        let outcome = await executor.execute(
            FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_row_selected"),
                     expected: "selected=row_30", timeout: 0, occlusionGuard: false))

        guard case .failed(let message) = outcome.status else {
            XCTFail("失敗するはず: \(outcome.status)"); return
        }
        XCTAssertTrue(message.contains("has moved"), "動いたことを出すこと: \(message)")
        XCTAssertTrue(message.contains("(0,-100)"), "移動量を出すこと: \(message)")
        XCTAssertFalse(message.contains("did not change the screen"),
                       "動いている = 無変化ではない(2つは排他)")
    }

    /// **わずかな揺れでは出さない**(整定のブレ・サブピクセル)。実測の取りこぼしは 98pt 級
    func testSmallJitterDoesNotProduceTheMovedNote() async throws {
        let before = [text(1, "row_30", "行 30", y: 300, type: "clickable"),
                      text(2, "txt_row_selected", "selected=-", y: 500)]
        let after = [text(1, "row_30", "行 30", y: 303, type: "clickable"),
                     text(2, "txt_row_selected", "selected=-", y: 500)]
        let driver = ScriptedDriver(frames: [before, after])
        let executor = StepExecutor(driver: driver)

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30")))
        let outcome = await executor.execute(
            FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_row_selected"),
                     expected: "selected=row_30", timeout: 0, occlusionGuard: false))

        guard case .failed(let message) = outcome.status else { XCTFail("失敗するはず"); return }
        XCTAssertFalse(message.contains("has moved"), "3pt の揺れで注記を出さないこと: \(message)")
    }

    /// 対象が**消えていたら黙る**(消えた要素について「動いた」とは言えない)
    func testDisappearedTargetIsSilent() async throws {
        let before = [text(1, "row_30", "行 30", y: 300, type: "clickable"),
                      text(2, "txt_row_selected", "selected=-", y: 500)]
        let after = [text(2, "txt_row_selected", "selected=-", y: 500)]
        let driver = ScriptedDriver(frames: [before, after])
        let executor = StepExecutor(driver: driver)

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30")))
        let outcome = await executor.execute(
            FlowStep(assert: "textEquals", locator: FlowLocator(id: "txt_row_selected"),
                     expected: "selected=row_30", timeout: 0, occlusionGuard: false))

        guard case .failed(let message) = outcome.status else { XCTFail("失敗するはず"); return }
        XCTAssertFalse(message.contains("has moved"), "\(message)")
    }

    /// 探し直しの規則(id 優先・無ければ型+ラベル・見つからなければ nil)
    func testRelocateRules() {
        let target = text(1, "row_30", "行 30", y: 300, type: "clickable")
        let moved = text(9, "row_30", "行 30", y: 100, type: "clickable")
        XCTAssertEqual(StepExecutor.relocate(target, in: [moved])?.frame.y, 100, "id で探す")

        let unnamed = ElementInfo(ref: 1, type: "clickable", identifier: nil, label: "行 30",
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 300, width: 10, height: 10), depth: 1)
        let unnamedMoved = ElementInfo(ref: 9, type: "clickable", identifier: nil, label: "行 30",
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 100, width: 10, height: 10), depth: 1)
        XCTAssertEqual(StepExecutor.relocate(unnamed, in: [unnamedMoved])?.frame.y, 100,
                       "id が無ければ型+ラベル")
        XCTAssertNil(StepExecutor.relocate(target, in: [text(9, "row_31", "行 31", y: 100)]),
                     "見つからなければ nil")
    }

    // MARK: - 見えている部分を撃つ(座標そのものを直す)

    /// **中心が容器の外に落ちる要素は、見えている部分の中心を座標で撃つ**。
    /// 実測(S0110 を8並列・交互 A/B・各40サンプル): **base 18/40(45%)→ fix 5/40(12.5%)**。
    /// ref で撃つとブリッジが frame の中心へ解決するので、壊れた frame では容器の外を叩く
    func testTapsTheVisiblePartWhenTheFrameCentreFallsOutside() async throws {
        // 実採取の形: 容器 230..692 に対し row_30 は (16,206 h=38) = 中心 225 が容器の外
        let container = ElementInfo(ref: 1, type: "other", identifier: "list_rows", label: nil,
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 16, y: 230, width: 370, height: 462), depth: 11)
        let straddling = ElementInfo(ref: 2, type: "clickable", identifier: "row_30", label: "行 30",
                                     value: nil, placeholder: nil, enabled: true,
                                     frame: FTRect(x: 16, y: 206, width: 370, height: 38), depth: 12)
        let sibling1 = ElementInfo(ref: 3, type: "clickable", identifier: "row_31", label: "行 31",
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 16, y: 244, width: 370, height: 56), depth: 12)
        let sibling2 = ElementInfo(ref: 4, type: "clickable", identifier: "row_32", label: "行 32",
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 16, y: 300, width: 370, height: 56), depth: 12)
        let tree = [container, straddling, sibling1, sibling2]
        let driver = ScriptedDriver(frames: [tree])
        let executor = StepExecutor(driver: driver)

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30")))

        XCTAssertTrue(driver.tappedRefs.isEmpty, "ref で撃つと壊れた frame の中心を叩く")
        XCTAssertEqual(driver.tappedPoints.count, 1)
        // 見えているのは 230..244 なので中心は 237
        XCTAssertEqual(driver.tappedPoints.first?.y ?? 0, 237, accuracy: 0.5)
    }

    /// **中心が容器の中なら従来どおり ref で撃つ**(in-app の accessibilityActivate の利点を捨てない)
    func testKeepsTheRefTapWhenTheCentreIsInside() async throws {
        let container = ElementInfo(ref: 1, type: "other", identifier: "list_rows", label: nil,
                                    value: nil, placeholder: nil, enabled: true,
                                    frame: FTRect(x: 16, y: 230, width: 370, height: 462), depth: 11)
        func row(_ ref: Int, _ id: String, _ y: Double) -> ElementInfo {
            ElementInfo(ref: ref, type: "clickable", identifier: id, label: id, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 12)
        }
        let tree = [container, row(2, "row_30", 300), row(3, "row_31", 356), row(4, "row_32", 412)]
        let driver = ScriptedDriver(frames: [tree])
        let executor = StepExecutor(driver: driver)

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30")))

        XCTAssertEqual(driver.tappedRefs, [2])
        XCTAssertTrue(driver.tappedPoints.isEmpty)
    }

    /// 判定の境界(純粋関数)
    func testVisibleTapRectRules() {
        let container = ElementInfo(ref: 1, type: "other", identifier: "list", label: nil, value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 16, y: 230, width: 370, height: 462), depth: 1)
        func row(_ ref: Int, _ y: Double, _ h: Double = 56) -> ElementInfo {
            ElementInfo(ref: ref, type: "clickable", identifier: "row\(ref)", label: "行", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 16, y: y, width: 370, height: h), depth: 2)
        }
        let inside1 = row(3, 300), inside2 = row(4, 360)
        let straddling = row(2, 206, 38)
        let outside = row(5, 20)
        let tree = [container, straddling, inside1, inside2, outside]
        XCTAssertEqual(StepExecutor.visibleTapRect(for: straddling, in: tree)?.y ?? -1, 230,
                       accuracy: 0.5)
        XCTAssertNil(StepExecutor.visibleTapRect(for: inside1, in: tree), "中心が中なら nil")
        XCTAssertNil(StepExecutor.visibleTapRect(for: outside, in: tree),
                     "完全に外は交点が空 = 撃つ場所が無い(別問題)")
    }

    /// **タップ経路にスナップショットを足さない**(tap は実行時間の 23% を占めるので固定費が跳ねる)。
    /// 2026-08-05 に「触る直前に対象の静止を確かめる」を入れて1枚増やしたが、
    /// 8並列の A/B で **fix 20/40 対 base 20/40 = 差ゼロ**だったので撤去した
    /// (frame は動いていない = 安定していて間違っている、が実測の答えだった)
    func testPlainTapDoesNotPayForAnExtraSnapshot() async throws {
        let frame = [text(1, "row_30", "行 30", y: 300, type: "clickable")]
        let driver = ScriptedDriver(frames: [frame])
        let executor = StepExecutor(driver: driver)

        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30")))

        XCTAssertEqual(driver.snapshotCount, 1, "探索なしのタップで取得が増えている")
    }

    /// 純粋関数側の境界(点が入っているか・自分の子孫は除く・前後関係)
    func testFrontElementTakingPointRules() {
        let target = ElementInfo(ref: 1, type: "clickable", identifier: "row", label: nil, value: nil,
                                 placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 100, height: 100), depth: 1)
        let child = ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "行", value: nil,
                                placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 100, height: 100), depth: 2)
        let sibling = ElementInfo(ref: 3, type: "other", identifier: "front", label: nil, value: nil,
                                  placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 0, width: 100, height: 100), depth: 1)
        XCTAssertNil(StepExecutor.frontElementTakingPoint(x: 50, y: 50, of: target,
                                                          in: [target, child]),
                     "自分の子孫は「手前の別要素」ではない")
        XCTAssertEqual(StepExecutor.frontElementTakingPoint(x: 50, y: 50, of: target,
                                                            in: [target, child, sibling])?.identifier,
                       "front")
        XCTAssertNil(StepExecutor.frontElementTakingPoint(x: 500, y: 50, of: target,
                                                          in: [target, child, sibling]),
                     "点を含まない要素は取らない")
        XCTAssertNil(StepExecutor.frontElementTakingPoint(x: 50, y: 50, of: target,
                                                          in: [sibling, target, child]),
                     "対象より前にある = 奥に描かれる要素は取らない")
    }
}
