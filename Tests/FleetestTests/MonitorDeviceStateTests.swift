// デバイスモニターの状態判定(`fleetest api monitor`)。
// connected/booted/offline はモニタータイルの表示・ブリッジ自動修復ウォッチドッグ・
// ライブ操作の可否をすべて駆動する。誤ると「タイルが点滅する」「実機が永久に offline」という
// 形で出るが、シナリオ実行は成功するため E2E では捕まらない。
// determineStates 本体はカタログ照会と HTTP を伴うので対象外。ここは副作用の無い判定部分だけ。

import XCTest
import FTAndroid
import FTBridgeClient
import FTCore
@testable import fleetest

final class MonitorDeviceStateTests: XCTestCase {

    // MARK: - fixtures

    private func emulator(name: String = "エミュ1", avd: String? = "Pixel_9_Android_15_-01") -> MonitorTarget {
        MonitorTarget(platform: "android", spec: DeviceSpec(name: name, avd: avd))
    }

    private func physical(name: String = "実機1", serial: String?) -> MonitorTarget {
        MonitorTarget(platform: "android", spec: DeviceSpec(name: name, kind: .physical, serial: serial))
    }

    private func state(_ target: MonitorTarget, runningAVDs: [String: String] = [:],
                       connectedSerials: Set<String> = [], bootCompleted: [String: Bool] = [:]
    ) -> DeviceRuntimeState {
        ApiMonitorCommand.androidState(target: target, runningAVDs: runningAVDs,
                                       connectedSerials: connectedSerials, bootCompleted: bootCompleted)
    }

    // MARK: - androidState: エミュレータ

    func testEmulatorIsConnectedWhenRunningAndBooted() {
        let result = state(emulator(),
                           runningAVDs: ["emulator-5554": "Pixel_9_Android_15_-01"],
                           bootCompleted: ["emulator-5554": true])
        XCTAssertEqual(result.state, "connected")
        XCTAssertEqual(result.androidSerial, "emulator-5554",
                       "connected のときだけ serial を載せる(スクショ取得に使う)")
        XCTAssertEqual(result.detail, "emulator-5554")
    }

    func testEmulatorIsBootedWhileBootNotCompleted() {
        // ブート未完了で connected にすると、パッケージマネージャ未起動のままブリッジ APK の
        // 自動インストールを試みて失敗する
        let result = state(emulator(),
                           runningAVDs: ["emulator-5554": "Pixel_9_Android_15_-01"],
                           bootCompleted: ["emulator-5554": false])
        XCTAssertEqual(result.state, "booted")
        XCTAssertNil(result.androidSerial, "booted では serial を載せない")
    }

    func testEmulatorIsBootedWhenBootStatusUnknown() {
        // getprop が取れなかった場合(キー欠落)も connected に昇格させない
        let result = state(emulator(), runningAVDs: ["emulator-5554": "Pixel_9_Android_15_-01"])
        XCTAssertEqual(result.state, "booted")
    }

    func testEmulatorIsOfflineWhenNotRunning() {
        let result = state(emulator(), runningAVDs: ["emulator-5554": "別の_AVD"])
        XCTAssertEqual(result.state, "offline")
        XCTAssertEqual(result.detail, "", "未起動は理由を書かない(拡張の契約は detail: string 固定)")
    }

    func testEmulatorWithoutAVDIsOfflineWithReason() {
        let result = state(emulator(avd: nil))
        XCTAssertEqual(result.state, "offline")
        XCTAssertEqual(result.detail, "avd is not set")
    }

    func testEmulatorMatchesAVDByCanonicalID() {
        // ~/.android/avd の孤児 .avd 等で表記が揺れるため、照合は canonical 化した ID で行う
        let canonical = AndroidDeviceCatalog.canonicalAVDID("Pixel_9_Android_15_-01")
        let result = state(emulator(), runningAVDs: ["emulator-5554": canonical],
                           bootCompleted: ["emulator-5554": true])
        XCTAssertEqual(result.state, "connected")
    }

    // MARK: - androidState: 実機

