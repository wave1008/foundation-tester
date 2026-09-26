import XCTest
@testable import fleetest
import FTBridgeClient
import FTCore

/// live serve の command watchdog と、正当に長く占有しうる操作の猶予(`watchdogAllowanceSeconds`)。
/// press/drag/pinch/gesture は指定秒数ぶん、launch/activate/install は内側の上限
/// (xcuitest の session 45秒・実機 install の 600秒)ぶん猶予が要る——猶予0だと、正当な
/// 失敗の後始末(観測の撮り直し)中に watchdog が serve ごと殺す。
/// ①watchdog の基準値を固定 ②猶予が perform() と同じ既定値から計算されることを固定する
/// ③猶予が各コマンドの内側の上限を watchdog の基準値越しに超えることを固定する。
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

    // MARK: - watchdogAllowanceSeconds

    private func command(_ cmd: String, _ raw: [String: Any]) -> ApiLiveServeCommand {
        var merged = raw
        merged["cmd"] = cmd
        return ApiLiveServeCommand(cmd: cmd, raw: merged)
    }

    /// 内側の上限が watchdog 基準値(30秒)を超えない通常のコマンドは allowance 0
    func testNonGestureCommandsHaveNoAllowance() {
        XCTAssertEqual(command("tap", ["ref": 1]).watchdogAllowanceSeconds, 0)
        XCTAssertEqual(command("back", [:]).watchdogAllowanceSeconds, 0)
    }

    /// press の allowance は指定した duration そのもの(縮めない)
    func testPressAllowanceIsTheRequestedDuration() {
        let cmd = command("press", ["x": 10, "y": 20, "duration": 45.0, "maxGestureSeconds": 45.0])
        XCTAssertEqual(cmd.watchdogAllowanceSeconds, 45)
    }

    /// press の duration 省略時(perform() が別途 invalidArguments で断るが、allowance の算出
    /// 自体は 0 に倒れる——固定の watchdog 基準値だけで、断るところまでは十分間に合う)
    func testPressAllowanceIsZeroWhenDurationOmitted() {
        XCTAssertEqual(command("press", ["x": 10, "y": 20]).watchdogAllowanceSeconds, 0)
    }

    /// drag の既定 press/duration は perform() が使う ApiLiveGestureDefaults と同じもの
    func testDragAllowanceUsesTheSameDefaultsAsPerform() {
        let cmd = command("drag", ["fromX": 0, "fromY": 0, "toX": 10, "toY": 10])
        XCTAssertEqual(cmd.watchdogAllowanceSeconds,
            ApiLiveGestureDefaults.dragPressSeconds + ApiLiveGestureDefaults.dragDurationSeconds)
    }

    /// drag に press/duration を明示したら、その合計を allowance にする
    func testDragAllowanceSumsExplicitPressAndDuration() {
        let cmd = command("drag", ["fromX": 0, "fromY": 0, "toX": 10, "toY": 10,
                                    "press": 1.0, "duration": 2.0])
        XCTAssertEqual(cmd.watchdogAllowanceSeconds, 3)
    }

    /// pinch の既定 duration は perform() が使う ApiLiveGestureDefaults と同じもの
    func testPinchAllowanceUsesTheSameDefaultAsPerform() {
        let cmd = command("pinch", ["scale": 2.0])
        XCTAssertEqual(cmd.watchdogAllowanceSeconds, ApiLiveGestureDefaults.pinchDurationSeconds)
    }

    func testPinchAllowanceIsTheRequestedDuration() {
        let cmd = command("pinch", ["scale": 2.0, "duration": 10.0])
        XCTAssertEqual(cmd.watchdogAllowanceSeconds, 10)
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
        XCTAssertEqual(cmd.watchdogAllowanceSeconds, 5.5)
    }

    /// gesture で fingers を欠く(decodeError になる行)は allowance 0 —— perform を通らず
    /// actionResult(ok:false)ですぐ答えるので、待つ理由が無い
    func testGestureAllowanceIsZeroWithoutFingers() {
        XCTAssertEqual(command("gesture", [:]).watchdogAllowanceSeconds, 0)
    }

    // MARK: - launch/activate/install(内側の上限が watchdog 基準値を超えるコマンド)

    /// launch/activate の allowance は BridgeClient.Timeout.session(xcuitest 経由の内側の上限)
    func testLaunchAndActivateAllowanceIsTheSessionTimeout() {
        XCTAssertEqual(command("launch", ["bundle": "com.example.app"]).watchdogAllowanceSeconds,
                       BridgeClient.Timeout.session)
        XCTAssertEqual(command("activate", ["bundle": "com.example.app"]).watchdogAllowanceSeconds,
                       BridgeClient.Timeout.session)
    }

    /// install の allowance は実機 devicectl install の上限そのもの
    func testInstallAllowanceIsThePhysicalInstallTimeout() {
        XCTAssertEqual(command("install", ["path": "/tmp/App.app"]).watchdogAllowanceSeconds,
                       BridgeClient.Timeout.physicalInstall)
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
        XCTAssertEqual(cmd.watchdogAllowanceSeconds, ceiling)
        // watchdog + allowance が、その1コマンドの実際の HTTP タイムアウト
        // (BridgeClient の interaction 20 秒 + duration)より大きいこと(force-quit されない)
        let totalWatchdogBudget = ApiLiveServe.commandWatchdogMaxSeconds + cmd.watchdogAllowanceSeconds
        let actualRequestTimeout = 20 + ceiling
        XCTAssertGreaterThan(totalWatchdogBudget, actualRequestTimeout)
    }

    /// launch/activate の内側の上限(xcuitest の session)は45秒——watchdog 基準値+allowance は
    /// それをリテラルの45で超えること(production の定数から計算しない = 定数自体が縮んだときも
    /// この不等式で検出する)
    func testWatchdogPlusLaunchAllowanceExceedsTheSessionTimeoutLiteral() {
        let cmd = command("launch", ["bundle": "com.example.app"])
        let totalWatchdogBudget = ApiLiveServe.commandWatchdogMaxSeconds + cmd.watchdogAllowanceSeconds
        XCTAssertGreaterThan(totalWatchdogBudget, 45)
    }

    /// install の内側の上限(実機 devicectl)は600秒——同じ不等式をリテラルの600で固定する
    func testWatchdogPlusInstallAllowanceExceedsThePhysicalInstallTimeoutLiteral() {
        let cmd = command("install", ["path": "/tmp/App.app"])
        let totalWatchdogBudget = ApiLiveServe.commandWatchdogMaxSeconds + cmd.watchdogAllowanceSeconds
        XCTAssertGreaterThan(totalWatchdogBudget, 600)
    }
}
