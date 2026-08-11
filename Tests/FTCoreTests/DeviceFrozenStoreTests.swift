import XCTest
@testable import FTCore

/// run が公表した凍結をモニターが読む共有ストア。
/// **ホスト共有パスを触らない**ようテストごとに一時ディレクトリを掘る(並列実行で衝突しないため)
final class DeviceFrozenStoreTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-frozen-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    /// 生きている pid(自分自身)。読み手は書き手の生存を条件にする
    private var livePID: Int32 { ProcessInfo.processInfo.processIdentifier }
    /// 確実に存在しない pid。kill(pid, 0) が ESRCH を返す領域を使う
    private let deadPID: Int32 = 2_000_000

    func testPublishThenRead() {
        DeviceFrozenStore.publish(stateDir: stateDir, key: "udid-a",
                                  verdict: FrozenVerdict([.uniformBlank]), pid: livePID)
        XCTAssertEqual(DeviceFrozenStore.current(stateDir: stateDir, key: "udid-a"),
                       FrozenVerdict([.uniformBlank]))
    }

    func testUnknownKeyIsNil() {
        XCTAssertNil(DeviceFrozenStore.current(stateDir: stateDir, key: "udid-missing"))
    }

    /// **健全は「公表」ではなく「削除」**。読み手が2形(健全と書かれた entry / entry 無し)を
    /// 持たなくて済むようにする
    func testPublishingHealthyClearsTheEntry() {
        DeviceFrozenStore.publish(stateDir: stateDir, key: "udid-a",
                                  verdict: FrozenVerdict([.uniformBlank]), pid: livePID)
        DeviceFrozenStore.publish(stateDir: stateDir, key: "udid-a", verdict: .healthy, pid: livePID)
        XCTAssertNil(DeviceFrozenStore.current(stateDir: stateDir, key: "udid-a"))
    }

    func testClearRemovesTheEntry() {
        DeviceFrozenStore.publish(stateDir: stateDir, key: "udid-a",
                                  verdict: FrozenVerdict([.uniformBlank]), pid: livePID)
        DeviceFrozenStore.clear(stateDir: stateDir, key: "udid-a")
        XCTAssertNil(DeviceFrozenStore.current(stateDir: stateDir, key: "udid-a"))
    }

    /// **書き手が死んだら無視する** —— 凍結を公表したまま run が落ちても、
    /// カウンタに残り続けない
    func testEntryFromDeadWriterIsIgnored() {
        DeviceFrozenStore.publish(stateDir: stateDir, key: "udid-a",
                                  verdict: FrozenVerdict([.uniformBlank]), pid: deadPID)
        XCTAssertNil(DeviceFrozenStore.current(stateDir: stateDir, key: "udid-a"))
    }

    /// mtime の backstop(pid 再利用への保険)
    func testStaleEntryIsIgnored() {
        let publishedAt = Date()
        DeviceFrozenStore.publish(stateDir: stateDir, key: "udid-a",
                                  verdict: FrozenVerdict([.uniformBlank]),
                                  pid: livePID, now: publishedAt)
        let justInside = publishedAt.addingTimeInterval(DeviceFrozenStore.stalenessSeconds - 1)
        XCTAssertNotNil(DeviceFrozenStore.current(stateDir: stateDir, key: "udid-a", now: justInside))
        let past = publishedAt.addingTimeInterval(DeviceFrozenStore.stalenessSeconds + 1)
        XCTAssertNil(DeviceFrozenStore.current(stateDir: stateDir, key: "udid-a", now: past))
    }

    /// clearAll は**自分が書いた分だけ**消す(別 run/モニターの公表を巻き込まない)
    func testClearAllRemovesOnlyOwnEntries() {
        DeviceFrozenStore.publish(stateDir: stateDir, key: "mine",
                                  verdict: FrozenVerdict([.uniformBlank]), pid: livePID)
        DeviceFrozenStore.publish(stateDir: stateDir, key: "theirs",
                                  verdict: FrozenVerdict([.uniformBlank]), pid: deadPID)
        DeviceFrozenStore.clearAll(stateDir: stateDir, pid: livePID)
        XCTAssertNil(DeviceFrozenStore.current(stateDir: stateDir, key: "mine"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: DeviceFrozenStore.entryURL(stateDir: stateDir, key: "theirs").path),
            "他プロセスの公表ファイルは残る(読むときに pid 生存で落ちるだけ)")
    }

    /// 根拠は往復しても失われない(モニターがどの根拠で凍結と言っているかを出せる)
    func testEvidenceSurvivesRoundTrip() {
        DeviceFrozenStore.publish(stateDir: stateDir, key: "udid-a",
                                  verdict: FrozenVerdict([.injected, .uniformBlank]), pid: livePID)
        XCTAssertEqual(DeviceFrozenStore.current(stateDir: stateDir, key: "udid-a")?.evidence,
                       [.uniformBlank, .injected])
    }
}