    func testPhysicalDeviceUsesSerialNotAVD() {
        // 実機は AVD を持たない。avd 前提のままだと永久に「avd が未設定です」で offline になる
        let result = state(physical(serial: "R5CT30ABCDE"),
                           connectedSerials: ["R5CT30ABCDE"],
                           bootCompleted: ["R5CT30ABCDE": true])
        XCTAssertEqual(result.state, "connected")
        XCTAssertEqual(result.androidSerial, "R5CT30ABCDE")
    }

    func testPhysicalDeviceOfflineWhenNotVisibleToADB() {
        let result = state(physical(serial: "R5CT30ABCDE"), connectedSerials: [])
        XCTAssertEqual(result.state, "offline")
        XCTAssertTrue(result.detail.contains("adb"), "対処が分かる理由を出すこと: \(result.detail)")
    }

    func testPhysicalDeviceWithoutSerialReportsMissingSerial() {
        let result = state(physical(serial: nil))
        XCTAssertEqual(result.state, "offline")
        XCTAssertEqual(result.detail, "serial is not set")
    }

    func testPhysicalDeviceIsBootedUntilBootCompleted() {
        let result = state(physical(serial: "R5CT30ABCDE"), connectedSerials: ["R5CT30ABCDE"])
        XCTAssertEqual(result.state, "booted")
    }

    // MARK: - debounce

    private func observed(_ target: MonitorTarget, _ state: String,
                          serial: String? = nil, port: UInt16? = nil,
                          udid: String? = nil) -> DeviceRuntimeState {
        DeviceRuntimeState(target: target, state: state, detail: state == "connected" ? (serial ?? "") : "",
                           iosPort: port, androidSerial: serial, iosUdid: udid)
    }

    private func debounced(_ states: [DeviceRuntimeState],
                           confirmed: inout [String: ConfirmedDeviceState],
                           downgrades: inout [String]) -> [DeviceRuntimeState] {
        var collected: [String] = []
        let result = ApiMonitorCommand.debounce(states, confirmed: &confirmed,
                                                onDowngrade: { collected.append($0) })
        downgrades += collected
        return result
    }

    func testPromotionToConnectedIsImmediate() {
        let target = emulator()
        var confirmed: [String: ConfirmedDeviceState] = [:]
        var downgrades: [String] = []
        let result = debounced([observed(target, "connected", serial: "emulator-5554")],
                               confirmed: &confirmed, downgrades: &downgrades)
        XCTAssertEqual(result.first?.state, "connected", "昇格は即時(待たせるとタイルが遅れる)")
        XCTAssertTrue(downgrades.isEmpty)
    }

    func testDowngradeFromConnectedRequiresConsecutiveMisses() {
        // /status の一過性の失敗でタイルを落とすと点滅する。閾値回まで connected を維持する
        let target = emulator()
        var confirmed: [String: ConfirmedDeviceState] = [:]
        var downgrades: [String] = []
        _ = debounced([observed(target, "connected", serial: "emulator-5554")],
                      confirmed: &confirmed, downgrades: &downgrades)

        let threshold = ApiMonitorCommand.connectedDowngradeMissThreshold
        for miss in 1..<threshold {
            let result = debounced([observed(target, "booted")],
                                   confirmed: &confirmed, downgrades: &downgrades)
            XCTAssertEqual(result.first?.state, "connected", "\(miss) 回目の失敗では降格しない")
            XCTAssertEqual(result.first?.androidSerial, "emulator-5554",
                           "維持中も接続情報を持ち越す(スクショ取得を試み続けるため)")
            XCTAssertTrue(downgrades.isEmpty)
        }

        let final = debounced([observed(target, "booted")],
                              confirmed: &confirmed, downgrades: &downgrades)
        XCTAssertEqual(final.first?.state, "booted", "閾値到達で降格する")
        XCTAssertEqual(downgrades.count, 1, "降格はログに残す")
    }

