// ft_gesture: `fingers` JSON → 絶対座標の `[FTFinger]` への変換(MCPServer+Gesture.swift)と、
// dispatch(MCPServer+GesturesTools.swift の ftGesture)の配線。
//
// TouchGesture.resolve/validate 自体の判定(点の積み上げ・本数・画面内・時刻の単調性・
// 合計秒数の上限)は TouchGestureTests(FTCoreTests)が持つ。ここで確かめるのは MCP 側の責務だけ:
// ①JSON の形だけの誤り(欠落・型違い・move/hold の二重指定)が指/ステップの番号を添えて
// デバイスに触る前に断られること ②絶対座標のまま `[FTFinger]` へ正しく写り、resolve を1回だけ
// 通って GestureRequest になること ③resolve を通った要求だけが driver.gesture(_:) に届くこと。
//
// **ネストした引数は `[String: Any]`/`[[String: Any]]` を明示する**(型推論に任せない) ——
// リテラルの型推論は要素が同じ型なら `[String: Double]` 等の具体型に落ち、production 側の
// `raw as? [String: Any]` がそのキャストを想定どおり通るかは読み手にとって自明ではない

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPGestureTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    private func call(_ args: [String: Any]) async throws -> [[String: Any]] {
        try await server.call(tool: "ft_gesture", args: args)
    }

    private func assertRejected(_ args: [String: Any], contains fragments: [String],
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await call(args)
            XCTFail("通ってはいけない: \(args)", file: file, line: line)
        } catch {
            let message = error.localizedDescription
            for fragment in fragments {
                XCTAssertTrue(message.contains(fragment), "\(message) に \"\(fragment)\" が無い",
                              file: file, line: line)
            }
        }
    }

    // MARK: - JSON の形(デバイスに触る前に断る)

    func testMissingFingersIsRejected() async {
        await assertRejected([:], contains: ["fingers"])
        XCTAssertEqual(driver.calls, [])
    }

    func testEmptyFingersArrayIsRejected() async {
        let fingers: [[String: Any]] = []
        await assertRejected(["fingers": fingers], contains: ["fingers", "empty"])
        XCTAssertEqual(driver.calls, [])
    }

    func testNonArrayFingersIsRejected() async {
        await assertRejected(["fingers": "nope"], contains: ["fingers", "array"])
        XCTAssertEqual(driver.calls, [])
    }

    func testNonObjectFingerElementIsRejected() async {
        let fingers: [Any] = ["nope"]
        await assertRejected(["fingers": fingers], contains: ["finger 1", "object"])
        XCTAssertEqual(driver.calls, [])
    }

    func testMissingCoordinateNamesTheFingerAndKey() async {
        let missingX: [[String: Any]] = [["y": 20.0]]
        await assertRejected(["fingers": missingX], contains: ["finger 1.x", "required"])
        let missingY: [[String: Any]] = [["x": 10.0]]
        await assertRejected(["fingers": missingY], contains: ["finger 1.y", "required"])
        XCTAssertEqual(driver.calls, [])
    }

    func testWrongTypeCoordinateNamesTheFingerAndKey() async {
        let fingers: [[String: Any]] = [["x": 10.0, "y": "abc"]]
        await assertRejected(["fingers": fingers],
                             contains: ["finger 1.y", "must be a number", "the string \"abc\""])
        XCTAssertEqual(driver.calls, [])
    }

    func testNonObjectStepIsRejected() async {
        let steps: [Any] = ["nope"]
        let fingers: [[String: Any]] = [["x": 10.0, "y": 20.0, "steps": steps]]
        await assertRejected(["fingers": fingers], contains: ["finger 1, step 1", "object"])
        XCTAssertEqual(driver.calls, [])
    }

    func testStepWithNeitherMoveNorHoldFieldsIsRejected() async {
        let steps: [[String: Any]] = [[:]]
        let fingers: [[String: Any]] = [["x": 10.0, "y": 20.0, "steps": steps]]
        await assertRejected(["fingers": fingers], contains: ["finger 1, step 1", "move", "hold"])
        XCTAssertEqual(driver.calls, [])
    }

    func testStepWithBothMoveAndHoldFieldsIsRejected() async {
        let steps: [[String: Any]] = [
            ["x": 15.0, "y": 20.0, "durationSeconds": 0.3, "holdSeconds": 0.2],
        ]
        let fingers: [[String: Any]] = [["x": 10.0, "y": 20.0, "steps": steps]]
        await assertRejected(["fingers": fingers], contains: ["finger 1, step 1", "both"])
        XCTAssertEqual(driver.calls, [])
    }

    func testMoveStepMissingDurationSecondsIsRejected() async {
        let steps: [[String: Any]] = [["x": 15.0, "y": 20.0]]
        let fingers: [[String: Any]] = [["x": 10.0, "y": 20.0, "steps": steps]]
        await assertRejected(["fingers": fingers],
                             contains: ["finger 1, step 1.durationSeconds", "required"])
        XCTAssertEqual(driver.calls, [])
    }

    // MARK: - 絶対座標のまま GestureRequest へ写る

    /// steps 無し = ただのタップ&リフト(TouchGesture.minimumContactSeconds ぶん置いて離す)
    func testFingerWithNoStepsBecomesATapAndLift() async throws {
        let fingers: [[String: Any]] = [["x": 10.0, "y": 20.0]]
        _ = try await call(["fingers": fingers])
        let expected = GestureRequest(fingers: [GestureFinger(points: [
            GesturePoint(x: 10, y: 20, t: 0),
            GesturePoint(x: 10, y: 20, t: TouchGesture.minimumContactSeconds),
        ])])
        XCTAssertEqual(driver.lastGestureRequest, expected)
        XCTAssertEqual(driver.calls.last, "gesture(fingers:1)")
    }

    /// startSeconds・move・hold が順に積み上がること(2本指: 1本は遅らせて置く)
    func testMoveAndHoldStepsAccumulateAbsoluteTimeAndPosition() async throws {
        let steps: [[String: Any]] = [
            ["x": 50.0, "y": 60.0, "durationSeconds": 0.5],
            ["holdSeconds": 0.3],
        ]
        let fingers: [[String: Any]] = [
            ["x": 10.0, "y": 20.0, "steps": steps],
            ["x": 200.0, "y": 200.0, "startSeconds": 0.2],
        ]
        _ = try await call(["fingers": fingers])
        var afterMove: Double = 0
        afterMove += 0.5
        var afterHold = afterMove
        afterHold += 0.3
        let expected = GestureRequest(fingers: [
            GestureFinger(points: [
                GesturePoint(x: 10, y: 20, t: 0),
                GesturePoint(x: 50, y: 60, t: afterMove),
                GesturePoint(x: 50, y: 60, t: afterHold),
            ]),
            GestureFinger(points: [
                GesturePoint(x: 200, y: 200, t: 0.2),
                GesturePoint(x: 200, y: 200, t: 0.2 + TouchGesture.minimumContactSeconds),
            ]),
        ])
        XCTAssertEqual(driver.lastGestureRequest, expected)
    }

    /// 直近の木があれば screen 判定のために撮り直さない(coordinateScreen の doc と同じ規律。
    /// ft_double_tap/ft_drag の座標形と同じ節約)
    func testReusesAnExistingSnapshotInsteadOfTakingAnother() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let before = driver.calls.count
        let fingers: [[String: Any]] = [["x": 10.0, "y": 20.0]]
        _ = try await call(["fingers": fingers])
        let added = driver.calls[before...]
        XCTAssertFalse(added.contains { $0.hasPrefix("snapshot") }, "\(added)")
        XCTAssertEqual(added.last, "gesture(fingers:1)")
    }

    /// 絶対座標 → 比率への割り戻し。**resolve 前の `[FTFinger]` から直接割る**(点への展開を
    /// 経由しない)ので、move/hold の分類はそのまま素通しされる
    func testGestureFingersRatioDividesAbsoluteCoordinatesByScreen() {
        let screen = FTRect(x: 0, y: 0, width: 390, height: 844)
        let finger = FTFinger(x: 0, y: 0).move(x: 390, y: 844, durationSeconds: 0.5)
            .hold(seconds: 0.5)
        let fingers = MCPServer.gestureFingersRatio([finger], screen: screen)
        XCTAssertEqual(fingers.count, 1)
        let ratio = fingers[0]
        XCTAssertEqual(ratio.x, 0)
        XCTAssertEqual(ratio.y, 0)
        XCTAssertEqual(ratio.startSeconds, 0)
        XCTAssertEqual(ratio.steps, [
            .move(x: 1, y: 1, durationSeconds: 0.5),
            .hold(seconds: 0.5),
        ])
    }

    /// screen の原点(x, y)が 0 でなくても比率が正しく引かれること。steps 無し(タップ&リフト)の
    /// 指は steps 無しのまま割り戻る —— `TouchGesture.minimumContactSeconds` の作り物の hold は
    /// resolve が点へ展開するときにだけ足すもので、送信前の `[FTFinger]` には無い
    func testGestureFingersRatioAccountsForScreenOrigin() {
        let screen = FTRect(x: 100, y: 200, width: 200, height: 400)
        let finger = FTFinger(x: 150, y: 400)
        let fingers = MCPServer.gestureFingersRatio([finger], screen: screen)
        XCTAssertEqual(fingers.count, 1)
        XCTAssertEqual(fingers[0].x, 0.25)
        XCTAssertEqual(fingers[0].y, 0.5)
        XCTAssertEqual(fingers[0].steps, [])
    }

    /// 成功した gesture は下書き材料(InteractionLog)へ残る —— FlowStep.gesture に比率へ
    /// 割り戻した FTFinger を積む(DSL の gesture は比率で書くため)。**ScenarioCodeGen が
    /// "gesture" ケースを持つかはここでは断定しない**(別ファイル・別エージェントの持ち物) ——
    /// 未対応の間は「// (unsupported step: …)」に落ちるだけで壊れない(他の未対応アクションと同じ
    /// 経路)。ここで固定するのは「記録されること」だけ
    func testGestureIsRecordedForTheDraft() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        let fingers: [[String: Any]] = [["x": 10.0, "y": 20.0]]
        _ = try await call(["fingers": fingers])
        let draft = try await server.call(tool: "ft_draft_scenario", args: [:])
        let text = draft.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("gesture"), text)
    }

    // MARK: - TouchGesture.validate へ委ねる判定(デバイスに触る前・screen は必要)

    /// 6本指(TouchGesture.maxFingers=5 を超える)
    func testTooManyFingersIsRejectedByValidate() async {
        let fingers: [[String: Any]] = (0..<6).map { i in ["x": Double(i) * 10, "y": 10.0] }
        await assertRejected(["fingers": fingers], contains: ["at most \(TouchGesture.maxFingers) fingers"])
        // TouchGesture.validate は screen を必須で取る(唯一の門)ので、本数だけで落ちる要求でも
        // screen 取得の "snapshot" は先に撃ってしまう(driver.gesture(_:) は撃たない)
        XCTAssertEqual(driver.calls, ["snapshot"])
    }

    func testOffscreenPointIsRejectedByValidate() async {
        // FakeDriver の既定 screen は 390x844(FakeDriver.swift)
        let fingers: [[String: Any]] = [["x": 5000.0, "y": 20.0]]
        await assertRejected(["fingers": fingers], contains: ["off the screen"])
        XCTAssertEqual(driver.calls, ["snapshot"])
    }

    /// 上書き無しの既定上限は10秒(BridgeAPI.defaultMaxGestureSeconds)
    func testExceedsDefaultCapWithoutOverrideIsRejected() async {
        let steps: [[String: Any]] = [["x": 10.0, "y": 20.0, "durationSeconds": 15.0]]
        let fingers: [[String: Any]] = [["x": 10.0, "y": 20.0, "steps": steps]]
        await assertRejected(["fingers": fingers], contains: ["maxGestureSeconds", "10 seconds or less"])
        XCTAssertEqual(driver.calls, ["snapshot"])
    }

    func testMaxGestureSecondsOverrideAllowsALongerGesture() async throws {
        let steps: [[String: Any]] = [["x": 10.0, "y": 20.0, "durationSeconds": 15.0]]
        let fingers: [[String: Any]] = [["x": 10.0, "y": 20.0, "steps": steps]]
        _ = try await call(["fingers": fingers, "maxGestureSeconds": 20.0])
        XCTAssertEqual(driver.calls, ["snapshot", "gesture(fingers:1)"])
    }

    /// maxGestureSeconds 自体が絶対上限(60)を超えるのは、値域の入口(ArgumentBounds)で
    /// dispatch より前に断られる —— fingers の中身を読む前もドライバに触る前も無い
    func testMaxGestureSecondsAboveCeilingIsRejectedAtTheEntry() async {
        let fingers: [[String: Any]] = [["x": 10.0, "y": 20.0]]
        await assertRejected(["fingers": fingers, "maxGestureSeconds": 61.0], contains: ["maxGestureSeconds"])
        XCTAssertEqual(driver.calls, [])
    }
}
