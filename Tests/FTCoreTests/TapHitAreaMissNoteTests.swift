// in-app の ref タップが「枠の中心で本物のタッチを受けるのは別の view」と申告したら(`TapHitAreaMiss`)、
// DSL の tap は**判定を変えずに**注記だけを残す(コード `inapp-tap-outside-hit-area` + 事実の括弧書き)。
// 判定はブリッジの1箇所(InAppBridge の hitAreaMissBeforeActivate)で、ホストは写すだけ。

import XCTest
@testable import FTCore

final class TapHitAreaMissNoteTests: XCTestCase {

    private final class MissReportingDriver: AppDriver, @unchecked Sendable {
        let miss: TapHitAreaMiss?
        private(set) var refTaps: [Int] = []
        private(set) var coordinateTaps = 0
        private var lastMiss: TapHitAreaMiss?
        init(miss: TapHitAreaMiss?) { self.miss = miss }

        var lastTapHitAreaMiss: TapHitAreaMiss? { lastMiss }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func snapshot() async throws -> SnapshotResponse {
            let element = ElementInfo(ref: 1, type: "button", identifier: "btn_jump_bottom", label: "最新へ",
                                      value: nil, placeholder: nil, enabled: true,
                                      frame: FTRect(x: 318, y: 827, width: 72, height: 34), depth: 0)
            return SnapshotResponse(sessionBundleID: nil,
                                    screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                    elements: [element], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {
            refTaps.append(ref)
            lastMiss = miss
        }
        func tap(x: Double, y: Double) async throws { coordinateTaps += 1 }
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func tap(_ driver: MissReportingDriver) async -> StepOutcome {
        await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_jump_bottom"), timeout: 1))
    }

    /// 申告があれば: 緑のまま・撃ち直さない・コードと事実(受けた view・点)を残す
    func testReportedMissIsNotedWithoutChangingTheVerdict() async {
        let driver = MissReportingDriver(miss: TapHitAreaMiss(x: 354, y: 844.8, receiver: "ChatInputBar"))
        let outcome = await tap(driver)

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.refTaps, [1], "撃ち直さない")
        XCTAssertEqual(driver.coordinateTaps, 0, "別の経路で撃ち直さない")
        XCTAssertTrue(outcome.notes.contains(.inAppTapOutsideHitArea), "\(outcome.notes)")
        let text = outcome.driverFallback ?? ""
        XCTAssertTrue(text.contains("lands on another view"), text)
        XCTAssertTrue(text.contains("ChatInputBar at (354, 845)"), text)
    }

    /// 活性化の点のずれ(SwiftUI の `.contentShape` 抜け)は別のコードと事実の括弧書きで残す
    func testActivationPointOffCentreIsNotedWithItsOwnCode() async {
        let driver = MissReportingDriver(miss: TapHitAreaMiss(x: 201, y: 570.3,
                                                              kind: .activationPoint(x: 44.3, y: 570.3)))
        let outcome = await tap(driver)

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.refTaps, [1], "撃ち直さない")
        XCTAssertEqual(driver.coordinateTaps, 0, "別の経路で撃ち直さない")
        XCTAssertTrue(outcome.notes.contains(.inAppActivationPointOffCentre), "\(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains(.inAppTapOutsideHitArea), "\(outcome.notes)")
        let text = outcome.driverFallback ?? ""
        XCTAssertTrue(text.contains("activation point (44, 570), centre (201, 570)"), text)
    }

    /// 陰性: 申告が無ければ(届く・判定不能・in-app 以外)何も言わない
    func testNoReportMeansNoNote() async {
        let driver = MissReportingDriver(miss: nil)
        let outcome = await tap(driver)

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(outcome.notes.contains(.inAppTapOutsideHitArea), "\(outcome.notes)")
        XCTAssertFalse(outcome.notes.contains(.inAppActivationPointOffCentre), "\(outcome.notes)")
        XCTAssertFalse((outcome.driverFallback ?? "").contains("lands on another view"),
                       outcome.driverFallback ?? "")
    }

    /// ワイヤ形式: 欄は in-app の ref タップだけが立て、無い応答(XCUITest・Android・他の操作)は nil で読める
    func testOKResponseCarriesTheMissAndDecodesWithoutIt() throws {
        let miss = TapHitAreaMiss(x: 1.5, y: 2, receiver: "_UIGrabber")
        let data = try JSONEncoder().encode(OKResponse(hitAreaMiss: miss))
        XCTAssertEqual(try JSONDecoder().decode(OKResponse.self, from: data).hitAreaMiss, miss)
        let offCentre = TapHitAreaMiss(x: 201, y: 570, kind: .activationPoint(x: 44, y: 570))
        let data2 = try JSONEncoder().encode(OKResponse(hitAreaMiss: offCentre))
        XCTAssertEqual(try JSONDecoder().decode(OKResponse.self, from: data2).hitAreaMiss, offCentre)
        let plain = try JSONDecoder().decode(OKResponse.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertNil(plain.hitAreaMiss)
    }
}
