import XCTest
@testable import FTDSL
import FTCore

/// `String.range(of:options:.regularExpression)` は不正なパターンで throw せず nil を返すだけなので、
/// 否定形(`thisMatchesNot`/`textMatchesNot`/`valueMatchesNot`)は閉じ忘れの括弧1つで
/// **永久に緑**になる(RegexValidation 参照)。ここでは実行前(dry-run 含む)に落ちることを固定する
final class RegexAssertionValidationTests: XCTestCase {

    private final class StubDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func makeCore(dryRun: Bool) -> FTDriveCore {
        FTDriveCore(driver: StubDriver(), platform: "ios", app: "com.example.app",
                   scenarioID: "T.S0010", scenarioTitle: "t",
                   delegate: nil, healingEnabled: false, dryRun: dryRun,
                   healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                       .appendingPathComponent("ft-regex-validation-\(UUID().uuidString).json"),
                   emit: { _ in })
    }

    private func run(dryRun: Bool = false, _ body: @escaping () -> Void) -> [DSLStepRecord] {
        let core = makeCore(dryRun: dryRun)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { body() } } }
        return core.finalRecord.scenes.flatMap(\.steps)
    }

    private func isFailed(_ step: DSLStepRecord) -> Bool {
        if case .failed = step.status { return true }
        return false
    }

    // MARK: - thisMatches / thisMatchesNot(ValueAssertions.swift)

    func testThisMatchesNotFailsOnInvalidPattern() {
        let steps = run { "abc".thisMatchesNot("[") }
        XCTAssertEqual(steps.count, 1)
        XCTAssertTrue(isFailed(steps[0]), "\(steps[0].status)")
    }

    func testThisMatchesFailsOnInvalidPattern() {
        let steps = run { "abc".thisMatches("[") }
        XCTAssertEqual(steps.count, 1)
        XCTAssertTrue(isFailed(steps[0]), "\(steps[0].status)")
    }

    func testThisMatchesPassesOnValidPattern() {
        let steps = run { "abc".thisMatches("^a") }
        XCTAssertEqual(steps.count, 1)
        XCTAssertFalse(isFailed(steps[0]), "\(steps[0].status)")
    }

    // MARK: - textMatches* / valueMatches*(CommandsVerify.swift、dry-run でも落ちること)

    func testSelectTextMatchesNotFailsOnInvalidPatternInDryRun() {
        let steps = run(dryRun: true) { select("#x").textMatchesNot("(") }
        XCTAssertTrue(steps.contains { isFailed($0) },
                      "不正な正規表現が dry-run で素通りした: \(steps.map(\.status))")
    }

    func testSelectTextMatchesFailsOnInvalidPatternInDryRun() {
        let steps = run(dryRun: true) { select("#x").textMatches("(") }
        XCTAssertTrue(steps.contains { isFailed($0) },
                      "不正な正規表現が dry-run で素通りした: \(steps.map(\.status))")
    }

    func testSelectValueMatchesNotFailsOnInvalidPatternInDryRun() {
        let steps = run(dryRun: true) { select("#x").valueMatchesNot("(") }
        XCTAssertTrue(steps.contains { isFailed($0) },
                      "不正な正規表現が dry-run で素通りした: \(steps.map(\.status))")
    }

    func testSelectValueMatchesFailsOnInvalidPatternInDryRun() {
        let steps = run(dryRun: true) { select("#x").valueMatches("(") }
        XCTAssertTrue(steps.contains { isFailed($0) },
                      "不正な正規表現が dry-run で素通りした: \(steps.map(\.status))")
    }

    func testSelectTextMatchesPassesOnValidPatternInDryRun() {
        let steps = run(dryRun: true) { select("#x").textMatches("^a") }
        XCTAssertFalse(steps.contains { isFailed($0) },
                       "正当な正規表現を dry-run で誤って落とした: \(steps.map(\.status))")
    }
}
