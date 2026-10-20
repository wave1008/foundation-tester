// 画像判定の絵の撮り分け(FTCore.JudgmentCapture と StepExecutor.judgmentScreenshot)。
// hybrid の in-app の絵にはキーボードもシステムアラートも写らないので、覆いがあると分かっているときだけ
// 画面全体の絵(fallbackDriver = XCUITest)で撮る。

@testable import FTCore
import XCTest

final class JudgmentCaptureTests: XCTestCase {

    private func source(omits: Bool = true, whole: Bool = true, always: Bool = false,
                        keyboard: Bool = false, alert: Bool?) -> JudgmentCapture.Source {
        JudgmentCapture.source(primaryOmitsSystemUI: omits, hasWholeScreen: whole, alwaysWholeScreen: always,
                               keyboardShown: keyboard, alertCovering: alert)
    }

    func testDecisionTable() {
        // xcuitest 単独・Android・MCP(主ドライバの絵が画面全体)は今までどおり
        XCTAssertEqual(source(omits: false, keyboard: true, alert: true), .primary)
        // inapp 単独は撮り直す先が無い
        XCTAssertEqual(source(whole: false, keyboard: true, alert: true), .primary)
        XCTAssertEqual(source(keyboard: true, alert: nil), .wholeScreen, "キーボードは木だけで分かる = 聞かない")
        XCTAssertEqual(source(always: true, alert: nil), .wholeScreen)
        XCTAssertEqual(source(alert: nil), .probeSystemAlert)
        XCTAssertEqual(source(alert: true), .wholeScreen)
        XCTAssertEqual(source(alert: false), .primary)
    }

    private let alert = SystemAlertProbeResponse(present: true, title: "Allow?", buttons: ["Allow", "Don't Allow"])
    private let pngPrimary = Data([1])
    private let pngWhole = Data([2])

    private func makeExecutor(omits: Bool = true, alertFrames: [SystemAlertProbeResponse]? = nil)
        -> (StepExecutor, FakeAppDriver, FakeAppDriver) {
        let log = CallLog()
        let primary = FakeAppDriver(name: "inapp", log: log, screenshots: [pngPrimary])
        let whole = FakeAppDriver(name: "xcuitest", log: log, screenshots: [pngWhole])
        whole.systemAlertFrames = alertFrames ?? [SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: whole, primaryCaptureOmitsSystemUI: omits,
                                    isAndroid: false, tunables: RunTunables())
        return (executor, primary, whole)
    }

    func testNoCoverUsesThePrimaryAndAsksOncePerPhase() async throws {
        let (executor, _, whole) = makeExecutor()
        var phase = StepExecutor.PhaseAccumulator()
        let first = try await executor.judgmentScreenshot(keyboardShown: false, phase: &phase)
        let second = try await executor.judgmentScreenshot(keyboardShown: false, phase: &phase)
        XCTAssertEqual([first, second], [pngPrimary, pngPrimary])
        XCTAssertEqual(whole.systemAlertCallCount, 1, "同じフェーズでは聞き直さない")
        executor.armUnregisteredSystemAlertProbe()
        _ = try await executor.judgmentScreenshot(keyboardShown: false, phase: &phase)
        XCTAssertEqual(whole.systemAlertCallCount, 2, "フェーズの先頭で聞き直す")
    }

    func testKeyboardShownUsesTheWholeScreenWithoutAsking() async throws {
        let (executor, _, whole) = makeExecutor()
        var phase = StepExecutor.PhaseAccumulator()
        let shot = try await executor.judgmentScreenshot(keyboardShown: true, phase: &phase)
        XCTAssertEqual(shot, pngWhole)
        XCTAssertEqual(whole.systemAlertCallCount, 0)
    }

