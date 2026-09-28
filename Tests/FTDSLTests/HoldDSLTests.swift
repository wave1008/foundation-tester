// hold("...") { } の DSL 写像。FTCore の単体(HoldStepTests.swift)は FlowStep を直接作るので、
// DSL 側の渡し忘れ・反転(ブロックを走らせる/走らせないタイミング)は通ってしまう —— ここで固定する。

import XCTest
@testable import FTCore
@testable import FTDSL

final class HoldDSLTests: XCTestCase {

    private final class HoldDriver: AppDriver {
        /// element が nil なら snapshot は空(= 対象が見つからない状況を模す)
        let element: ElementInfo?
        /// 呼ばれた順に積む(hold が送られたことと、ブロックが走ったことの前後関係を見るため)
        private(set) var log: [String] = []
        init(element: ElementInfo?) { self.element = element }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 300, height: 100),
                             elements: element.map { [$0] } ?? [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func hold(x: Double, y: Double, duration: Double) async throws {
            log.append("holdSent")
        }
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}

        func recordBlockRan() { log.append("blockRan") }
        var recordedLog: [String] { log }
    }

    private func makeCore(driver: AppDriver) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0060", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: false,
                    fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-hold-test-\(UUID().uuidString).json"),
                    emit: { _ in })
    }

    private func makeElement() -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "btn_tooltip_anchor", label: nil,
                   value: nil, placeholder: nil, enabled: true,
                   frame: FTRect(x: 100, y: 200, width: 50, height: 40), depth: 1)
    }

    /// ブロックは hold が送られた**後**、hold(の呼び出し)が返る**前**に走る
    func testTheBlockRunsBetweenTheHoldBeingSentAndHoldReturning() throws {
        let driver = HoldDriver(element: makeElement())
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    hold("#btn_tooltip_anchor", holdSeconds: 0.2) {
                        driver.recordBlockRan()
                    }
                }
            }
        }

        XCTAssertTrue(core.finalRecord.passed, "\(core.finalRecord)")
        XCTAssertEqual(driver.recordedLog, ["holdSent", "blockRan"])
    }

    /// 対象が解決できなければブロックは走らない(select と同じ「押せる前提が崩れたら何もしない」規律)
    func testTheBlockDoesNotRunWhenTheTargetIsNotFound() throws {
        let driver = HoldDriver(element: nil)
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var ranBlock = false
        scenario {
            scene(1, "s") {
                action {
                    hold("#btn_tooltip_anchor", holdSeconds: 0.2, waitSeconds: 0) {
                        ranBlock = true
                    }
                }
            }
        }

        XCTAssertFalse(core.finalRecord.passed, "対象が無いので holdStart は失敗するはず")
        XCTAssertFalse(ranBlock, "対象が見つからないのにブロックが走ってはいけない")
        XCTAssertTrue(driver.recordedLog.isEmpty, "hold を送ってはいけない: \(driver.recordedLog)")
    }
}
