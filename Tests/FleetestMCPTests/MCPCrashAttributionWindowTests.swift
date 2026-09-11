// クラッシュ時の注記の2つの契約:
// ①案内する引数は ft_logs のスキーマに実在するもの(`all`。既定 false = crash バッファのみなので
//   無指定の ft_logs がそのまま該当部分を出す)。存在しない `crashOnly` を案内しない
// ②引用するのは直近の launch 以降のクラッシュだけ(`adb logcat -d -b crash` は時間で絞らないと
//   数時間前の別プロセスのクラッシュまで残るバッファを丸ごと読む)

import XCTest
import FTAndroid
import FTCore
@testable import fleetest_mcp

final class MCPCrashAttributionWindowTests: XCTestCase {

    private func element(_ ref: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: nil, label: nil, value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10),
                    depth: 1)
    }

    private func snapshot(bundleID: String) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: bundleID, screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                         elements: [element(1)], truncatedCount: 0)
    }

    // MARK: - ① 文言(実在しない引数を案内しない)

    func testCrashNoteRecommendsFtLogsWithoutAFictionalArgument() {
        let evidence = AndroidAppProcessEvidence(
            running: false, crashSummary: ["FATAL EXCEPTION: main", "Process: com.example.app, PID: 123",
                                           "java.lang.RuntimeException: boom"])
        let note = MCPServer.switchedAppNote(
            launched: "com.example.app", snapshot: snapshot(bundleID: "com.android.launcher"),
            processEvidence: evidence)
        XCTAssertTrue(note.contains("ft_logs shows the full trace."), note)
        XCTAssertFalse(note.contains("crashOnly"), "存在しない引数を案内している: \(note)")
    }

    /// 陰性対照: クラッシュ痕跡が無いときは crash 行の案内そのものを出さない
    func testNoCrashSummaryMeansNoLogsRecommendation() {
        let evidence = AndroidAppProcessEvidence(running: false, crashSummary: [])
        let note = MCPServer.switchedAppNote(
            launched: "com.example.app", snapshot: snapshot(bundleID: "com.android.launcher"),
            processEvidence: evidence)
        XCTAssertFalse(note.contains("ft_logs"), note)
        XCTAssertTrue(note.contains("may have crashed"), note)
    }

    // MARK: - ② 遡り窓(直近の launch 以降に絞る)

    /// launch 時刻が分かっていれば、経過秒数+5秒の余裕だけを遡る(無制限に戻らない)
    func testWindowIsElapsedSinceLaunchPlusFiveSecondsOfGrace() {
        let launchedAt = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_042)
        XCTAssertEqual(MCPServer.crashAttributionWindowSeconds(launchedAt: launchedAt, now: now), 47)
    }

    /// launch 時刻を知らない(このセッションが ft_launch していない)ときは ft_logs の既定(300s)
    /// に倒す —— **無制限には戻さない**。これが元の欠陥(数時間前のクラッシュを引用)そのもの
    func testWindowFallsBackToTheFtLogsDefaultWhenLaunchTimeIsUnknown() {
        XCTAssertEqual(MCPServer.crashAttributionWindowSeconds(launchedAt: nil, now: Date()), 300)
    }

    /// 経過が負(時計のずれ・launch がまだ記録されていない世代)でも下限5秒を割らない
    func testWindowHasAFloorOfFiveSeconds() {
        let launchedAt = Date(timeIntervalSince1970: 2_000)
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(MCPServer.crashAttributionWindowSeconds(launchedAt: launchedAt, now: now), 5)
    }

    // MARK: - 配線: ft_launch が launchTimestamps を刻み、forgetDeviceState が捨てる

    func testFtLaunchRecordsATimestampAndForgetDeviceStateDropsIt() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver },
                               recordSnapshot: { _, _, _ in })
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        let key = MCPServer.engineKey([:])
        XCTAssertNotNil(server.launchTimestamps[key], "ft_launch が launchTimestamps を刻んでいない")

        server.forgetDeviceState(key)
        XCTAssertNil(server.launchTimestamps[key], "forgetDeviceState が launchTimestamps を捨てていない")
    }
}