    func testMissStreakResetsOnRecovery() {
        // 失敗が連続しない限り降格させない(閾値未満で回復したら数え直し)
        let target = emulator()
        var confirmed: [String: ConfirmedDeviceState] = [:]
        var downgrades: [String] = []
        _ = debounced([observed(target, "connected", serial: "emulator-5554")],
                      confirmed: &confirmed, downgrades: &downgrades)
        _ = debounced([observed(target, "booted")], confirmed: &confirmed, downgrades: &downgrades)
        _ = debounced([observed(target, "connected", serial: "emulator-5554")],
                      confirmed: &confirmed, downgrades: &downgrades)

        for _ in 1..<ApiMonitorCommand.connectedDowngradeMissThreshold {
            let result = debounced([observed(target, "booted")],
                                   confirmed: &confirmed, downgrades: &downgrades)
            XCTAssertEqual(result.first?.state, "connected")
        }
        XCTAssertTrue(downgrades.isEmpty, "回復を挟んだので降格しない")
    }

    func testDebouncePreservesIOSUdidWhileHolding() {
        // iosUdid を持ち越さないと leaseKey が nil になり inRun/recording が false に振れる
        let target = MonitorTarget(platform: "ios", spec: DeviceSpec(name: "シミュ1"))
        var confirmed: [String: ConfirmedDeviceState] = [:]
        var downgrades: [String] = []
        _ = debounced([observed(target, "connected", port: 8123, udid: "UDID-1")],
                      confirmed: &confirmed, downgrades: &downgrades)

        let held = debounced([observed(target, "offline")],
                             confirmed: &confirmed, downgrades: &downgrades)
        XCTAssertEqual(held.first?.state, "connected")
        XCTAssertEqual(held.first?.iosUdid, "UDID-1")
        XCTAssertEqual(held.first?.iosPort, 8123)
    }

    func testTransitionsBetweenBootedAndOfflineAreImmediate() {
        // connected を経由しない遷移は debounce しない(そのまま反映)
        let target = emulator()
        var confirmed: [String: ConfirmedDeviceState] = [:]
        var downgrades: [String] = []
        XCTAssertEqual(debounced([observed(target, "booted")],
                                 confirmed: &confirmed, downgrades: &downgrades).first?.state, "booted")
        XCTAssertEqual(debounced([observed(target, "offline")],
                                 confirmed: &confirmed, downgrades: &downgrades).first?.state, "offline")
        XCTAssertTrue(downgrades.isEmpty)
    }

    func testDebounceTracksDevicesIndependently() {
        let a = emulator(name: "エミュ1")
        let b = emulator(name: "エミュ2")
        var confirmed: [String: ConfirmedDeviceState] = [:]
        var downgrades: [String] = []
        _ = debounced([observed(a, "connected", serial: "emulator-5554"),
                       observed(b, "connected", serial: "emulator-5556")],
                      confirmed: &confirmed, downgrades: &downgrades)

        // a だけが落ちる。b の維持カウントに影響してはいけない
        for _ in 0..<ApiMonitorCommand.connectedDowngradeMissThreshold {
            _ = debounced([observed(a, "offline"), observed(b, "connected", serial: "emulator-5556")],
                          confirmed: &confirmed, downgrades: &downgrades)
        }
        let result = debounced([observed(a, "offline"), observed(b, "connected", serial: "emulator-5556")],
                               confirmed: &confirmed, downgrades: &downgrades)
        XCTAssertEqual(result.first(where: { $0.target.id == a.id })?.state, "offline")
        XCTAssertEqual(result.first(where: { $0.target.id == b.id })?.state, "connected")
        XCTAssertEqual(downgrades.count, 1, "降格したのは a だけ")
    }

    // MARK: - unregisteredStates(「(起動中のデバイス)」でマシンプロファイル未記載機を表示するための合成)

    private func sim(udid: String, name: String = "野良シム", os: String = "iOS 18.0",
                     booted: Bool = true, physical: Bool = false) -> SimDeviceInfo {
        SimDeviceInfo(udid: udid, name: name, os: os, booted: booted, physical: physical)
    }

    func testUnregisteredBootedSimulatorIsSynthesizedAsConnected() {
        let (states, skipped) = ApiMonitorCommand.unregisteredStates(
            simCatalog: [sim(udid: "UDID-A")], runningAVDs: [:], bootCompleted: [:],
            registeredTargets: [], registeredIosUdids: [])
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(states.count, 1)
        let state = states[0]
        XCTAssertEqual(state.state, "connected",
                       "simstream は udid だけで動く(ブリッジ不要)ので booted のまま止めない")
        XCTAssertEqual(state.detail, "unregistered")
        XCTAssertEqual(state.iosUdid, "UDID-A")
        XCTAssertNil(state.iosPort, "未登録シミュレータにブリッジは無い")
        XCTAssertFalse(state.target.registered)
        XCTAssertEqual(state.target.name, "野良シム")
    }

