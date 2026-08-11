// Android の凍結も**共有ストアへ公表する**(iOS と同じ口)。
//
// 2026-08-11 のフル E2E で `Pixel 9-02` が guest restart でも戻らず除外されたが、Android の
// トリアージは公表しておらず**モニターの ❄️ には出なかった**。iOS だけ公表する非対称は、
// 「run は知っているのにモニターは知らない」という今回直したはずの欠陥と同じ形。
//
// adb が要る経路は試せないが、**注入(陽性対照)は adb へ触れる前に短絡する**ので、
// 公表の配線だけをデバイス無しで固定できる。注入は `environment:` で渡す
// (setenv はプロセス全体を書き換えるので、並列実行中の他テストへ漏れる)。

import XCTest
@testable import FTAndroid
@testable import FTCore

private struct UnusedDriver: AppDriver {
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
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

final class AndroidFrozenPublicationTests: XCTestCase {
    private var stateDir: URL!
    private let serial = "emulator-59999"

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-android-frozen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func worker() -> RunWorker {
        RunWorker(label: "emu(android:\(serial))", platform: "android", driver: UnusedDriver(),
                  connection: DriverConnection(platform: "android", serial: serial, physical: false),
                  logicalName: "emu")
    }

    /// 注入した機の凍結が**ストアへ公表される**(モニターが読む唯一の口)
    func testInjectedFreezeIsPublished() async {
        let triage = await ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers(
            [worker()], stateDir: stateDir,
            environment: [FrozenInjection.environmentKey: serial], log: { _ in })
        XCTAssertEqual(DeviceFrozenStore.current(stateDir: stateDir, key: serial)?.evidence,
                       [.injected], "Android の凍結が公表されていない(モニターに出ない)")
        XCTAssertTrue(triage.excluded.isEmpty, "注入は実体が健全なので除外しない")
        XCTAssertTrue(triage.repaired.isEmpty, "注入で sleep/wake を撃ってはいけない")
        XCTAssertEqual(triage.workers.count, 1)
    }

    /// `stateDir` を渡さない呼び出しは従来どおり(公表しないだけで壊れない)
    func testWithoutStateDirNothingIsPublished() async {
        let triage = await ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers(
            [worker()], environment: [FrozenInjection.environmentKey: serial], log: { _ in })
        XCTAssertNil(DeviceFrozenStore.current(stateDir: stateDir, key: serial))
        XCTAssertEqual(triage.workers.count, 1)
    }
}
