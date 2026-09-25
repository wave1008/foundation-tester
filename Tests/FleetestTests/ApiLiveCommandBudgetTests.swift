import XCTest
@testable import fleetest
import FTCore

/// live serve の command watchdog と、秒数を指定する操作の猶予(`gestureAllowanceSeconds`)。
/// press/drag/pinch は最大60秒の指定を受けるのに猶予が軌跡(gesture)にしか無く、正当な長押しが
/// watchdog(30秒)に強制終了されていた。①watchdog の基準値を固定 ②猶予が perform() と同じ既定値から
/// 計算されることを固定する。
final class ApiLiveCommandBudgetTests: XCTestCase {

    // MARK: - リテラルの固定

    func testCommandWatchdogMaxSecondsLiteral() {
        XCTAssertEqual(ApiLiveServe.commandWatchdogMaxSeconds, 30)
    }

    // MARK: - 予算の算術(純粋。デバイス不要)

    func testWatchdogExceedsExtensionRequestTimeout() {
        let extensionRequestTimeoutSeconds: Double = 20
        XCTAssertGreaterThan(ApiLiveServe.commandWatchdogMaxSeconds, extensionRequestTimeoutSeconds)
    }

    // MARK: - gestureAllowanceSeconds(watchdog allowance)

    private func command(_ cmd: String, _ raw: [String: Any]) -> ApiLiveServeCommand {
        var merged = raw
        merged["cmd"] = cmd
        return ApiLiveServeCommand(cmd: cmd, raw: merged)
    }

    /// 通常のコマンド(gesture 系以外)は allowance 0 —— 固定の watchdog 基準値だけで足りる
    func testNonGestureCommandsHaveNoAllowance() {
        XCTAssertEqual(command("tap", ["ref": 1]).gestureAllowanceSeconds, 0)
        XCTAssertEqual(command("back", [:]).gestureAllowanceSeconds, 0)
        XCTAssertEqual(command("launch", ["bundle": "com.example.app"]).gestureAllowanceSeconds, 0)
    }

    /// press の allowance は指定した duration そのもの(縮めない)
    func testPressAllowanceIsTheRequestedDuration() {
        let cmd = command("press", ["x": 10, "y": 20, "duration": 45.0, "maxGestureSeconds": 45.0])
        XCTAssertEqual(cmd.gestureAllowanceSeconds, 45)
    }

    /// press の duration 省略時(perform() が別途 invalidArguments で断るが、allowance の算出
    /// 自体は 0 に倒れる——固定の watchdog 基準値だけで、断るところまでは十分間に合う)
    func testPressAllowanceIsZeroWhenDurationOmitted() {
        XCTAssertEqual(command("press", ["x": 10, "y": 20]).gestureAllowanceSeconds, 0)
    }

    /// drag の既定 press/duration は perform() が使う ApiLiveGestureDefaults と同じもの
    func testDragAllowanceUsesTheSameDefaultsAsPerform() {
        let cmd = command("drag", ["fromX": 0, "fromY": 0, "toX": 10, "toY": 10])
        XCTAssertEqual(cmd.gestureAllowanceSeconds,
            ApiLiveGestureDefaults.dragPressSeconds + ApiLiveGestureDefaults.dragDurationSeconds)
    }

    /// drag に press/duration を明示したら、その合計を allowance にする
    func testDragAllowanceSumsExplicitPressAndDuration() {
        let cmd = command("drag", ["fromX": 0, "fromY": 0, "toX": 10, "toY": 10,
                                    "press": 1.0, "duration": 2.0])
        XCTAssertEqual(cmd.gestureAllowanceSeconds, 3)
    }

    /// pinch の既定 duration は perform() が使う ApiLiveGestureDefaults と同じもの
    func testPinchAllowanceUsesTheSameDefaultAsPerform() {
        let cmd = command("pinch", ["scale": 2.0])
        XCTAssertEqual(cmd.gestureAllowanceSeconds, ApiLiveGestureDefaults.pinchDurationSeconds)
    }

    func testPinchAllowanceIsTheRequestedDuration() {
        let cmd = command("pinch", ["scale": 2.0, "duration": 10.0])
        XCTAssertEqual(cmd.gestureAllowanceSeconds, 10)
    }

    /// gesture(軌跡モード)の allowance は最後の指が離れる時刻(従来どおり)
    func testGestureAllowanceIsTheTrajectoryPlaybackTime() {
        let raw: [String: Any] = [
            "cmd": "gesture",
            "fingers": [
                ["points": [["x": 0, "y": 0, "t": 0], ["x": 10, "y": 10, "t": 5.5]]],
            ],
        ]
        let cmd = ApiLiveServeCommand(cmd: "gesture", raw: raw)
        XCTAssertEqual(cmd.gestureAllowanceSeconds, 5.5)
    }

    /// gesture で fingers を欠く(decodeError になる行)は allowance 0 —— perform を通らず
    /// actionResult(ok:false)ですぐ答えるので、待つ理由が無い
    func testGestureAllowanceIsZeroWithoutFingers() {
        XCTAssertEqual(command("gesture", [:]).gestureAllowanceSeconds, 0)
    }

    // MARK: - ArgumentBounds.gestureSecondsCeiling(60秒)まで allowance が伸びても watchdog は破綻しない

    /// **allowance を最大まで使った1コマンド**でも、watchdog の基準値+allowance は
    /// 「基礎の外部呼び出し合計(≒ margin 付きで watchdog 以内)+ 正味の追加分(duration)」で
    /// 収まる。press/drag/pinch/gesture が `BridgeClient.timeout(forDuration:)` で使う本体の
    /// タイムアウト自体は `interaction(20秒)+ duration` なので、この allowance は
    /// duration の全量をそのまま watchdog に足すだけで十分(過不足の判定は
    /// ApiLiveCommand.swift のコメント参照)
    func testMaximalGestureAllowanceStillLeavesTheBaseBudgetIntact() {
        let ceiling: Double = 60
        let cmd = command("press", ["x": 0, "y": 0, "duration": ceiling, "maxGestureSeconds": ceiling])
        XCTAssertEqual(cmd.gestureAllowanceSeconds, ceiling)
        // watchdog + allowance が、その1コマンドの実際の HTTP タイムアウト
        // (BridgeClient の interaction 20 秒 + duration)より大きいこと(force-quit されない)
        let totalWatchdogBudget = ApiLiveServe.commandWatchdogMaxSeconds + cmd.gestureAllowanceSeconds
        let actualRequestTimeout = 20 + ceiling
        XCTAssertGreaterThan(totalWatchdogBudget, actualRequestTimeout)
    }
}
