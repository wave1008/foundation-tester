// ステータスバー以外が真っ黒の絵(撮れていない・表示の凍結)を、画像で判定する経路の根拠にしない。
// 実測(Android Emulator・配信 24fps + 8 並列): CheckStateClassifier が真っ黒の絵の切り出しを
// ON の要素なのに「[OFF]・確信度 1.00」と答えて checkIsON が赤になった。findImage は同じ絵で
// 全候補が似ていない = 見つからない(`isEmpty` での否定なら誤った緑)になる。

import CoreGraphics
import XCTest
@testable import FTCore

final class BlankScreenshotJudgementTests: XCTestCase {

    private static func blackPNG() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BlackFrames/android-emulator-black-with-status-bar.png")
        return try Data(contentsOf: url)
    }

    func testTheClassifierDoesNotJudgeABlackScreenshot() async throws {
        let root = try CheckStateClassifierTests.makeProject(script: "// options=-noise\n// imageFilter=binary")
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try XCTUnwrap(try VisionClassifier.trainingSet(at: CheckStateClassifier.directory(projectRoot: root)))
        let model = try VisionClassifier.loadBlocking(set, cacheDirectory: CheckStateClassifier.cacheDirectory(projectRoot: root))
        let driver = FakeAppDriver(name: "primary", log: CallLog())
        driver.screenshots = [try Self.blackPNG()]
        let executor = StepExecutor(driver: driver, isAndroid: true)
        let element = ElementInfo(ref: 1, type: "checkBox", identifier: "cb", label: nil, value: nil,
                                  placeholder: nil, enabled: true,
                                  frame: FTRect(x: 100, y: 800, width: 200, height: 200), depth: 1)

        let classification = await executor.classifyElementImage(
            element, screen: FTRect(x: 0, y: 0, width: 1080, height: 2424), with: model)

        XCTAssertNil(classification, "真っ黒の絵は分類しない")
        XCTAssertTrue(executor.classifierFailureThisStep?.contains("a single colour") == true,
                      executor.classifierFailureThisStep ?? "nil")

        // 画面全体が一色(ステータスバーも無い白)も分類しない
        driver.screenshots = [Self.whitePNG()]
        executor.classifierFailureThisStep = nil
        let white = await executor.classifyElementImage(
            element, screen: FTRect(x: 0, y: 0, width: 1080, height: 2424), with: model)
        XCTAssertNil(white, "全面が一色の絵は分類しない")
        XCTAssertNotNil(executor.classifierFailureThisStep)
    }

    /// ステータスバーも描かれていない全面の白(実測の絵と同じ #FEFEFE)
    private static func whitePNG() -> Data {
        let context = CGContext(data: nil, width: 108, height: 242, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 254 / 255, green: 254 / 255, blue: 254 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 108, height: 242))
        return CheckStateClassifierTests.png(context.makeImage()!)
    }

    /// ステータスバーの有無に関わらず、アプリの領域が一色なら外す。中身のある画面は外さない
    func testFlatAppAreaIsUnjudgeableWithOrWithoutTheStatusBar() throws {
        func screen(background gray: CGFloat, statusBar: Bool, content: Bool) -> Data {
            let context = CGContext(data: nil, width: 108, height: 242, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 108, height: 242))
            context.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
            if statusBar {   // 上端(CG は下が原点)
                context.fill(CGRect(x: 4, y: 232, width: 30, height: 6))
                context.fill(CGRect(x: 80, y: 232, width: 20, height: 6))
            }
            if content { context.fill(CGRect(x: 10, y: 120, width: 60, height: 14)) }   // ボタン1つ
            return CheckStateClassifierTests.png(context.makeImage()!)
        }
        XCTAssertTrue(BlankFrameDetector.isUnjudgeable(pngData: screen(background: 250 / 255, statusBar: true, content: false)))
        XCTAssertTrue(BlankFrameDetector.isUnjudgeable(pngData: screen(background: 250 / 255, statusBar: false, content: false)))
        XCTAssertTrue(BlankFrameDetector.isUnjudgeable(pngData: screen(background: 0, statusBar: true, content: false)))
        XCTAssertFalse(BlankFrameDetector.isUnjudgeable(pngData: screen(background: 250 / 255, statusBar: true, content: true)))
        XCTAssertFalse(BlankFrameDetector.isUnjudgeable(pngData: screen(background: 0, statusBar: true, content: true)))
        XCTAssertTrue(BlankFrameDetector.isUnjudgeable(pngData: try Self.blackPNG()))
    }

    // MARK: - findImage

    /// FindImageTests の ScreenDriver と同じ画面(300x100)で、スクリーンショットだけを順に返す
    private final class SequenceDriver: AppDriver {
        let elements: [ElementInfo]
        var shots: [Data]
        private(set) var shotCount = 0
        init(elements: [ElementInfo], shots: [Data]) { self.elements = elements; self.shots = shots }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 300, height: 100),
                             elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data {
            defer { shotCount += 1 }
            return shots[min(shotCount, shots.count - 1)]
        }
        func terminate() async throws {}
    }

    private func findCircle(_ executor: StepExecutor) async -> StepOutcome {
        await executor.execute(FlowStep(action: "findImage", expected: "[Circle Icon]", timeout: 0,
                                        imageThreshold: FindImage.defaultThreshold))
    }

    func testFindImageRetakesABlackScreenshotInsteadOfReportingNothingFound() async throws {
        let fixture = FindImageTests()
        let root = try fixture.makeProjectForExtension()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = SequenceDriver(elements: fixture.screenElements,
                                    shots: [try Self.blackPNG(), FindImageTests.screenPNG()])
        let executor = StepExecutor(driver: driver, isAndroid: false)
        executor.visionClassifierProjectRoot = root

        let outcome = await findCircle(executor)

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(outcome.imageMatches?.map(\.element.identifier), ["circle"], "撮り直した絵で見つける")
        XCTAssertEqual(driver.shotCount, 2, "一色の1枚目は照合せずに撮り直す")
        XCTAssertTrue(outcome.notes.contains(.blankScreenshotRetaken))
        XCTAssertFalse(outcome.notes.contains(.visionAnomalyRetried), "Vision の異常とは言い分ける")
    }

    /// 前の検証が控えた絵のまま(木は遷移後)なら照合せずに待って撮り直す。遷移前の絵で照合すると
    /// 全候補が似ていない = 0 件(実測 Flutter: 遷移直後の findImages "[Switch]" が 0 件で何もタップされなかった)
    func testFindImageWaitsWhileThePictureIsStillTheOneBeforeTheTransition() async throws {
        let fixture = FindImageTests()
        let root = try fixture.makeProjectForExtension()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = CheckStateClassifierTests.checkboxPNG(on: true, shift: 0, canvas: 120)
        let driver = SequenceDriver(elements: fixture.screenElements, shots: [before, FindImageTests.screenPNG()])
        let executor = StepExecutor(driver: driver, isAndroid: false)
        executor.visionClassifierProjectRoot = root
        // 遷移前の画面で視覚検証が控えた絵と木(木は今と違う)
        let previousTree = [ElementInfo(ref: 9, type: "button", identifier: "nav_noid", label: nil, value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 0, y: 0, width: 300, height: 50), depth: 1)]
        executor.lastGuardFrameRecord = StaleFrameDetector.judge(png: before, elements: previousTree, previous: nil).record

        let outcome = await findCircle(executor)

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(outcome.imageMatches?.map(\.element.identifier), ["circle"], "追いついた絵で見つける")
        XCTAssertEqual(driver.shotCount, 2, "遷移前の絵では照合しない")
        XCTAssertTrue(outcome.notes.contains(.staleScreenshot))
    }

    /// 待っても絵が追いつかなければ、失敗にせず最新の絵で照合する(古い絵の検知は照合を赤にしない)。
    /// 実測: CMP の iOS in-app で 20 秒以上同じ絵が返り続け、失敗にした版は緑だったシナリオを毎周赤にした
    func testFindImageFallsBackToTheLatestPictureWhenItNeverCatchesUp() async throws {
        let fixture = FindImageTests()
        let root = try fixture.makeProjectForExtension()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = CheckStateClassifierTests.checkboxPNG(on: true, shift: 0, canvas: 120)
        let driver = SequenceDriver(elements: fixture.screenElements, shots: [before])
        let executor = StepExecutor(driver: driver, isAndroid: false)
        executor.visionClassifierProjectRoot = root
        let previousTree = [ElementInfo(ref: 9, type: "button", identifier: "nav_noid", label: nil, value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 0, y: 0, width: 300, height: 50), depth: 1)]
        executor.lastGuardFrameRecord = StaleFrameDetector.judge(png: before, elements: previousTree, previous: nil).record

        let outcome = await findCircle(executor)

        guard case .passed = outcome.status else {
            return XCTFail("古い絵のまま待ちが尽きても失敗にしない: \(outcome.status)")
        }
        XCTAssertTrue(outcome.notes.contains(.staleScreenshot), "待ったことは注記に残す")
        XCTAssertEqual(driver.shotCount, 6, "最初の1回 + 待った4回 + 古い絵の確認を外した最後の1回")
    }

    func testStaleRetryDelaysArePinned() {
        // 実測の最長 5.0 秒(追いついた回)を覆う長さ。値を変えるなら同じ測り方で測り直す
        XCTAssertEqual(FindImage.staleRetryDelays, [0.5, 1, 2, 4])
    }

    /// 控えが無い(前に検証が1度も走っていない)ときは判定しない = 今までどおり照合する
    func testFindImageWithoutAnEarlierPictureJudgesAsBefore() async throws {
        let fixture = FindImageTests()
        let root = try fixture.makeProjectForExtension()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = SequenceDriver(elements: fixture.screenElements, shots: [FindImageTests.screenPNG()])
        let executor = StepExecutor(driver: driver, isAndroid: false)
        executor.visionClassifierProjectRoot = root

        let outcome = await findCircle(executor)

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.shotCount, 1)
        XCTAssertFalse(outcome.notes.contains(.staleScreenshot))
    }

    func testUnjudgeableAndStalePicturesAreWaitedOutLikeAVisionAnomaly() {
        XCTAssertTrue(FindImage.MatchError.blankScreenshot.isTransient)
        XCTAssertTrue(FindImage.MatchError.staleScreenshot.isTransient)
        XCTAssertFalse(FindImage.MatchError.noTemplate(label: "x", directory: "d").isTransient)
    }

    // MARK: - screenLooksLike

    private final class ScreenVerdictDelegate: ReplayDelegate {
        private(set) var calls = 0
        func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? {
            calls += 1
            return (false, "a different screen")
        }
        func verifyElementVisible(expectedText: String, frame: FTRect, screen: FTRect,
                                  screenshotPNG: Data) async
            -> (visible: Bool, state: String, reason: String, observedText: String)? { nil }
    }

    private func screenLooksLike(shots: [Data]) async -> (StepOutcome, ScreenVerdictDelegate) {
        let driver = FakeAppDriver(name: "primary", log: CallLog())
        driver.screenshots = shots
        let delegate = ScreenVerdictDelegate()
        let executor = StepExecutor(driver: driver, delegate: delegate, isAndroid: true)
        let outcome = await executor.execute(FlowStep(assert: "screenMatches", expected: "ホーム画面"))
        return (outcome, delegate)
    }

    /// 黒い絵を FM に渡さない(渡すと必ず「一致しない」)。凍結扱いにもしない(回復は撃たない)
    func testScreenLooksLikeDoesNotJudgeABlackScreenshot() async throws {
        guard FMVisionSupport.isSupported else { throw XCTSkip(FMVisionSupport.requirement) }
        let (outcome, delegate) = await screenLooksLike(shots: [try Self.blackPNG()])
        guard case .skipped(let reason) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(reason.contains("black apart from the system bars"), reason)
        XCTAssertEqual(delegate.calls, 0)
        XCTAssertTrue(outcome.notes.contains(.blankScreenshot))
    }

    /// 撮り直しだけが黒なら 1 枚目の不一致を返す(見送ると本物の不一致を黒い絵で消す)
    func testScreenLooksLikeKeepsTheFirstMismatchWhenOnlyTheRetakeIsBlack() async throws {
        guard FMVisionSupport.isSupported else { throw XCTSkip(FMVisionSupport.requirement) }
        let (outcome, delegate) = await screenLooksLike(shots: [FindImageTests.screenPNG(), try Self.blackPNG()])
        guard case .failed(let reason) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(reason.contains("a different screen"), reason)
        XCTAssertEqual(delegate.calls, 1)
    }
}
