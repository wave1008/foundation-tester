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
                                      running: true, physical: false, registered: true, port: 8123)
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
                                      running: false, physical: true, registered: false, port: nil)
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
            livePorts: ["iPhone 17 Pro": 8124])
        XCTAssertTrue(row.running)
        XCTAssertEqual(row.identifier, "SIM-1")
        XCTAssertEqual(row.port, 8124)
        XCTAssertFalse(row.physical)
        XCTAssertTrue(row.registered)
    }

    func testIOSRowWithNoMatchIsNotRunningAndKeepsSpecUDID() {
        let row = DeviceInventory.iosRow(
            spec: spec(name: "stale", simulator: "iPad Pro", udid: "GHOST-UDID"),
            simDevices: [], physicalDevices: [], livePorts: [:])
        XCTAssertFalse(row.running)
        XCTAssertEqual(row.identifier, "GHOST-UDID")
        XCTAssertNil(row.port)
    }

    func testIOSRowPhysicalUsesConnectedFlagFromCatalog() {
        let connected = IOSPhysicalDeviceInfo(udid: "PHYS-1", name: "wave's iPhone", os: "iOS 18.5",
                                              connected: true, transport: "wired")
        let row = DeviceInventory.iosRow(
            spec: spec(name: "my-phone", kind: .physical, udid: "PHYS-1"),
            simDevices: [], physicalDevices: [connected], livePorts: [:])
        XCTAssertTrue(row.running)
        XCTAssertTrue(row.physical)
        XCTAssertEqual(row.identifier, "PHYS-1")
    }

    func testIOSRowPhysicalDisconnectedIsNotRunning() {
        let disconnected = IOSPhysicalDeviceInfo(udid: "PHYS-2", name: "old iPhone", os: "iOS 17.0",
                                                  connected: false, transport: "wired")
        let row = DeviceInventory.iosRow(
            spec: spec(name: "old-phone", kind: .physical, udid: "PHYS-2"),
            simDevices: [], physicalDevices: [disconnected], livePorts: [:])
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

    func testRenderAppLinesReportsZeroExplicitly() {
        let text = DeviceInventory.renderAppLines(userApps: [], systemCount: 12)
        XCTAssertTrue(text.contains("0 user apps installed"), text)
    }

    func testRenderAppLinesListsUserAppsAndOmittedSystemCount() {
        let text = DeviceInventory.renderAppLines(
            userApps: ["com.example.one  One", "com.example.two  Two"], systemCount: 40)
        XCTAssertTrue(text.contains("2 user app(s):"), text)
        XCTAssertTrue(text.contains("com.example.one  One"), text)
        XCTAssertTrue(text.contains("40 system app(s) omitted"), text)
    }

    /// Android は user のみ列挙(pm list packages -3)で system 件数の概念が無い —
    /// nil のときは省略行を出さない
    func testRenderAppLinesOmitsSystemLineWhenCountIsNil() {
        let text = DeviceInventory.renderAppLines(userApps: ["com.example.one"], systemCount: nil)
        XCTAssertFalse(text.contains("system app"), text)
    }
}
