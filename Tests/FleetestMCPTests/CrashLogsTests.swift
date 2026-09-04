// CrashLogs の iOS 経路(iosText)を dir/now 差し替えで検証する。SimulatorCrashReport.findRecent
// への委譲が正しく効くこと・非対称の注記が本文に必ず出ること・bundleID 欠落を弾くことを確認する。
// Android 経路は adb 実行が要るためここでは対象外(AndroidLogcatTests が filter を検証する)。

import XCTest
@testable import fleetest_mcp

final class CrashLogsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-mcp-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJSONFormatIPS(name: String, bundleID: String, mtime: Date) throws {
        let header = #"{"bundleID":"\#(bundleID)","app_name":"SampleApp"}"#
        let payload = #"{"exception":{"type":"EXC_CRASH","signal":"SIGABRT"}}"#
        let url = dir.appendingPathComponent(name)
        try "\(header)\n\(payload)".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private func writeTextFormatIPS(name: String, bundleID: String, mtime: Date) throws {
        let text = """
        Incident Identifier: 12345
        Identifier:            \(bundleID)
        Exception Type:  EXC_BAD_ACCESS (SIGSEGV)
        Termination Reason: Namespace SIGNAL, Code 11 Segmentation fault
        """
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    // MARK: - 経過時間(古い run のクラッシュを今回のものとして読ませない)

    /// 既定の窓は 300s あり、直前の run のレポートが残っていると掴んでしまう。
    /// **いつのものか**を出さないと、エージェントは今回落ちたと読む(2026-08-09 に実機ならぬ
    /// シミュレータで実際に踏んだ: 11 分前のレポートを今回の結果として返した)
    func testFoundCrashReportsHowLongAgoItWas() throws {
        let now = Date()
        try writeJSONFormatIPS(name: "recent.ips", bundleID: "com.example.app",
                               mtime: now.addingTimeInterval(-20))
        let text = CrashLogs.iosText(bundleID: "com.example.app", withinSeconds: 300,
                                     dir: dir, now: now)
        XCTAssertTrue(text.contains("20s ago"), text)
    }

    /// 1 分以上前なら「前の run のものではないか」と名指しで疑わせる
    func testOldCrashWarnsItMayBeFromAnEarlierRun() throws {
        let now = Date()
        try writeJSONFormatIPS(name: "old.ips", bundleID: "com.example.app",
                               mtime: now.addingTimeInterval(-185))
        let text = CrashLogs.iosText(bundleID: "com.example.app", withinSeconds: 300,
                                     dir: dir, now: now)
        XCTAssertTrue(text.contains("3m 5s ago"), text)
        XCTAssertTrue(text.contains("earlier run"), text)
    }

    /// 見つからなかったときは、待ったこと自体を本文に出す(待たずに諦めたのか、
    /// 待っても無かったのかが読み手に分かる)
    func testAbsenceMentionsTheWaitWhenOneHappened() {
        let text = CrashLogs.iosText(bundleID: "com.example.app", withinSeconds: 120,
                                     dir: dir, now: Date(), waitedSeconds: 4.2)
        XCTAssertTrue(text.contains("4.2s"), text)
    }

    // MARK: - bundleID 必須

    func testMissingBundleIDReturnsGuidance() {
        let text = CrashLogs.iosText(bundleID: nil, withinSeconds: 120, dir: dir, now: Date())
        XCTAssertTrue(text.contains("bundleID"), text)
    }

    func testEmptyBundleIDReturnsGuidance() {
        let text = CrashLogs.iosText(bundleID: "", withinSeconds: 120, dir: dir, now: Date())
        XCTAssertTrue(text.contains("bundleID"), text)
    }

    // MARK: - 一致するクラッシュあり(新 JSON 形式)

    func testFoundCrashJSONFormatReportsReasonAndPath() throws {
        let now = Date()
        try writeJSONFormatIPS(name: "a.ips", bundleID: "com.example.app", mtime: now)

        let text = CrashLogs.iosText(bundleID: "com.example.app", withinSeconds: 120, dir: dir, now: now)

        XCTAssertTrue(text.contains("EXC_CRASH"), text)
        XCTAssertTrue(text.contains("SIGABRT"), text)
        XCTAssertTrue(text.contains("a.ips"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("crash found"), text)
    }

    // MARK: - 一致するクラッシュあり(旧テキスト形式)

    func testFoundCrashTextFormatReportsReasonAndPath() throws {
        let now = Date()
        try writeTextFormatIPS(name: "b.ips", bundleID: "com.example.app", mtime: now)

        let text = CrashLogs.iosText(bundleID: "com.example.app", withinSeconds: 120, dir: dir, now: now)

        XCTAssertTrue(text.contains("EXC_BAD_ACCESS"), text)
        XCTAssertTrue(text.contains("b.ips"), text)
    }

    // MARK: - 一致するクラッシュなし(欠陥検知は両方向に掛ける)

    /// 「見つけたのに見つからなかったと言う」変異を検出する陽性側
    func testNoCrashPresentReturnsExplicitAbsence() {
        let now = Date()
        let text = CrashLogs.iosText(bundleID: "com.example.app", withinSeconds: 120, dir: dir, now: now)

        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("no crash"), text)
        // 件数ゼロを暗黙の空文字で返す(黙る)実装への回帰を防ぐ
        XCTAssertNotEqual(text, "")
    }

    /// 別 bundleID のクラッシュは無関係(「常に見つけたことにする」変異を検出する陰性側)
    func testCrashForDifferentBundleIDIsNotReported() throws {
        let now = Date()
        try writeJSONFormatIPS(name: "other.ips", bundleID: "com.other.app", mtime: now)

        let text = CrashLogs.iosText(bundleID: "com.example.app", withinSeconds: 120, dir: dir, now: now)

        XCTAssertTrue(text.localizedCaseInsensitiveContains("no crash"), text)
        XCTAssertFalse(text.contains("other.ips"), text)
    }

    /// window 外のクラッシュは無視される(SimulatorCrashReport.findRecent の within が効くこと)
    func testCrashOutsideWindowIsNotReported() throws {
        let now = Date()
        try writeJSONFormatIPS(name: "old.ips", bundleID: "com.example.app",
                               mtime: now.addingTimeInterval(-600))

        let text = CrashLogs.iosText(bundleID: "com.example.app", withinSeconds: 120, dir: dir, now: now)

        XCTAssertTrue(text.localizedCaseInsensitiveContains("no crash"), text)
    }

    // MARK: - iOS/Android 非対称の明示

    /// 決定済み仕様: iOS は os_log の tail を出さない。見つかっても見つからなくても、
    /// その非対称がエージェントに伝わる一文が本文に必ず含まれること
    func testAsymmetryNoteIsAlwaysPresentWhenNoCrash() {
        let text = CrashLogs.iosText(bundleID: "com.example.app", withinSeconds: 120, dir: dir, now: Date())
        XCTAssertTrue(text.contains("Android"), text)
    }

    func testAsymmetryNoteIsAlwaysPresentWhenCrashFound() throws {
        let now = Date()
        try writeJSONFormatIPS(name: "a.ips", bundleID: "com.example.app", mtime: now)

        let text = CrashLogs.iosText(bundleID: "com.example.app", withinSeconds: 120, dir: dir, now: now)

        XCTAssertTrue(text.contains("Android"), text)
    }

    // MARK: - platform 分岐(text() の非 iOS/Android 経路)

    func testUnknownPlatformIsRejectedWithoutThrowing() async {
        let text = await CrashLogs.text(platform: "windows", bundleID: nil, serial: nil,
                                        withinSeconds: 60, maxLines: 100, crashOnly: true,
                                        physicalUDID: nil)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("unknown"), text)
    }

