// serial を渡さない対話コマンドのデバイス選択。
//
// ここが緩むと 2026-08-06 のフィードバック #5 が再発する(`-s` 無しの adb が
// "more than one device/emulator" で落ち、生のエラーが利用者へ出る)。
// 複数台で自動採用しないのは、はぐれエミュレータを黙って操作させないため。

import XCTest
@testable import FTAndroid

final class AndroidSerialResolverTests: XCTestCase {

    func testExplicitSerialAlwaysWins() {
        XCTAssertEqual(
            AndroidSerialResolver.decide(explicit: "emulator-5556",
                                         connected: ["emulator-5554", "emulator-5556"]),
            .use("emulator-5556"))
    }

    /// 空文字は未指定として扱う(MCP 引数から素通しで来る)
    func testEmptyExplicitSerialIsTreatedAsUnset() {
        XCTAssertEqual(AndroidSerialResolver.decide(explicit: "", connected: ["emulator-5554"]),
                       .use("emulator-5554"))
    }

    func testAdoptsTheOnlyConnectedDevice() {
        XCTAssertEqual(AndroidSerialResolver.decide(explicit: nil, connected: ["emulator-5554"]),
                       .use("emulator-5554"))
    }

    func testMultipleDevicesAreAmbiguous() {
        XCTAssertEqual(
            AndroidSerialResolver.decide(explicit: nil,
                                         connected: ["emulator-5556", "emulator-5554"]),
            .ambiguous([AndroidSerialResolver.Device(serial: "emulator-5554", avd: nil),
                        AndroidSerialResolver.Device(serial: "emulator-5556", avd: nil)]),
            "serial 昇順で提示すること")
    }

    func testNoDevice() {
        XCTAssertEqual(AndroidSerialResolver.decide(explicit: nil, connected: []), .none)
    }

    /// 文言はそのまま利用者(エージェント)への指示になる。**AVD 名まで見せる**
    /// (serial だけではどのエミュレータか分からない)
    func testMessagesCarrySerialsAVDNamesAndTheNextStep() {
        let ambiguous = AndroidSerialResolver.ambiguousMessage([
            AndroidSerialResolver.Device(serial: "emulator-5554", avd: "Pixel_9_Android_16"),
            AndroidSerialResolver.Device(serial: "emulator-5556", avd: nil),
        ])
        XCTAssertTrue(ambiguous.contains("emulator-5554 (Pixel_9_Android_16)"), ambiguous)
        XCTAssertTrue(ambiguous.contains("emulator-5556"), ambiguous)
        XCTAssertTrue(ambiguous.contains("serial:"), ambiguous)
        XCTAssertTrue(ambiguous.contains("profile:"), ambiguous)

        XCTAssertTrue(AndroidSerialResolver.noDeviceMessage.contains("devices up"),
                      AndroidSerialResolver.noDeviceMessage)
    }
}