    func testAlertInFrontUsesTheWholeScreenAndNotesIt() async throws {
        let (executor, primary, _) = makeExecutor(alertFrames: [alert])
        var phase = StepExecutor.PhaseAccumulator()
        let shot = try await executor.judgmentScreenshot(keyboardShown: false, phase: &phase)
        XCTAssertEqual(shot, pngWhole)
        XCTAssertEqual(primary.screenshotCallCount, 0)
        XCTAssertTrue(executor.noteCodesThisStep.contains(.systemAlertPresent))
    }

    func testWithoutTheFlagNothingChanges() async throws {
        let (executor, _, whole) = makeExecutor(omits: false, alertFrames: [alert])
        var phase = StepExecutor.PhaseAccumulator()
        let shot = try await executor.judgmentScreenshot(keyboardShown: true, alwaysWholeScreen: true, phase: &phase)
        XCTAssertEqual(shot, pngPrimary)
        XCTAssertEqual(whole.systemAlertCallCount, 0, "xcuitest 単独・MCP に往復を足さない")
    }

    /// 触る操作の照会(launch 直後・フェーズ先頭)の答えを、同じフェーズの画像判定が使う
    func testTheTouchProbeAnswerIsReused() async throws {
        let (executor, _, whole) = makeExecutor(alertFrames: [alert])
        var phase = StepExecutor.PhaseAccumulator()
        _ = await executor.unregisteredSystemAlert(phase: &phase)
        let shot = try await executor.judgmentScreenshot(keyboardShown: false, phase: &phase)
        XCTAssertEqual(shot, pngWhole)
        XCTAssertEqual(whole.systemAlertCallCount, 1)
    }

    /// 可視性検証の 200ms の使い回しは、撮り分けが変わったら効かない(in-app の絵をキーボード表示中に使い回さない)
    func testGuardCacheIsNotReusedAcrossSources() async throws {
        let (executor, _, _) = makeExecutor()
        var phase = StepExecutor.PhaseAccumulator()
        let first = try await executor.guardScreenshot(keyboardShown: false, phase: &phase)
        let second = try await executor.guardScreenshot(keyboardShown: true, phase: &phase)
        XCTAssertEqual(first.data, pngPrimary)
        XCTAssertEqual(second.data, pngWhole)
        XCTAssertTrue(second.freshlyCaptured)
        let third = try await executor.guardScreenshot(keyboardShown: true, phase: &phase)
        XCTAssertFalse(third.freshlyCaptured, "同じ撮り分けなら今までどおり使い回す")
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 画像判定のファイルは主ドライバで直に撮らない(撮るのは judgmentScreenshot / judgmentCapture だけ)
    func testJudgmentFilesDoNotCaptureWithThePrimaryDirectly() throws {
        for path in ["Sources/FTCore/StepExecutor+Assert.swift", "Sources/FTCore/StepExecutor+FindImage.swift"] {
            let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("driver.screenshot()"), "\(path) が画像判定の絵を主ドライバで直に撮っている")
            XCTAssertTrue(source.contains("judgment"), "\(path) の走査が撮影の口に届いていない")
        }
    }

    /// 印を立てるのは hybrid の分岐(fallbackDriver = SystemUIDriver を組む所)だけで、FTDriveCore へ渡す
    func testScenarioRunnerSetsTheFlagOnlyForHybrid() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "Sources/FTScenarioRunner/ScenarioRunnerMain.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "primaryCaptureOmitsSystemUI = true").count - 1, 1)
        guard let hybrid = source.range(of: "if engine == \"hybrid\", let xcuiPort {"),
              let set = source.range(of: "primaryCaptureOmitsSystemUI = true") else {
            return XCTFail("hybrid の分岐か印が見つからない")
        }
        let between = source[hybrid.upperBound..<set.lowerBound]
        XCTAssertTrue(between.contains("fallbackDriver = SystemUIDriver("), "印が hybrid の fallbackDriver と別の所にある")
        XCTAssertFalse(between.contains("} else"), "印が hybrid の分岐の外にある")
        XCTAssertTrue(source.contains("primaryCaptureOmitsSystemUI: primaryCaptureOmitsSystemUI,"), "FTDriveCore へ渡していない")
    }
}