    func testRegisteredSimulatorUdidIsNotSynthesized() {
        let (states, _) = ApiMonitorCommand.unregisteredStates(
            simCatalog: [sim(udid: "UDID-A")], runningAVDs: [:], bootCompleted: [:],
            registeredTargets: [], registeredIosUdids: ["UDID-A"])
        XCTAssertTrue(states.isEmpty)
    }

    func testUnbootedAndPhysicalSimulatorsAreIgnored() {
        let (states, _) = ApiMonitorCommand.unregisteredStates(
            simCatalog: [sim(udid: "UDID-A", booted: false), sim(udid: "UDID-B", physical: true)],
            runningAVDs: [:], bootCompleted: [:],
            registeredTargets: [], registeredIosUdids: [])
        XCTAssertTrue(states.isEmpty,
                      "未起動と、simctl が並べる実機の器は対象外(実機は physicalIOS から合成する)")
    }

    // MARK: - 接続中の実機の合成(2026-08-26。「(起動中のデバイス)」で実機が出ず、バッジも付かなかった)

    private func iPhone(udid: String, name: String = "iPhone wave", connected: Bool = true)
        -> IOSPhysicalDeviceInfo {
        IOSPhysicalDeviceInfo(udid: udid, name: name, os: "iOS 26.6.1", connected: connected,
                              transport: "wired", model: "iPhone 15 Pro")
    }

