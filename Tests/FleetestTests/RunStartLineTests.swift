// `RunStartLine.text` は「🚀 Starting with …」行を事実に合わせて組み立てる純粋関数
// (Sources/fleetest/RunStartLine.swift の宣言参照)。実測 2026-09-16: 台数を渡し忘れた2実装が
// それぞれ別の誤りを出していた —— ApiRunCommand は iOS 0 台のプロファイルでも固定文言で
// 「iOS joins once bridge provisioning finishes」と言い、ProfileRunner は Android 0 台の
// プロファイル(iOS だけの run)でも「Starting with 0 Android worker(s)」と Android の行を出した。
// この2本の source-scan は、直したあとに実装が別々の組み立てへ戻らないことを固定する。

import XCTest
@testable import fleetest

final class RunStartLineTests: XCTestCase {

    // MARK: - 4形 + 実測されていた 0 台のエッジケース

    func testAndroidOnly() {
        XCTAssertEqual(
            RunStartLine.text(androidWorkers: 3, eagerIOSWorkers: 0, hasLateIOS: false),
            "🚀 Starting with 3 Android worker(s)")
    }

    /// 実測(9/16): iOS の台が1台も無いプロファイルで「iOS joins…」が固定で出ていた
    func testIOSOnlyEagerNeverMentionsAndroid() {
        XCTAssertEqual(
            RunStartLine.text(androidWorkers: 0, eagerIOSWorkers: 4, hasLateIOS: false),
            "🚀 Starting with 4 iOS worker(s)")
    }

    /// 実測: iOS だけの run(late join・非 performanceMode)で「Starting with 0 Android worker(s)」
    /// と出ていた。Android が0台なら Android の話をしない
    func testIOSOnlyLateJoinNeverMentionsAndroid() {
        XCTAssertEqual(
            RunStartLine.text(androidWorkers: 0, eagerIOSWorkers: 0, hasLateIOS: true),
            "🚀 Starting (iOS joins once bridge provisioning finishes)")
    }

    func testBothEager() {
        XCTAssertEqual(
            RunStartLine.text(androidWorkers: 2, eagerIOSWorkers: 3, hasLateIOS: false),
            "🚀 Starting with 2 Android worker(s) + 3 iOS worker(s)")
    }

    func testBothWithIOSJoiningLater() {
        XCTAssertEqual(
            RunStartLine.text(androidWorkers: 2, eagerIOSWorkers: 0, hasLateIOS: true),
            "🚀 Starting with 2 Android worker(s) (iOS joins once bridge provisioning finishes)")
    }

    func testNeitherPlatformFallsBackWithoutClaimingAPlatform() {
        XCTAssertEqual(
            RunStartLine.text(androidWorkers: 0, eagerIOSWorkers: 0, hasLateIOS: false),
            "🚀 Starting with 0 worker(s)")
    }

    // MARK: - 配線(2実装が同じ関数を呼ぶこと)

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testProfileRunnerCallsTheSharedFunction() throws {
        let text = try source("Sources/fleetest/ProfileRunner.swift")
        XCTAssertTrue(text.contains("RunStartLine.text("),
                      "ProfileRunner が RunStartLine を呼んでいない(別々の組み立てに戻っている)")
    }

    func testApiRunCommandCallsTheSharedFunction() throws {
        let text = try source("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertTrue(text.contains("RunStartLine.text("),
                      "ApiRunCommand が RunStartLine を呼んでいない(別々の組み立てに戻っている)")
        // 供給フェーズの Task 内で早々に固定文言を出す形へ戻っていないこと
        XCTAssertFalse(text.contains("iOS joins once bridge provisioning finishes\")"),
                       "固定文言を直接埋め込んでいる(RunStartLine.text を経由していない)")
    }
}
