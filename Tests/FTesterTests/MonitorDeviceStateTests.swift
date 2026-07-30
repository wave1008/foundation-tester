// デバイスモニターの状態判定(`ftester api monitor`)。
// connected/booted/offline はモニタータイルの表示・ブリッジ自動修復ウォッチドッグ・
// ライブ操作の可否をすべて駆動する。誤ると「タイルが点滅する」「実機が永久に offline」という
// 形で出るが、シナリオ実行は成功するため E2E では捕まらない。
// determineStates 本体はカタログ照会と HTTP を伴うので対象外。ここは副作用の無い判定部分だけ。

import XCTest
import FTAndroid
import FTCore
@testable import ftester

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
}