    /// ブリッジが無くても**繋がっている端末は出す**(state は booted = ブリッジ未起動の意味)。
    /// kind=physical が乗らないと拡張の実機バッジが付かない
    func testConnectedIPhoneIsSynthesizedEvenWithoutABridge() {
        let (states, skipped) = ApiMonitorCommand.unregisteredStates(
            simCatalog: [], runningAVDs: [:], bootCompleted: [:],
            registeredTargets: [], registeredIosUdids: [],
            physicalIOS: [iPhone(udid: "UDID-PHONE")])
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].state, "booted", "繋がってはいるがブリッジが無い")
        XCTAssertEqual(states[0].detail, "bridge not running")
        XCTAssertTrue(states[0].target.spec.isPhysical, "実機バッジはこの値で出る")
        XCTAssertEqual(states[0].target.name, "iPhone wave")
        XCTAssertEqual(states[0].iosUdid, "UDID-PHONE")
        XCTAssertFalse(states[0].target.registered)
    }

    /// ブリッジが立っていれば登録済みと同じく connected + port(配信が張れる)
    func testConnectedIPhoneWithABridgeReportsThePort() {
        let (states, _) = ApiMonitorCommand.unregisteredStates(
            simCatalog: [], runningAVDs: [:], bootCompleted: [:],
            registeredTargets: [], registeredIosUdids: [],
            physicalIOS: [iPhone(udid: "UDID-PHONE")], iosBridgePorts: ["UDID-PHONE": 8145])
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].state, "connected")
        XCTAssertEqual(states[0].iosPort, 8145)
    }

    /// 登録済みの実機は合成しない(マシンプロファイル側の名前・ポートで既に並んでいる)
    func testRegisteredIPhoneIsNotSynthesizedTwice() {
        let (states, _) = ApiMonitorCommand.unregisteredStates(
            simCatalog: [], runningAVDs: [:], bootCompleted: [:],
            registeredTargets: [], registeredIosUdids: ["UDID-PHONE"],
            physicalIOS: [iPhone(udid: "UDID-PHONE")])
        XCTAssertTrue(states.isEmpty)
    }

    /// Android 実機は serial で合成し、表示名は ro.product.model(取れなければ serial)
    func testConnectedAndroidPhoneIsSynthesizedWithItsModelName() {
        let (states, _) = ApiMonitorCommand.unregisteredStates(
            simCatalog: [], runningAVDs: [:], bootCompleted: ["93MAY0CY1M": true],
            registeredTargets: [], registeredIosUdids: [],
            connectedPhysicalSerials: ["93MAY0CY1M", "ZY22H8LNCT"],
            androidPhysicalNames: ["93MAY0CY1M": "Pixel 3a", "ZY22H8LNCT": ""])
        XCTAssertEqual(states.map(\.target.name), ["Pixel 3a", "ZY22H8LNCT"],
                       "serial 昇順(辞書の順序に任せない)。名前が取れなければ serial を使う")
        XCTAssertEqual(states.map(\.state), ["connected", "booted"],
                       "ブート完了だけ connected(未完了はブリッジ APK の自動導入に進ませない)")
        XCTAssertTrue(states.allSatisfy { $0.target.spec.isPhysical })
    }

    /// 登録済みの Android 実機(serial 一致)は合成しない
    func testRegisteredAndroidPhoneIsNotSynthesizedTwice() {
        let registered = MonitorTarget(
            platform: "android",
            spec: DeviceSpec(name: "Pixel 3a", kind: .physical, serial: "93MAY0CY1M"))
        let (states, _) = ApiMonitorCommand.unregisteredStates(
            simCatalog: [], runningAVDs: [:], bootCompleted: ["93MAY0CY1M": true],
            registeredTargets: [registered], registeredIosUdids: [],
            connectedPhysicalSerials: ["93MAY0CY1M"], androidPhysicalNames: [:])
        XCTAssertTrue(states.isEmpty)
    }

    func testUnregisteredRunningAVDBecomesConnectedWhenBootCompleted() {
        let (states, skipped) = ApiMonitorCommand.unregisteredStates(
            simCatalog: [], runningAVDs: ["emulator-5556": "Pixel_9_Android_16_-02"],
            bootCompleted: ["emulator-5556": true],
            registeredTargets: [], registeredIosUdids: [])
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].state, "connected")
        XCTAssertEqual(states[0].androidSerial, "emulator-5556")
        XCTAssertFalse(states[0].target.registered)
        XCTAssertEqual(states[0].target.spec.avd, "Pixel_9_Android_16_-02")
    }

    func testUnregisteredRunningAVDStaysBootedUntilBootCompleted() {
        // 加えて呼び出し側(determineStates)が起動中の未登録 AVD の serial を boot-completed
        // スキャン対象へ加えないと、この bootCompleted が永久に埋まらず booted のまま固まる
        let (states, _) = ApiMonitorCommand.unregisteredStates(
            simCatalog: [], runningAVDs: ["emulator-5556": "Pixel_9_Android_16_-02"],
            bootCompleted: ["emulator-5556": false],
            registeredTargets: [], registeredIosUdids: [])
        XCTAssertEqual(states.first?.state, "booted")
        XCTAssertNil(states.first?.androidSerial, "booted では serial を載せない(androidState と同じ規約)")
        XCTAssertEqual(states.first?.detail, "waiting for boot to finish (emulator-5556)")
    }

    func testRegisteredAVDIsNotSynthesized() {
        let registered = emulator(avd: "Pixel_9_Android_15_-01")
        let (states, _) = ApiMonitorCommand.unregisteredStates(
            simCatalog: [], runningAVDs: ["emulator-5554": "Pixel_9_Android_15_-01"],
            bootCompleted: ["emulator-5554": true],
            registeredTargets: [registered], registeredIosUdids: [])
        XCTAssertTrue(states.isEmpty)
    }

    func testIdCollisionWithRegisteredTargetSkipsTheSimulator() {
        // 登録済みターゲットが同名の iOS デバイスを持つ場合、合成 id "ios:野良シム" が衝突するため
        // スキップする(拡張側は id をキーに devices を Map 管理するため、重複 id は表示が壊れる)
        let registered = MonitorTarget(platform: "ios", spec: DeviceSpec(name: "野良シム"))
        let (states, skipped) = ApiMonitorCommand.unregisteredStates(
            simCatalog: [sim(udid: "UDID-A")], runningAVDs: [:], bootCompleted: [:],
            registeredTargets: [registered], registeredIosUdids: [])
        XCTAssertTrue(states.isEmpty)
        XCTAssertEqual(skipped.count, 1)
        XCTAssertTrue(skipped[0].contains("ios:野良シム"), "スキップ理由に衝突した id を含めること: \(skipped[0])")
    }

    func testDuplicateNamedUnregisteredSimulatorsAreDisambiguatedByUdidPrefix() {
        let (states, skipped) = ApiMonitorCommand.unregisteredStates(
            simCatalog: [
                sim(udid: "AAAAAAAA-1111-0000-0000-000000000000", name: "同名シム"),
                sim(udid: "BBBBBBBB-2222-0000-0000-000000000000", name: "同名シム"),
            ],
            runningAVDs: [:], bootCompleted: [:],
            registeredTargets: [], registeredIosUdids: [])
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(states.count, 2)
        let names = Set(states.map { $0.target.name })
        XCTAssertEqual(names, ["同名シム [AAAAAAAA]", "同名シム [BBBBBBBB]"])
    }
}

