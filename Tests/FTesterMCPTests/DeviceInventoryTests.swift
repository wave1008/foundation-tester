// ft_list_devices / ft_list_apps の本文整形(DeviceInventory.swift)。
//
// マシンプロファイル・実デバイスに依存する経路(resolveMachine 成否・simctl/adb の実測)は
// このテストでは検証できない(スイート実行環境に依存するため)。ここで固定するのは:
// - devicesText は解決不能なときも throw せず英文で説明する(型シグネチャに throws が無いので
//   コンパイラが保証するが、実際に説明文が出ることまで確認する)
// - line/fallbackHeader/iosRow/androidRow/renderAppLines という**純粋な整形関数**の入出力

import XCTest
import FTAndroid
import FTBridgeClient
import FTCore
@testable import ftester_mcp

final class DeviceInventoryTests: XCTestCase {

    // MARK: - devicesText はプロファイル未解決でも throw せず案内文を返す

    /// フォールバックしたときは**理由を名指しする**。設定の壊れ(登録マシン名とプロファイル名の
    /// 不一致など)を黙って隠すと、受け手は profiles/ が死んでいることに気づけない
    func testDevicesTextFallsBackWithTheReasonNamed() async {
        let missing = "no-such-project-for-device-inventory-tests"
        let text = await DeviceInventory.devicesText(project: missing, profile: nil, platform: nil)
        XCTAssertTrue(text.contains("Not using a machine profile"), text)
        XCTAssertTrue(text.contains(missing), text)
    }

    func testDevicesTextReportsUnknownPlatformWithoutTouchingDevices() async {
        let text = await DeviceInventory.devicesText(project: nil, profile: nil, platform: "windows")
        XCTAssertTrue(text.contains("unknown platform"), text)
        XCTAssertTrue(text.contains("windows"), text)
    }

    // MARK: - fallbackHeader (純粋関数)

    func testFallbackHeaderIsEnglishAndExplainsTheSubstitution() {
        let header = DeviceInventory.fallbackHeader(reason: "machine profile \"X\" is not in P")
        XCTAssertTrue(header.contains("Not using a machine profile"), header)
        XCTAssertTrue(header.contains("machine profile \"X\" is not in P"), header)
        XCTAssertTrue(header.contains("booted/connected"), header)
    }

    // MARK: - line (純粋関数)

    func testLineIncludesAllFieldsWhenPresent() {
        let row = DeviceInventory.Row(name: "iPhone 17 Pro", platform: "ios", identifier: "ABCD-1234",
                                      running: true, physical: false, registered: true,
                                      bridges: [DeviceInventory.Row.Bridge(port: 8123, engine: nil)])
        let text = DeviceInventory.line(row)
        XCTAssertTrue(text.contains("iPhone 17 Pro"), text)
        XCTAssertTrue(text.contains("ios"), text)
        XCTAssertTrue(text.contains("virtual"), text)
        XCTAssertTrue(text.contains("registered"), text)
        XCTAssertTrue(text.contains("running"), text)
        XCTAssertTrue(text.contains("udid ABCD-1234"), text)
        XCTAssertTrue(text.contains("bridge port 8123"), text)
    }

    func testLineOmitsIdentifierAndPortWhenUnknown() {
        let row = DeviceInventory.Row(name: "Pixel 8", platform: "android", identifier: nil,
                                      running: false, physical: true, registered: false, bridges: [])
        let text = DeviceInventory.line(row)
        XCTAssertTrue(text.contains("Pixel 8"), text)
        XCTAssertTrue(text.contains("android"), text)
        XCTAssertTrue(text.contains("physical"), text)
        XCTAssertTrue(text.contains("unregistered"), text)
        XCTAssertTrue(text.contains("not running"), text)
        XCTAssertFalse(text.contains("udid"), text)
        XCTAssertFalse(text.contains("serial"), text)
        XCTAssertFalse(text.contains("bridge port"), text)
    }

    // MARK: - iosRow (純粋関数)

    private func spec(name: String, kind: DeviceKind? = nil, simulator: String? = nil,
                      os: String? = nil, udid: String? = nil) -> DeviceSpec {
        DeviceSpec(name: name, kind: kind, simulator: simulator, os: os, udid: udid)
    }

    func testIOSRowMatchesBootedSimulatorByNameAndCarriesItsPort() {
        let device = SimDeviceInfo(udid: "SIM-1", name: "iPhone 17 Pro", os: "iOS 26.0", booted: true)
        let row = DeviceInventory.iosRow(
            spec: spec(name: "primary", simulator: "iPhone 17 Pro"),
            simDevices: [device], physicalDevices: [],
            liveBridges: ["iPhone 17 Pro": [DeviceInventory.Row.Bridge(port: 8124, engine: nil)]])
        XCTAssertTrue(row.running)
        XCTAssertEqual(row.identifier, "SIM-1")
        XCTAssertEqual(row.bridges.first?.port, 8124)
        XCTAssertFalse(row.physical)
        XCTAssertTrue(row.registered)
    }

    func testIOSRowWithNoMatchIsNotRunningAndKeepsSpecUDID() {
        let row = DeviceInventory.iosRow(
            spec: spec(name: "stale", simulator: "iPad Pro", udid: "GHOST-UDID"),
            simDevices: [], physicalDevices: [])
        XCTAssertFalse(row.running)
        XCTAssertEqual(row.identifier, "GHOST-UDID")
        XCTAssertNil(row.bridges.first?.port)
    }

