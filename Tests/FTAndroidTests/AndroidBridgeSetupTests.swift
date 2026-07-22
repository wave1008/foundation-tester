import XCTest
import FTBridgeClient
@testable import FTAndroid

/// AndroidDriver.beginSetup の集約(同一 serial の並行初回操作を1本の startBridge にまとめる)を検証。
/// beginSetup は同期関数で、進行中タスクの登録も同期区間で行うため、body の非同期完了前に
/// N 回呼べば確実に1本へ集約される(adb forward / am instrument の二重実行を防ぐ)。
final class AndroidBridgeSetupTests: XCTestCase {

    private actor Counter {
        private(set) var value = 0
        func inc() { value += 1 }
    }

    func testCoalescesConcurrentSameKey() async throws {
        let counter = Counter()
        var tasks: [Task<BridgeClient, Error>] = []
        for _ in 0..<8 {
            tasks.append(AndroidDriver.beginSetup(key: "serial-A") {
                await counter.inc()
                try await Task.sleep(nanoseconds: 300_000_000)   // 全 begin 呼び出しが揃うまで body を保持
                return BridgeClient(port: 1)
            })
        }
        for t in tasks { _ = try await t.value }
        let n = await counter.value
        XCTAssertEqual(n, 1, "同一 key の並行 setup は1回に集約されるはず(実行 \(n) 回)")
    }

    func testDistinctKeysRunSeparately() async throws {
        let counter = Counter()
        let a = AndroidDriver.beginSetup(key: "A") {
            await counter.inc(); try await Task.sleep(nanoseconds: 100_000_000); return BridgeClient(port: 1)
        }
        let b = AndroidDriver.beginSetup(key: "B") {
            await counter.inc(); try await Task.sleep(nanoseconds: 100_000_000); return BridgeClient(port: 2)
        }
        _ = try await a.value
        _ = try await b.value
        let n = await counter.value
        XCTAssertEqual(n, 2, "異なる key は別々に実行される")
    }

    /// 完了後は登録解除され、次の setup は新規に走る(集約が永続化して再セットアップを妨げない)。
    func testSetupClearedAfterCompletion() async throws {
        let counter = Counter()
        _ = try await AndroidDriver.beginSetup(key: "serial-C") {
            await counter.inc(); return BridgeClient(port: 1)
        }.value
        _ = try await AndroidDriver.beginSetup(key: "serial-C") {
            await counter.inc(); return BridgeClient(port: 1)
        }.value
        let n = await counter.value
        XCTAssertEqual(n, 2, "完了後の再 setup は新規に走るはず")
    }
}