// MARK: - タイル識別子(ホストを含む)

/// タイル・ストリーミングの識別子は拡張側で Map のキーになる。**同名が別の機械に居るのは通常**
/// (一意なのは (host, name))なので、ホストを含めないと複数のデバイスが1タイルに潰れる
/// (2026-08-17 の実害: 12台のプロファイルが6タイルになった)。
final class MonitorTargetIDTests: XCTestCase {

    func testLocalDeviceKeepsTheHostlessForm() {
        let target = MonitorTarget(platform: "ios", spec: DeviceSpec(name: "iPhone-01"))
        XCTAssertEqual(target.id, "ios:iPhone-01")
    }

    func testRemoteDeviceIncludesTheHost() {
        let target = MonitorTarget(platform: "ios",
                                   spec: DeviceSpec(name: "iPhone-01", machine: "M1Ultra"))
        XCTAssertEqual(target.id, "ios:M1Ultra/iPhone-01")
    }

    func testSameNameOnDifferentHostsGetsDistinctIDs() {
        let ids = ["local", "M1Max", "M1Ultra"].map { host -> String in
            MonitorTarget(platform: "android",
                          spec: DeviceSpec(name: "Pixel-01", machine: host)).id
        }
        XCTAssertEqual(Set(ids).count, 3, "\(ids)")
    }
}

// MARK: - 実機一覧のキャッシュ(毎サイクル devicectl/adb を叩かないための TTL 判定)

extension MonitorDeviceStateTests {
    private func inventory(names: [String: String], ageSeconds: TimeInterval, now: Date)
        -> ApiMonitorCommand.PhysicalInventory {
        ApiMonitorCommand.PhysicalInventory(
            ios: [], androidNames: names, takenAt: now.addingTimeInterval(-ageSeconds))
    }

    func testInventoryIsRefetchedWhenThereIsNoCacheOrTheTTLExpired() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(ApiMonitorCommand.needsRefresh(cache: nil, serials: [], now: now))
        XCTAssertTrue(ApiMonitorCommand.needsRefresh(
            cache: inventory(names: [:], ageSeconds: ApiMonitorCommand.physicalInventoryTTLSeconds, now: now),
            serials: [], now: now))
        XCTAssertFalse(ApiMonitorCommand.needsRefresh(
            cache: inventory(names: [:], ageSeconds: 1, now: now), serials: [], now: now),
            "TTL 内は引き直さない(devicectl/adb は 0.5〜1 秒。2 秒周期には重い)")
    }

    /// **新しく繋いだ端末は TTL を待たない** —— 待つと「繋いだのに 30 秒出てこない」になる
    func testInventoryIsRefetchedWhenAnUnknownSerialAppears() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cache = inventory(names: ["93MAY0CY1M": "Pixel 3a"], ageSeconds: 1, now: now)
        XCTAssertTrue(ApiMonitorCommand.needsRefresh(
            cache: cache, serials: ["93MAY0CY1M", "14141JEC204922"], now: now))
        XCTAssertFalse(ApiMonitorCommand.needsRefresh(
            cache: cache, serials: ["93MAY0CY1M"], now: now))
        XCTAssertFalse(ApiMonitorCommand.needsRefresh(cache: cache, serials: [], now: now),
                       "端末が抜けただけなら次の TTL まで待ってよい(消えるのは一覧側で分かる)")
    }
}