    /// text() の iOS 分岐が iosText へちゃんと委譲していること(既定の dir/now ではなく
    /// テスト用に差し替えられないため、bundleID 欠落のガード文言だけで委譲を確認する)
    func testTextDelegatesToIOSPathForIOSPlatform() async {
        let text = await CrashLogs.text(platform: "ios", bundleID: nil, serial: nil,
                                        withinSeconds: 60, maxLines: 100, crashOnly: true,
                                        physicalUDID: nil)
        XCTAssertTrue(text.contains("bundleID"), text)
    }

    // MARK: - 実機宛て(件3: 待っても永遠に見つからない)

    /// **実機だと分かっているときは iOS の待ち(reportPollAttempts × reportPollIntervalNanos ≒
    /// 4.2 秒)を一切払わない**。待ったかどうかは "Waited" の有無で判定できる(iosText の
    /// waitedSeconds 注記と同じ語)—— 待っていれば必ず付き、実機経路では絶対に付かない
    func testPhysicalDeviceSkipsTheSimulatorPollingWait() async {
        let text = await CrashLogs.text(platform: "ios", bundleID: "com.example.app", serial: nil,
                                        withinSeconds: 60, maxLines: 100, crashOnly: true,
                                        physicalUDID: "00008130-001819863E60001C")
        XCTAssertFalse(text.contains("Waited"), text)
    }

    /// 実機宛ての本文は udid を名指しし、取り出し方(Xcode の Devices and Simulators / devicectl)
    /// まで言う。黙ると「ではどうやって取るのか」で行き止まる
    func testPhysicalDeviceTextNamesTheUDIDAndTheRetrievalPath() {
        let text = CrashLogs.physicalDeviceText(bundleID: "com.example.app",
                                                udid: "00008130-001819863E60001C")
        XCTAssertTrue(text.contains("00008130-001819863E60001C"), text)
        XCTAssertTrue(text.contains("com.example.app"), text)
        XCTAssertTrue(text.contains("Devices and Simulators"), text)
        XCTAssertTrue(text.contains("devicectl"), text)
        // iOS/Android 非対称は実機経路でも言う(iosText と同じ一文を共有)
        XCTAssertTrue(text.contains("Android"), text)
    }

    /// bundleID 省略でも(scope が無いだけで)落ちない
    func testPhysicalDeviceTextToleratesMissingBundleID() {
        let text = CrashLogs.physicalDeviceText(bundleID: nil, udid: "00008130-001819863E60001C")
        XCTAssertTrue(text.contains("00008130-001819863E60001C"), text)
    }

    /// physicalUDID が nil なら**従来どおりシミュレータの経路**(常に実機扱いへ倒れていないことの
    /// 回帰ガード)。bundleID も省いて即 return させ、4.2 秒のポーリング待ちを払わずに確認する
    func testNilPhysicalUDIDStaysOnTheSimulatorPath() async {
        let text = await CrashLogs.text(platform: "ios", bundleID: nil, serial: nil,
                                        withinSeconds: 60, maxLines: 100, crashOnly: true,
                                        physicalUDID: nil)
        XCTAssertFalse(text.contains("Devices and Simulators"), text)
        XCTAssertTrue(text.contains("bundleID"), text)
    }
}
