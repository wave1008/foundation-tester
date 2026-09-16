import XCTest
@testable import FTCore

final class RunProfileDeviceEditorTests: XCTestCase {

    private func devices(_ object: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(object["devices"] as? [[String: Any]])
    }

    func testAddingDeviceAppendsToTheEnd() throws {
        let object: [String: Any] = [
            "app": "a",
            "devices": [["platform": "ios", "machine": "local", "name": "シミュ1", "model": "iPhone 17 Pro"]],
        ]
        let updated = try RunProfileDeviceEditor.addingDevice(
            toRunProfileObject: object,
            device: ["platform": "android", "machine": "local", "name": "エミュ1", "avd": "Pixel_9"])
        let list = try devices(updated)
        XCTAssertEqual(list.map { $0["name"] as? String }, ["シミュ1", "エミュ1"])
        XCTAssertEqual(list[1]["platform"] as? String, "android")
    }

    func testAddingDeviceCreatesDevicesArrayWhenMissing() throws {
        let updated = try RunProfileDeviceEditor.addingDevice(
            toRunProfileObject: ["app": "a"],
            device: ["platform": "ios", "machine": "local", "name": "シミュ1"])
        XCTAssertEqual(try devices(updated).count, 1)
    }

    func testAddingDevicePreservesUnknownKeys() throws {
        let object: [String: Any] = [
            "notes": "手動メモ",
            "devices": [["platform": "ios", "machine": "local", "name": "シミュ1", "extra": "維持"]],
        ]
        let updated = try RunProfileDeviceEditor.addingDevice(
            toRunProfileObject: object, device: ["platform": "ios", "machine": "local", "name": "シミュ2"])
        XCTAssertEqual(updated["notes"] as? String, "手動メモ")
        XCTAssertEqual(try devices(updated)[0]["extra"] as? String, "維持")
    }

    /// 同じ機械の同名は platform を跨いでも重複(無効の台も数える)
    func testAddingDeviceRejectsDuplicateNameOnTheSameMachineAcrossPlatforms() {
        let object: [String: Any] = [
            "devices": [["platform": "ios", "machine": "local", "name": "重複", "enabled": false]],
        ]
        XCTAssertThrowsError(try RunProfileDeviceEditor.addingDevice(
            toRunProfileObject: object,
            device: ["platform": "android", "name": "重複", "avd": "Pixel_9"])
        ) { error in
            guard case RunProfileDeviceEditorError.duplicateDeviceName(let name) = error else {
                return XCTFail("duplicateDeviceName ではありません: \(error)")
            }
            XCTAssertEqual(name, "重複")
        }
    }

    func testAddingDeviceAllowsTheSameNameOnAnotherMachine() throws {
        let object: [String: Any] = [
            "devices": [["platform": "ios", "machine": "local", "name": "iPhone-01"]],
        ]
        let updated = try RunProfileDeviceEditor.addingDevice(
            toRunProfileObject: object,
            device: ["platform": "ios", "machine": "M1Max", "name": "iPhone-01"])
        XCTAssertEqual(try devices(updated).count, 2)
    }

