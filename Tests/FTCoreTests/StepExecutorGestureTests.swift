import XCTest
@testable import FTCore

// StepExecutorTests の "gesture" アクション(ひと続きの多点ジェスチャ)専用。
// 比率→絶対座標の写し自体は TouchGestureTests(純粋関数)が持つので、ここは
// 「StepExecutor が正しい target/viewport を渡すこと」「失敗時にドライバへ触らないこと」
// 「501 で typeDriver へ回ること」の配線だけを見る(pinchOut/pinchIn と対になる形。
// StepExecutorTests+Gestures.swift のマップ系ジェスチャのテストを参照)。

extension StepExecutorTests {

    /// 対象未指定は画面全体(target = snapshot.screen)。**PinchRegion で絞らない**
    /// (pinch との違い。両方の指が同じものに載る必要はここには無い)
    func testGestureWithoutLocatorTargetsTheWholeScreen() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let finger = FTFinger(x: 0.25, y: 0.5).move(x: 0.75, y: 0.5, durationSeconds: 0.3)
        let step = FlowStep(action: "gesture", gesture: [finger])

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("gesture の passed を期待したが \(outcome.status) だった"); return
        }
        let points = try XCTUnwrap(primary.lastGesture?.fingers.first?.points)
        // FakeAppDriver.snapshot() の画面は (0, 0, 400x800)
        XCTAssertEqual(points[0].x, 100, accuracy: 0.001)
        XCTAssertEqual(points[0].y, 400, accuracy: 0.001)
        XCTAssertEqual(points[1].x, 300, accuracy: 0.001)
        XCTAssertEqual(points[1].y, 400, accuracy: 0.001)
    }

    /// セレクタ付きは**要素の frame**が対象(pinch と同じ規約)
    func testGestureWithLocatorTargetsTheElementFrame() async throws {
        let log = CallLog()
        let pad = framed(ref: 1, id: "pad", x: 10, y: 40, width: 300, height: 200)
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[pad]])
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let finger = FTFinger(x: 0, y: 0).move(x: 1, y: 1, durationSeconds: 0.2)
        let step = FlowStep(action: "gesture", locator: FlowLocator(id: "pad"), gesture: [finger])

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("gesture の passed を期待したが \(outcome.status) だった"); return
        }
        let points = try XCTUnwrap(primary.lastGesture?.fingers.first?.points)
        XCTAssertEqual(points[0].x, 10, accuracy: 0.001)
        XCTAssertEqual(points[0].y, 40, accuracy: 0.001)
        XCTAssertEqual(points[1].x, 310, accuracy: 0.001)
        XCTAssertEqual(points[1].y, 240, accuracy: 0.001)
    }

    /// 指を1本も積まない不正な指定は**デバイスに触らず**失敗する(TouchGesture.resolve の門)
    func testGestureRejectsEmptySpecWithoutTouchingTheDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let step = FlowStep(action: "gesture", gesture: [])

        let outcome = await executor.execute(step)

        guard case .failed(let reason) = outcome.status else {
            XCTFail("指0本は failed のはず: \(outcome.status)"); return
        }
        XCTAssertTrue(reason.contains("at least one finger"), reason)
        XCTAssertNil(primary.lastGesture, "撃たないこと")
        XCTAssertFalse(log.entries.contains { $0.contains(".gesture") },
                       "デバイスの gesture ルートへ一度も触れていないはず: \(log.entries)")
    }

    /// 既定 10 秒を超える総所要(maxGestureSeconds 未指定)も**デバイスに触らず**失敗する
    /// (executeAction の入口ではなく TouchGesture.validate 側の門。duration が nil の gesture では
    /// 入口の gestureDurationViolation は総所要を見ないため、ここで確かに落ちることを確認する)
    func testGestureRejectsTotalOverTheDefaultCapWithoutTouchingTheDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let finger = FTFinger(x: 0.2, y: 0.2).move(x: 0.8, y: 0.8, durationSeconds: 11)
        let step = FlowStep(action: "gesture", gesture: [finger])

        let outcome = await executor.execute(step)

        guard case .failed(let reason) = outcome.status else {
            XCTFail("11秒(上書き無し)は failed のはず: \(outcome.status)"); return
        }
        XCTAssertTrue(reason.contains("must be 10 seconds or less"), reason)
        XCTAssertNil(primary.lastGesture, "撃たないこと")
    }

    /// `maxGestureSeconds:` を添えれば、その値までは通ってドライバへ届く
    func testGestureWithinMaxGestureSecondsOverrideReachesTheDriver() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let finger = FTFinger(x: 0.2, y: 0.2).move(x: 0.8, y: 0.8, durationSeconds: 11)
        var step = FlowStep(action: "gesture", gesture: [finger])
        step.maxGestureSeconds = 30

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("上書き(30)の範囲内なので成功するはず: \(outcome.status)"); return
        }
        XCTAssertNotNil(primary.lastGesture)
    }

    /// `maxGestureSeconds:` 自体が絶対上限(60)を超えるときは、**executeAction の入口**
    /// (duration が nil でも maxGestureSeconds は見る)で、デバイスに一切触れず失敗する
    func testGestureMaxGestureSecondsAboveCeilingFailsAtTheEntryGate() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, isAndroid: false)
        let finger = FTFinger(x: 0.2, y: 0.2).move(x: 0.8, y: 0.8, durationSeconds: 1)
        var step = FlowStep(action: "gesture", gesture: [finger])
        step.maxGestureSeconds = 61

        let outcome = await executor.execute(step)

        guard case .failed(let reason) = outcome.status else {
            XCTFail("maxGestureSeconds=61 は failed のはず: \(outcome.status)"); return
        }
        XCTAssertTrue(reason.contains("maxGestureSeconds"), reason)
        XCTAssertTrue(log.entries.isEmpty, "デバイスへ一度も触れていないはず: \(log.entries)")
    }

    /// in-app 相当(501)なら typeDriver へ回すこと。座標はそのまま渡る(ref を使わないので取り直し不要)
    func testGestureFallsBackToTypeDriverWhenEngineIncapable() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[]])
        primary.gestureError = DriverError.badResponse(status: 501, body: "in-app では gesture が効きません")
        let typeDriver = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [[]])
        let executor = StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false)
        let finger = FTFinger(x: 0.5, y: 0.5).hold(seconds: 0.1)
        let step = FlowStep(action: "gesture", gesture: [finger])

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else {
            XCTFail("501 からの切替による passed を期待したが \(outcome.status) だった"); return
        }
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
        XCTAssertNotNil(typeDriver.lastGesture, "typeDriver 側へ届いていること")
    }
}
