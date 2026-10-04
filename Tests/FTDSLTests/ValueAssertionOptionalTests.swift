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
                               delegate: nil, healingEnabled: false, tunables: RunTunables(), dryRun: false,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
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

    /// 素の値(FTValue)でも `strict:` が書けて効く(索引・docs が案内する形)。既定は正規化して比べ、
    /// strict: true はゼロ幅の文字も違いとして見る
    func testPlainStringThisIsHonoursStrict() {
        let value = "ab\u{200B}c"
        let normalized = run { value.thisIs("abc") }
        XCTAssertFalse(isFailed(normalized[0]), "既定は正規化して一致: \(normalized[0].status)")
        let strict = run { value.thisIs("abc", strict: true) }
        XCTAssertTrue(isFailed(strict[0]), "strict は正規化しない: \(strict[0].status)")
        let strictNot = run { value.thisIsNot("abc", strict: true) }
        XCTAssertFalse(isFailed(strictNot[0]), "strict の否定形も同じ規則: \(strictNot[0].status)")
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

    /// 数値比較は境界で向きが割れる(> と >= / < と <=)。数値に読めない値は失敗(緑に倒さない)。
    /// **1件ずつ別の run で見る** —— 失敗はシナリオを打ち切るので、同じ run に並べると2件目以降が飛ばされて「通った」に見える
    func testNumericComparisonsAtTheBoundary() {
        let five: Int = 5
        let checks: [(String, () -> Void, Bool)] = [
            ("5 > 4", { five.thisIsGreaterThan(4) }, false),
            ("5 > 5", { five.thisIsGreaterThan(5) }, true),
            ("5 >= 5", { five.thisIsGreaterThanOrEqual(5) }, false),
            ("5 < 6", { five.thisIsLessThan(6) }, false),
            ("5 < 5", { five.thisIsLessThan(5) }, true),
            ("5 <= 5", { five.thisIsLessThanOrEqual(5) }, false),
            ("\"abc\" > 1", { "abc".thisIsGreaterThan(1) }, true),
        ]
        for (name, body, shouldFail) in checks {
            let steps = run(body)
            XCTAssertEqual(steps.count, 1, name)
            XCTAssertEqual(isFailed(steps[0]), shouldFail, "\(name): \(steps[0].status)")
        }
    }

    /// blank は空白・改行だけでも空とみなす(empty とは違う)。nil も blank
    func testBlankTreatsWhitespaceAsEmpty() {
        let spaces = " \n\t"
        let none: String? = nil
        let checks: [(String, () -> Void, Bool)] = [
            ("spaces blank", { spaces.thisIsBlank() }, false),
            ("spaces empty", { spaces.thisIsEmpty() }, true),
            ("nil blank", { none.thisIsBlank() }, false),
            ("a blank", { "a".thisIsBlank() }, true),
            ("a not blank", { "a".thisIsNotBlank() }, false),
            ("spaces not blank", { spaces.thisIsNotBlank() }, true),
        ]
        for (name, body, shouldFail) in checks {
            let steps = run(body)
            XCTAssertEqual(steps.count, 1, name)
            XCTAssertEqual(isFailed(steps[0]), shouldFail, "\(name): \(steps[0].status)")
        }
    }
}
