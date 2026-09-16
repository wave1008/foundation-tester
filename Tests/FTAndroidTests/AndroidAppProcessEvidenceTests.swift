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

    // MARK: - processAbsence(status:output:) — adb 自体の失敗と「本当に居ない」を区別する
    // (2026-09-16 の負荷テストで M1Ultra のエミュレータで実際に踏んだ: 一瞬の adb 断
    // 「adb: device offline」を「プロセスが居ない(クラッシュの疑い)」と誤記録した。
    // logcat ではアプリもブリッジも生きていた)

    /// adb 自体が失敗した出力(3系統のうちの1つ)は **nil**(判定できない)——
    /// これが (1) の直接の回帰ゲート
    func testProcessAbsenceIsNilWhenADBItselfFails() {
        let adbFailures = [
            "adb: device offline",
            "error: device 'emulator-5554' not found",
            "error: no devices/emulators found",
            "error: device unauthorized",
        ]
        for output in adbFailures {
            XCTAssertNil(AndroidAppProcessEvidenceQuery.processAbsence(status: 1, output: output),
                        "adb 自体の失敗を「判定できる」と読んだ: \(output)")
        }
    }

    /// pidof が空を返した(2系統目)= 本当に居ない → true
    func testProcessAbsenceIsTrueWhenPidofReturnsNothing() {
        XCTAssertEqual(AndroidAppProcessEvidenceQuery.processAbsence(status: 1, output: ""), true)
        XCTAssertEqual(AndroidAppProcessEvidenceQuery.processAbsence(status: 1, output: "\n"), true)
    }

    /// pidof が pid を返した(3系統目)= 居る → false
    func testProcessAbsenceIsFalseWhenPidofReturnsAPid() {
        XCTAssertEqual(AndroidAppProcessEvidenceQuery.processAbsence(status: 0, output: "13561\n"), false)
        XCTAssertEqual(AndroidAppProcessEvidenceQuery.processAbsence(status: 0, output: "13561 13562\n"),
                       false)
    }

    /// **nil のとき呼び出し元が何も書かない**ことも固定する。実際の配線は
    /// `Sources/FTScenarioRunner/ScenarioRunnerMain.swift` の `core.appProcessEvidence` クロージャ
    /// (`guard let evidence = AndroidAppProcessEvidenceQuery.query(...), !evidence.running else
    /// { return [] }`)。ここではその guard パターンだけを模して、`query` が nil を返す回
    /// (= adb 自体の失敗)に何も出ないことを確かめる
    func testCallerProducesNoEvidenceStringsWhenQueryReturnsNil() {
        func evidenceStrings(_ evidence: AndroidAppProcessEvidence?) -> [String] {
            guard let evidence, !evidence.running else { return [] }
            return ["process not running"] + evidence.crashSummary
        }
        XCTAssertEqual(evidenceStrings(nil), [],
                       "query が nil(adb 自体の失敗)を返したのに何か書いてしまった")
        XCTAssertEqual(evidenceStrings(AndroidAppProcessEvidence(running: true, crashSummary: [])), [])
        XCTAssertEqual(
            evidenceStrings(AndroidAppProcessEvidence(running: false, crashSummary: ["reason"])),
            ["process not running", "reason"])
    }
}
