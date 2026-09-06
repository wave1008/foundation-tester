import XCTest
@testable import FTDSL
import FTCore

/// `String?` 等の nil は **nil として**判定される(文字列 "nil" ではない)。
/// ジェネリック経由で `Optional<Any>.some(.none)` に包まれると `thisIsNotEmpty()` が緑になる
final class ValueAssertionOptionalTests: XCTestCase {

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

    private func run(_ body: @escaping () -> Void) -> [DSLStepRecord] {
        let core = FTDriveCore(driver: StubDriver(), platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, dryRun: false,
                               healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-value-optional-\(UUID().uuidString).json"),
                               emit: { _ in })
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { body() } } }
        return core.finalRecord.scenes.flatMap(\.steps)
    }

    private func isFailed(_ step: DSLStepRecord) -> Bool {
        if case .failed = step.status { return true }
        return false
    }

    func testNilOptionalStringIsNotANonEmptyString() {
        let none: String? = nil
        let steps = run { none.thisIsNotEmpty() }
        XCTAssertEqual(steps.count, 1)
        XCTAssertTrue(isFailed(steps[0]), "\(steps[0].status)")
    }

    func testNilOptionalDoesNotContainTheLettersOfTheWordNil() {
        let none: String? = nil
        let steps = run { none.thisContains("ni") }
        XCTAssertTrue(isFailed(steps[0]), "\(steps[0].status)")
    }

    func testNilOptionalIsEmptyAndEqualsNil() {
        let none: String? = nil
        let count: Int? = nil
        let steps = run {
            none.thisIsEmpty()
            none.thisIs(nil)
            count.thisIs(nil)
        }
        XCTAssertEqual(steps.count, 3)
        XCTAssertFalse(steps.contains(where: isFailed), "\(steps.map(\.status))")
    }

    func testSomeOptionalIsJudgedByItsWrappedValue() {
        let some: String? = "abc"
        let number: Int? = 30
        let steps = run {
            some.thisIs("abc")
            some.thisIsNotEmpty()
            number.thisIs(30)
        }
        XCTAssertFalse(steps.contains(where: isFailed), "\(steps.map(\.status))")
    }
}