    func testUpsertReplacesTheSameMachineAndNameButKeepsEnabled() throws {
        let object: [String: Any] = [
            "devices": [
                ["platform": "ios", "machine": "local", "name": "simulator1", "enabled": false],
                ["platform": "ios", "machine": "M1Max", "name": "simulator1", "udid": "REMOTE"],
            ],
        ]
        let updated = try RunProfileDeviceEditor.upsertingDevice(
            inRunProfileObject: object,
            device: ["platform": "ios", "machine": "local", "name": "simulator1", "udid": "NEW"])
        let list = try devices(updated)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["udid"] as? String, "NEW")
        XCTAssertEqual(list[0]["enabled"] as? Bool, false, "再セットアップでチェックを勝手に戻さない")
        XCTAssertEqual(list[1]["udid"] as? String, "REMOTE", "別の機械の同名は触らない")
    }

    func testUpsertAppendsWhenAbsent() throws {
        let updated = try RunProfileDeviceEditor.upsertingDevice(
            inRunProfileObject: ["devices": [[String: Any]]()],
            device: ["platform": "android", "machine": "local", "name": "emulator1", "avd": "X"])
        XCTAssertEqual(try devices(updated).map { $0["name"] as? String }, ["emulator1"])
    }

    func testUpsertRejectsTheSameNameOnAnotherPlatform() {
        let object: [String: Any] = [
            "devices": [["platform": "ios", "machine": "local", "name": "dev"]],
        ]
        XCTAssertThrowsError(try RunProfileDeviceEditor.upsertingDevice(
            inRunProfileObject: object,
            device: ["platform": "android", "machine": "local", "name": "dev", "avd": "X"]))
    }

    func testLocalDeviceNamesSkipsRemoteAndMalformedEntries() {
        let object: [String: Any] = [
            "devices": [
                ["platform": "ios", "machine": "local", "name": "シミュ1"],
                ["platform": "ios", "name": "暗黙の手元"],
                ["platform": "ios", "machine": "M1Max", "name": "リモート"],
                ["platform": "ios", "machine": "local"],
                ["platform": "ios", "machine": "local", "name": 123],
            ],
        ]
        XCTAssertEqual(RunProfileDeviceEditor.localDeviceNames(inRunProfileObject: object),
                       ["シミュ1", "暗黙の手元"])
    }

    func testLocalDeviceNamesEmptyObject() {
        XCTAssertEqual(RunProfileDeviceEditor.localDeviceNames(inRunProfileObject: [:]), [])
    }

    func testSanitizedAVDIDReplacesSpacesAndParentheses() {
        XCTAssertEqual(
            RunProfileDeviceEditor.sanitizedAVDID(from: "Pixel 9(Android 16)"),
            "Pixel_9_Android_16")
    }

    func testSanitizedAVDIDCollapsesConsecutiveUnderscores() {
        XCTAssertEqual(RunProfileDeviceEditor.sanitizedAVDID(from: "a___b"), "a_b")
        XCTAssertEqual(RunProfileDeviceEditor.sanitizedAVDID(from: "a   b"), "a_b")
    }

    func testSanitizedAVDIDTrimsLeadingAndTrailingUnderscores() {
        XCTAssertEqual(RunProfileDeviceEditor.sanitizedAVDID(from: "  leading and trailing  "),
                       "leading_and_trailing")
    }

    func testSanitizedAVDIDJapaneseNameKeepsOnlyASCIIDigits() {
        // 日本語文字は全て置換対象。連続置換は 1 つの "_" に圧縮され、末尾の数字は残る
        XCTAssertEqual(RunProfileDeviceEditor.sanitizedAVDID(from: "エミュ1"), "1")
    }

    func testSanitizedAVDIDAllInvalidCharactersFallsBackToAvd() {
        XCTAssertEqual(RunProfileDeviceEditor.sanitizedAVDID(from: "＠＃＄"), "avd")
        XCTAssertEqual(RunProfileDeviceEditor.sanitizedAVDID(from: "   "), "avd")
        XCTAssertEqual(RunProfileDeviceEditor.sanitizedAVDID(from: ""), "avd")
    }

    func testAndroidVersionNameBelowTable() {
        XCTAssertEqual(RunProfileDeviceEditor.androidVersionName(apiLevel: 19), "API 19")
        XCTAssertEqual(RunProfileDeviceEditor.androidVersionName(apiLevel: 1), "API 1")
    }

    func testAndroidVersionNameWithinTable() {
        XCTAssertEqual(RunProfileDeviceEditor.androidVersionName(apiLevel: 21), "Android 5.0")
        XCTAssertEqual(RunProfileDeviceEditor.androidVersionName(apiLevel: 24), "Android 7")
        XCTAssertEqual(RunProfileDeviceEditor.androidVersionName(apiLevel: 29), "Android 10")
        XCTAssertEqual(RunProfileDeviceEditor.androidVersionName(apiLevel: 32), "Android 12L")
    }

    func testAndroidVersionNameAboveTable() {
        XCTAssertEqual(RunProfileDeviceEditor.androidVersionName(apiLevel: 33), "Android 13")
        XCTAssertEqual(RunProfileDeviceEditor.androidVersionName(apiLevel: 37), "Android 17")
    }
}
