// AndroidAppProcessEvidenceQuery.crashSummary の純粋ロジック(adb は叩かない)。
// 入力は実機(Pixel 4a・2026-09-05)で #btn_crash_confirm から実測した crash バッファ。

import XCTest
@testable import FTAndroid

final class AndroidAppProcessEvidenceTests: XCTestCase {

    private let package = "com.ftester.e2e.android"

    private let sample = """
        09-05 12:15:16.160 13561 13561 E AndroidRuntime: FATAL EXCEPTION: main
        09-05 12:15:16.160 13561 13561 E AndroidRuntime: Process: com.ftester.e2e.android, PID: 13561
        09-05 12:15:16.160 13561 13561 E AndroidRuntime: java.lang.RuntimeException: FT_E2E intentional crash
        09-05 12:15:16.160 13561 13561 E AndroidRuntime: \tat com.ftester.e2e.android.Screens2Kt.buildDiagnosticsScreen$lambda$1$1(Screens2.kt:323)
        """

    private let sampleWithOtherPackageCrashBefore = """
        09-05 12:15:10.000 27295 27295 E AndroidRuntime: FATAL EXCEPTION: main
        09-05 12:15:10.000 27295 27295 E AndroidRuntime: Process: com.ftester.bridge, PID: 27295
        09-05 12:15:10.000 27295 27295 E AndroidRuntime: java.lang.IllegalStateException: UiAutomationService ... already registered!
        09-05 12:15:16.160 13561 13561 E AndroidRuntime: FATAL EXCEPTION: main
        09-05 12:15:16.160 13561 13561 E AndroidRuntime: Process: com.ftester.e2e.android, PID: 13561
        09-05 12:15:16.160 13561 13561 E AndroidRuntime: java.lang.RuntimeException: FT_E2E intentional crash
        """

    func testCrashSummaryExtractsFirstThreeLinesOfTheMatchingBlock() {
        let summary = AndroidAppProcessEvidenceQuery.crashSummary(fromCrashLog: sample, package: package)
        XCTAssertEqual(summary, [
            "FATAL EXCEPTION: main",
            "Process: com.ftester.e2e.android, PID: 13561",
            "java.lang.RuntimeException: FT_E2E intentional crash",
        ])
    }

    /// 別 package(instrumentation ランナー自身)のブロックが前方にあっても無視する
    func testCrashSummaryIgnoresBlocksFromOtherPackages() {
        let summary = AndroidAppProcessEvidenceQuery.crashSummary(
            fromCrashLog: sampleWithOtherPackageCrashBefore, package: package)
        XCTAssertEqual(summary, [
            "FATAL EXCEPTION: main",
            "Process: com.ftester.e2e.android, PID: 13561",
            "java.lang.RuntimeException: FT_E2E intentional crash",
        ])
        XCTAssertFalse(summary.contains { $0.contains("com.ftester.bridge") })
    }

    /// このpackage のブロックが1つも無ければ空(誤って別 package の話を返さない)
    func testCrashSummaryReturnsEmptyWhenPackageNeverAppears() {
        let summary = AndroidAppProcessEvidenceQuery.crashSummary(
            fromCrashLog: sampleWithOtherPackageCrashBefore, package: "com.nonexistent.app")
        XCTAssertEqual(summary, [])
    }

    func testCrashSummaryOnEmptyLogReturnsEmpty() {
        XCTAssertEqual(AndroidAppProcessEvidenceQuery.crashSummary(fromCrashLog: "", package: package), [])
    }

    /// FATAL EXCEPTION は在るが Process: 行がこの package でない(絞り込みが効いていること)
    func testCrashSummaryReturnsEmptyWhenNoBlockMatchesPackage() {
        let summary = AndroidAppProcessEvidenceQuery.crashSummary(fromCrashLog: sample,
                                                                   package: "com.other.app")
        XCTAssertEqual(summary, [])
    }
}
