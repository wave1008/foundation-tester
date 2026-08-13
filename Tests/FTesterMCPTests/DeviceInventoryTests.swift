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
            liveBridges: DeviceInventory.LiveBridges(
                byName: ["iPhone 17 Pro": [DeviceInventory.Row.Bridge(port: 8124, engine: nil)]],
                byUDID: [:]))
        XCTAssertTrue(row.running)
        XCTAssertEqual(row.identifier, "SIM-1")
        XCTAssertEqual(row.bridges.first?.port, 8124)
        XCTAssertFalse(row.physical)
        XCTAssertTrue(row.registered)
    }

    /// udid 一致と名前一致は和集合で出ること(欠陥③・2026-08-14。以前は udid 側が
    /// 1本でも当たると名前側を丸ごと捨てていた)。この形は両方に別のポートが1本ずつ載るので、
    /// 結果は port 昇順で両方揃う
    func testIOSRowUnionsUDIDMatchAndNameMatchWhenBothPresent() {
        let device = SimDeviceInfo(udid: "SIM-2", name: "iPhone 17 Pro", os: "iOS 26.0", booted: true)
        let live = DeviceInventory.LiveBridges(
            byName: ["iPhone 17 Pro": [DeviceInventory.Row.Bridge(port: 9999, engine: nil)]],
            byUDID: ["SIM-2": [DeviceInventory.Row.Bridge(port: 8124, engine: nil)]])
        let row = DeviceInventory.iosRow(
            spec: spec(name: "primary", simulator: "iPhone 17 Pro"),
            simDevices: [device], physicalDevices: [], liveBridges: live)
        XCTAssertEqual(row.bridges.map(\.port), [8124, 9999], "udid 一致と名前一致が両方出ること")
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

    /// 実機の `/status.device` は "iPhone" のような機種名で返り、プロファイルの表示名
    /// ("iPhone wave" 等)とは一致しない。udid だけが両者を橋渡しできる安定鍵であること
    /// (欠陥①(a)の再発防止)
    func testIOSRowPhysicalFindsBridgeByUDIDEvenWhenDeviceNameDoesNotMatch() {
        let connected = IOSPhysicalDeviceInfo(udid: "00008130-001819863E60001C", name: "iPhone wave",
                                              os: "iOS 26.6", connected: true, transport: "wired")
        let live = DeviceInventory.LiveBridges(
            byName: [:],  // status.device="iPhone" はプロファイル名 "iPhone wave" と一致しない
            byUDID: ["00008130-001819863E60001C":
                [DeviceInventory.Row.Bridge(port: 8144, engine: "xcuitest")]])
        let row = DeviceInventory.iosRow(
            spec: spec(name: "iPhone wave", kind: .physical, udid: "00008130-001819863E60001C"),
            simDevices: [], physicalDevices: [connected], liveBridges: live)
        XCTAssertTrue(row.running)
        XCTAssertEqual(row.bridges.first?.port, 8144)
        XCTAssertTrue(DeviceInventory.line(row).contains("bridge port 8144 (xcuitest)"),
                     DeviceInventory.line(row))
    }

    /// udid に一致するブリッジが見つからないときは従来どおり「no bridge」文言に落ちること
    /// (記録が無い旧ブリッジ・別 udid のブリッジのケース)
    func testIOSRowPhysicalWithoutMatchingBridgeStillSaysNoBridge() {
        let connected = IOSPhysicalDeviceInfo(udid: "PHYS-3", name: "iPhone", os: "iOS 26.6",
                                              connected: true, transport: "wired")
        let row = DeviceInventory.iosRow(
            spec: spec(name: "my-phone", kind: .physical, udid: "PHYS-3"),
            simDevices: [], physicalDevices: [connected])
        XCTAssertTrue(row.running)
        XCTAssertTrue(row.bridges.isEmpty)
        XCTAssertTrue(DeviceInventory.line(row).contains("no bridge"), DeviceInventory.line(row))
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

    // MARK: - 配線(ソース走査): ブリッジ走査に repoRoot を渡すこと

    /// `repoRoot: nil` で走査すると `BridgeEndpoint.load` が記録を読めず 127.0.0.1 へ落ちるため、
    /// **lan トランスポート(実機を LAN IP で直叩き)のブリッジが一度も疎通されない**。
    /// I/O の引数なので純粋関数からは踏めない(欠陥①(b))
    func testLiveBridgeScanIsGivenTheRepoRoot() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ftester-mcp/DeviceInventory.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("repoRoot: nil"),
                       "ブリッジ走査が repoRoot: nil のまま —— lan の実機ブリッジに到達できない")
        XCTAssertTrue(source.contains("BridgeDiscovery.scan(excluding: 0, repoRoot: try? RepoRoot.find())"),
                      "走査へ repoRoot が渡されていない")
    }

    // MARK: - 欠陥⑥ devicesText が abbreviated へその回の理由を渡すこと

    /// **`abbreviated` はその回の reason を受け取れる**(欠陥⑥): 呼び出し側が畳む鍵を理由込みに
    /// できるのは、devicesText がここで理由を渡しているから。鍵を理由に依存させない実装へ戻ると、
    /// このクロージャは常に同じ(または空の)引数しか受け取れなくなる
    func testDevicesTextPassesTheFallbackReasonToAbbreviated() async {
        let missing = "no-such-project-for-device-inventory-reason-test"
        var received: [String] = []
        _ = await DeviceInventory.devicesText(project: missing, profile: nil, platform: nil,
                                              abbreviated: { reason in received.append(reason); return false })
        XCTAssertEqual(received.count, 1, "abbreviated が想定回数呼ばれていない: \(received)")
        XCTAssertTrue(received.first?.contains(missing) ?? false,
                      "abbreviated へ渡された理由にプロジェクト名が無い: \(received)")
    }

    /// abbreviated が true を返せば見出しは短縮形になる(devicesText 側は引数をそのまま使うだけ)
    func testDevicesTextHonoursAbbreviatedReturningTrue() async {
        let text = await DeviceInventory.devicesText(
            project: "no-such-project-for-device-inventory-reason-test", profile: nil, platform: nil,
            abbreviated: { _ in true })
        XCTAssertTrue(text.contains("reason given in the first ft_list_devices"), text)
    }
}
