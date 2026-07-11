// MachineProfileEditorTests.swift

import XCTest
@testable import FTCore

final class MachineProfileEditorTests: XCTestCase {

    // MARK: - addingDevice: 基本追加

    func testAddingDeviceBasicAddition() throws {
        let object: [String: Any] = [
            "ios": ["devices": [["name": "シミュ1", "simulator": "iPhone 17 Pro", "os": "27.0"]]],
        ]
        let updated = try MachineProfileEditor.addingDevice(
            toProfileObject: object, platform: "ios",
            device: ["name": "シミュ2", "simulator": "iPhone 16", "os": "26.0"])

        let devices = try XCTUnwrap((updated["ios"] as? [String: Any])?["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0]["name"] as? String, "シミュ1")
        XCTAssertEqual(devices[1]["name"] as? String, "シミュ2")
        XCTAssertEqual(devices[1]["simulator"] as? String, "iPhone 16")
    }

    // MARK: - addingDevice: セクション/devices 配列欠落時の生成

    func testAddingDeviceCreatesSectionWhenMissing() throws {
        let object: [String: Any] = [:]
        let updated = try MachineProfileEditor.addingDevice(
            toProfileObject: object, platform: "android",
            device: ["name": "エミュ1", "avd": "Pixel_9"])

        let android = try XCTUnwrap(updated["android"] as? [String: Any])
        let devices = try XCTUnwrap(android["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0]["name"] as? String, "エミュ1")
        XCTAssertEqual(devices[0]["avd"] as? String, "Pixel_9")
        // 他プラットフォームのセクションは作られない
        XCTAssertNil(updated["ios"])
    }

    func testAddingDeviceCreatesDevicesArrayWhenSectionExistsButEmpty() throws {
        // ios セクション自体は存在するが devices キーが無いケース
        let object: [String: Any] = ["ios": [String: Any]()]
        let updated = try MachineProfileEditor.addingDevice(
            toProfileObject: object, platform: "ios",
            device: ["name": "シミュ1", "simulator": "iPhone 17 Pro", "os": "27.0"])

        let devices = try XCTUnwrap((updated["ios"] as? [String: Any])?["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0]["name"] as? String, "シミュ1")
    }

    // MARK: - addingDevice: 未知キー保持

    func testAddingDevicePreservesUnknownKeys() throws {
        let object: [String: Any] = [
            "notes": "手動メモ",
            "ios": [
                "extra": "維持されるはず",
                "devices": [["name": "シミュ1", "simulator": "iPhone 17 Pro", "os": "27.0"]],
            ],
        ]
        let updated = try MachineProfileEditor.addingDevice(
            toProfileObject: object, platform: "ios",
            device: ["name": "シミュ2", "simulator": "iPhone 16", "os": "26.0"])

        // トップレベルの未知キー
        XCTAssertEqual(updated["notes"] as? String, "手動メモ")

        let ios = try XCTUnwrap(updated["ios"] as? [String: Any])
        // ios セクション内の未知キー
        XCTAssertEqual(ios["extra"] as? String, "維持されるはず")

        let devices = try XCTUnwrap(ios["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0]["name"] as? String, "シミュ1")
        XCTAssertEqual(devices[1]["name"] as? String, "シミュ2")
    }

    // MARK: - addingDevice: 名前重複エラー(ios↔android 横断)

    func testAddingDeviceDuplicateNameAcrossPlatforms() {
        let object: [String: Any] = [
            "ios": ["devices": [["name": "重複", "simulator": "iPhone 17 Pro", "os": "27.0"]]],
        ]
        XCTAssertThrowsError(try MachineProfileEditor.addingDevice(
            toProfileObject: object, platform: "android",
            device: ["name": "重複", "avd": "Pixel_9"])
        ) { error in
            guard case MachineProfileEditorError.duplicateDeviceName(let name) = error else {
                return XCTFail("duplicateDeviceName ではありません: \(error)")
            }
            XCTAssertEqual(name, "重複")
        }
    }

    func testAddingDeviceDuplicateNameWithinSamePlatform() {
        let object: [String: Any] = [
            "android": ["devices": [["name": "重複", "avd": "Pixel_9"]]],
        ]
        XCTAssertThrowsError(try MachineProfileEditor.addingDevice(
            toProfileObject: object, platform: "android",
            device: ["name": "重複", "avd": "Pixel_10"]))
    }

    // MARK: - deviceNames

    func testDeviceNames() {
        let object: [String: Any] = [
            "ios": ["devices": [
                ["name": "シミュ1", "simulator": "iPhone 17 Pro"],
                ["simulator": "名前なし"],  // name が無い要素はスキップされる
                ["name": 123],  // name が String でない要素もスキップされる
            ]],
            "android": ["devices": [["name": "エミュ1", "avd": "Pixel_9"]]],
        ]
        let names = MachineProfileEditor.deviceNames(inProfileObject: object)
        XCTAssertEqual(Set(names), Set(["シミュ1", "エミュ1"]))
        XCTAssertEqual(names.count, 2)
    }

    func testDeviceNamesEmptyObject() {
        XCTAssertEqual(MachineProfileEditor.deviceNames(inProfileObject: [:]), [])
    }

    // MARK: - sanitizedAVDID

    func testSanitizedAVDIDReplacesSpacesAndParentheses() {
        XCTAssertEqual(
            MachineProfileEditor.sanitizedAVDID(from: "Pixel 9(Android 16)"),
            "Pixel_9_Android_16")
    }

    func testSanitizedAVDIDCollapsesConsecutiveUnderscores() {
        XCTAssertEqual(MachineProfileEditor.sanitizedAVDID(from: "a___b"), "a_b")
        XCTAssertEqual(MachineProfileEditor.sanitizedAVDID(from: "a   b"), "a_b")
    }

    func testSanitizedAVDIDTrimsLeadingAndTrailingUnderscores() {
        XCTAssertEqual(MachineProfileEditor.sanitizedAVDID(from: "  leading and trailing  "),
                       "leading_and_trailing")
    }

    func testSanitizedAVDIDJapaneseNameKeepsOnlyASCIIDigits() {
        // 日本語文字は全て置換対象。連続置換は 1 つの "_" に圧縮され、末尾の数字は残る
        XCTAssertEqual(MachineProfileEditor.sanitizedAVDID(from: "エミュ1"), "1")
    }

    func testSanitizedAVDIDAllInvalidCharactersFallsBackToAvd() {
        XCTAssertEqual(MachineProfileEditor.sanitizedAVDID(from: "＠＃＄"), "avd")
        XCTAssertEqual(MachineProfileEditor.sanitizedAVDID(from: "   "), "avd")
        XCTAssertEqual(MachineProfileEditor.sanitizedAVDID(from: ""), "avd")
    }

    // MARK: - androidVersionName

    func testAndroidVersionNameBelowTable() {
        XCTAssertEqual(MachineProfileEditor.androidVersionName(apiLevel: 19), "API 19")
        XCTAssertEqual(MachineProfileEditor.androidVersionName(apiLevel: 1), "API 1")
    }

    func testAndroidVersionNameWithinTable() {
        XCTAssertEqual(MachineProfileEditor.androidVersionName(apiLevel: 21), "Android 5.0")
        XCTAssertEqual(MachineProfileEditor.androidVersionName(apiLevel: 24), "Android 7")
        XCTAssertEqual(MachineProfileEditor.androidVersionName(apiLevel: 29), "Android 10")
        XCTAssertEqual(MachineProfileEditor.androidVersionName(apiLevel: 32), "Android 12L")
    }

    func testAndroidVersionNameAboveTable() {
        XCTAssertEqual(MachineProfileEditor.androidVersionName(apiLevel: 33), "Android 13")
        XCTAssertEqual(MachineProfileEditor.androidVersionName(apiLevel: 37), "Android 17")
    }
}
