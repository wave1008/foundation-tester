// hybrid で XCUITest へ回した打鍵(改行を含む type)も、キーボードの下の欄なら撃つ前に送る。XCUITest は欄を座標で
// タップしてから打つので、キーボードに当たると焦点が前の欄に残って打鍵が流れ込む(E2EX-CMP の複数行の欄で、
// 打鍵がパスワードの欄へ入った)。判断は XCUITest の木で行う(in-app の木はキーボードを申告しない)

import XCTest
@testable import FTCore

final class TypeDriverLiftTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func tree(fieldY: Double = 550) -> [ElementInfo] {
        [ElementInfo(ref: 1, type: "scrollView", identifier: nil, label: nil, value: nil, placeholder: nil,
                     enabled: true, frame: screen, depth: 1, scrollable: true),
         ElementInfo(ref: 2, type: "textView", identifier: "field_multiline", label: "メモ", value: nil,
                     placeholder: nil, enabled: true, frame: FTRect(x: 16, y: fieldY, width: 370, height: 112), depth: 2)]
    }

    func testTypeRoutedToXCUITestLiftsAFieldUnderTheKeyboardFirst() async throws {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [tree()])
        // 送った後の撮り直しは XCUITest の木(キーボードを申告するのはこちらだけ)= 欄がキーボードの上へ出た木
        let xcui = FakeAppDriver(name: "typedriver", log: log, snapshotElements: [tree(), tree(fieldY: 200)])
        xcui.keyboardFrame = FTRect(x: 0, y: 538, width: 402, height: 336)
        let executor = StepExecutor(driver: primary, typeDriver: xcui, preferTypeDriver: false, isAndroid: false,
                                    tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "field_multiline"),
                                                      text: "a\nb"))
        guard case .passed = outcome.status else { XCTFail("\(outcome.status)"); return }
        let drags = primary.dragCalls.count + xcui.dragCalls.count
        XCTAssertGreaterThan(drags, 0, "キーボードの下の欄を送らずに XCUITest へ打たせた: \(log.entries)")
        let typeIndex = try XCTUnwrap(log.entries.firstIndex { $0.hasPrefix("typedriver.type(") }, "\(log.entries)")
        XCTAssertFalse(log.entries[typeIndex...].contains { $0.contains("drag") }, "送りは打つ前")
        XCTAssertTrue((outcome.driverFallback ?? "").contains("out from under the keyboard"), outcome.driverFallback ?? "")
    }
}
