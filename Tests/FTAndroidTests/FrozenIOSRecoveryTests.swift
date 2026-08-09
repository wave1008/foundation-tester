// 凍結シミュレータ回復(ProfileWorkerFactory.recoverFrozenIOSWorkers)の**選別と合流**。
//
// 本体は simctl を撃つので単体では通せない。分岐だけを純粋関数へ切り出してあり、
// ここが守るのは2つ:
// - **Android を巻き込まない**(呼び出し元の一覧は混在しうる。ApiRunCommand の直接供給)
// - **回復後に Android のレーンを消さない**(buildIOSWorkers は iOS しか作らない)

import XCTest
import FTBridgeClient
import FTCore
@testable import FTAndroid

final class FrozenIOSRecoveryTests: XCTestCase {

    private final class NullDriver: AppDriver, @unchecked Sendable {
        func screenshot() async throws -> Data { Data() }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func terminate() async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                   path: FTSwipePath?) async throws {}
    }

    private func ios(_ label: String, udid: String? = nil) -> RunWorker {
        RunWorker(label: label, platform: "ios", driver: NullDriver(),
                  connection: DriverConnection(platform: "ios", port: 8123, serial: nil,
                                               udid: udid ?? "UDID-\(label)"))
    }

    private func android(_ label: String) -> RunWorker {
        RunWorker(label: label, platform: "android", driver: NullDriver(),
                  connection: DriverConnection(platform: "android", port: 8200,
                                               serial: "emulator-\(label)", udid: nil))
    }

    // MARK: - 対象の選別

    func testOnlyTheNamedIOSWorkersAreRebooted() {
        let workers = [ios("a"), ios("b"), android("c")]
        let targets = ProfileWorkerFactory.frozenIOSTargets(labels: ["a"], workers: workers)
        XCTAssertEqual(targets.map(\.label), ["a"])
        XCTAssertEqual(targets.map(\.udid), ["UDID-a"])
    }

    /// **Android は simctl の対象にしない**(修復は別経路が済ませている)。
    /// **udid を持たせて確かめる** —— udid nil の Android で試すと platform の判定を消しても
    /// compactMap が落として素通しする(2026-08-09 の変異テストで実際に素通しした)
    func testAndroidIsNeverRebootedEvenWhenItCarriesAUDID() {
        let androidWithUDID = RunWorker(
            label: "c", platform: "android", driver: NullDriver(),
            connection: DriverConnection(platform: "android", port: 8200,
                                         serial: "emulator-c", udid: "UDID-c"))
        let targets = ProfileWorkerFactory.frozenIOSTargets(
            labels: ["c"], workers: [ios("a"), androidWithUDID])
        XCTAssertTrue(targets.isEmpty,
                      "Android を simctl で再起動しようとしている: \(targets.map(\.label))")
    }

    /// udid が無ければ撃てない(label は表示用で simctl には渡せない)
    func testIOSWorkerWithoutUDIDIsNotATarget() {
        let noUDID = RunWorker(label: "x", platform: "ios", driver: NullDriver(),
                               connection: DriverConnection(platform: "ios", port: 8123,
                                                            serial: nil, udid: nil))
        XCTAssertTrue(ProfileWorkerFactory.frozenIOSTargets(labels: ["x"], workers: [noUDID]).isEmpty)
    }

    // MARK: - 合流

    /// 張り直した iOS を入れつつ **Android はそのまま残す**
    func testMergeKeepsAndroidLanesAndReplacesIOS() {
        let original = [ios("a"), android("c"), ios("b")]
        let merged = ProfileWorkerFactory.mergeRecoveredIOS(into: original,
                                                            rebuiltIOS: [ios("a"), ios("b")])
        XCTAssertEqual(Set(merged.map(\.label)), ["a", "b", "c"])
        XCTAssertEqual(merged.filter { $0.platform == "android" }.map(\.label), ["c"],
                       "Android のレーンが消えている")
        XCTAssertEqual(merged.filter { $0.platform == "ios" }.count, 2,
                       "iOS が二重に入っている(古い凍結ワーカーが残る)")
    }

    /// 回復で iOS が1台も戻らなくても Android は走る
    func testMergeWithNoRebuiltIOSStillKeepsAndroid() {
        let merged = ProfileWorkerFactory.mergeRecoveredIOS(into: [ios("a"), android("c")],
                                                            rebuiltIOS: [])
        XCTAssertEqual(merged.map(\.label), ["c"])
    }
}