    func testIOSRowPhysicalUsesConnectedFlagFromCatalog() {
        let connected = IOSPhysicalDeviceInfo(udid: "PHYS-1", name: "wave's iPhone", os: "iOS 18.5",
                                              connected: true, transport: "wired")
        let row = DeviceInventory.iosRow(
            spec: spec(name: "my-phone", kind: .physical, udid: "PHYS-1"),
            simDevices: [], physicalDevices: [connected])
        XCTAssertTrue(row.running)
        XCTAssertTrue(row.physical)
        XCTAssertEqual(row.identifier, "PHYS-1")
    }

    func testIOSRowPhysicalDisconnectedIsNotRunning() {
        let disconnected = IOSPhysicalDeviceInfo(udid: "PHYS-2", name: "old iPhone", os: "iOS 17.0",
                                                  connected: false, transport: "wired")
        let row = DeviceInventory.iosRow(
            spec: spec(name: "old-phone", kind: .physical, udid: "PHYS-2"),
            simDevices: [], physicalDevices: [disconnected])
        XCTAssertFalse(row.running)
    }

    // MARK: - androidRow (純粋関数)

    func testAndroidRowMatchesConnectedAVDByName() {
        let connected = [AndroidSerialResolver.Device(serial: "emulator-5554", avd: "Pixel_8_API_34")]
        let row = DeviceInventory.androidRow(
            spec: DeviceSpec(name: "primary", avd: "Pixel_8_API_34"),
            connectedDevices: connected)
        XCTAssertTrue(row.running)
        XCTAssertEqual(row.identifier, "emulator-5554")
        XCTAssertFalse(row.physical)
    }

    func testAndroidRowWithNoMatchingAVDIsNotRunning() {
        let row = DeviceInventory.androidRow(
            spec: DeviceSpec(name: "stopped", avd: "Never_Booted"), connectedDevices: [])
        XCTAssertFalse(row.running)
        XCTAssertNil(row.identifier)
    }

    func testAndroidRowPhysicalMatchesBySerial() {
        let connected = [AndroidSerialResolver.Device(serial: "R3CN90ABCDE", avd: nil)]
        let row = DeviceInventory.androidRow(
            spec: DeviceSpec(name: "my-pixel", kind: .physical, serial: "R3CN90ABCDE"),
            connectedDevices: connected)
        XCTAssertTrue(row.running)
        XCTAssertTrue(row.physical)
        XCTAssertEqual(row.identifier, "R3CN90ABCDE")
    }

    // MARK: - renderAppLines (純粋関数)

    private static let rows = [
        DeviceInventory.AppRow(id: "com.example.one", name: "One", isUser: true),
        DeviceInventory.AppRow(id: "com.example.two", name: "Two", isUser: true),
        DeviceInventory.AppRow(id: "com.apple.Maps", name: "マップ", isUser: false),
    ]

    func testRenderAppLinesReportsZeroExplicitly() {
        let text = DeviceInventory.renderAppLines([], includeSystem: false, filter: nil)
        XCTAssertTrue(text.contains("0 app(s) installed"), text)
    }

    func testRenderAppLinesListsUserAppsAndPointsAtTheHiddenSystemOnes() {
        let text = DeviceInventory.renderAppLines(Self.rows, includeSystem: false, filter: nil)
        XCTAssertTrue(text.contains("2 app(s):"), text)
        XCTAssertTrue(text.contains("com.example.one  One"), text)
        XCTAssertFalse(text.contains("com.apple.Maps"), text)
        // **「system は見ていない」を必ず言う**(これが無いと空振りが「入っていない」に見える)
        XCTAssertTrue(text.contains("1 system app(s) not listed — pass includeSystem: true"), text)
    }

    func testRenderAppLinesIncludesSystemAppsMarked() {
        let text = DeviceInventory.renderAppLines(Self.rows, includeSystem: true, filter: nil)
        XCTAssertTrue(text.contains("com.apple.Maps  マップ  [system]"), text)
        XCTAssertFalse(text.contains("not listed"), text)
    }

    /// filter は id と表示名の両方に当たり、大小を無視する
    func testRenderAppLinesFiltersByIDAndName() {
        let byID = DeviceInventory.renderAppLines(Self.rows, includeSystem: true, filter: "maps")
        XCTAssertTrue(byID.contains("com.apple.Maps"), byID)
        XCTAssertFalse(byID.contains("com.example.one"), byID)
        let byName = DeviceInventory.renderAppLines(Self.rows, includeSystem: true, filter: "マップ")
        XCTAssertTrue(byName.contains("com.apple.Maps"), byName)
    }

    /// **Android のように system の件数が数えられない面でも案内は出す**(2026-08-09 の実地確認)。
    /// `pm list packages -3` は端末側で絞り込むので rows に system が1件も来ない ——
    /// 件数で分岐すると、いちばん詰まりやすい面でだけ逃げ道が消える
    func testRenderAppLinesStillPointsAtSystemAppsWhenTheyCannotBeCounted() {
        let userOnly = Self.rows.filter(\.isUser)
        let text = DeviceInventory.renderAppLines(userOnly, includeSystem: false, filter: nil,
                                                  systemAppsCounted: false)
        XCTAssertTrue(text.contains("system apps are not listed — pass includeSystem: true"), text)
        // 数えられる面では件数を出す(こちらは従来どおり)
        let counted = DeviceInventory.renderAppLines(Self.rows, includeSystem: false, filter: nil,
                                                     systemAppsCounted: true)
        XCTAssertTrue(counted.contains("1 system app(s) not listed"), counted)
    }

    /// 空振りは「探した範囲」を添えて言う(system を見ていないなら、そのことも)
    func testRenderAppLinesExplainsAnEmptyFilterResult() {
        let text = DeviceInventory.renderAppLines(Self.rows, includeSystem: false, filter: "maps")
        XCTAssertTrue(text.contains("no app matches \"maps\" among the 2 listed"), text)
        XCTAssertTrue(text.contains("pass includeSystem: true"), text)
    }
}
