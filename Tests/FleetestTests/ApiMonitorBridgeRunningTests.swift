// Android 実機のタイルに「ブリッジ未起動」を出すための `ApiMonitorDeviceInfo.bridgeRunning` 配線。
// iOS 実機は state==="booted" で「端末はあるがブリッジが無い」を表せるが、Android の state は
// 「adb に見えるか」「ブート完了か」しか表さずブリッジの有無とは無関係(コメント参照:
// ApiMonitorCommand.androidState)。だから専用の欄を持ち、`shouldProbeBridge` が対象を
// Android 実機の connected だけに絞る。

import FTCore
import XCTest

@testable import fleetest

final class ApiMonitorBridgeRunningTests: XCTestCase {

    private func androidPhysicalTarget(serial: String = "14141JEC204922") -> MonitorTarget {
        var spec = DeviceSpec(name: "Pixel 実機")
        spec.kind = .physical
        spec.serial = serial
        return MonitorTarget(platform: "android", spec: spec)
    }

    private func iosPhysicalTarget() -> MonitorTarget {
        var spec = DeviceSpec(name: "iPhone 実機")
        spec.kind = .physical
        spec.udid = "00008130-001819863E60001C"
        return MonitorTarget(platform: "ios", spec: spec)
    }

    private func androidVirtualTarget() -> MonitorTarget {
        let spec = DeviceSpec(name: "エミュ1")
        return MonitorTarget(platform: "android", spec: spec)
    }

    // MARK: - shouldProbeBridge

    func testAndroidPhysicalConnectedShouldProbe() {
        let state = DeviceRuntimeState(target: androidPhysicalTarget(), state: "connected", detail: "",
                                       iosPort: nil, androidSerial: "14141JEC204922")
        XCTAssertTrue(ApiMonitorCommand.shouldProbeBridge(state: state))
    }

    func testAndroidPhysicalNotConnectedDoesNotProbe() {
        for state in ["booted", "offline", "unknown"] {
            let s = DeviceRuntimeState(target: androidPhysicalTarget(), state: state, detail: "",
                                       iosPort: nil, androidSerial: nil)
            XCTAssertFalse(ApiMonitorCommand.shouldProbeBridge(state: s),
                           "state=\(state) は connected ではないので観測対象にしない")
        }
    }

    func testIOSPhysicalConnectedDoesNotProbe() {
        // iOS 実機は既存の state==="booted" 規則(deviceTiles.js の bridgeNotRunning)が担う。
        // ここで true にすると同じ意味の判定が2箇所に割れる
        let state = DeviceRuntimeState(target: iosPhysicalTarget(), state: "connected", detail: "",
                                       iosPort: 8134, androidSerial: nil)
        XCTAssertFalse(ApiMonitorCommand.shouldProbeBridge(state: state))
    }

    func testAndroidVirtualConnectedDoesNotProbe() {
        // エミュレータは一括終了で端末ごと消えるため「端末はあるがブリッジが無い」がほぼ起きない
        // (CLAUDE.md の決定どおり実機限定に絞る)
        let state = DeviceRuntimeState(target: androidVirtualTarget(), state: "connected", detail: "",
                                       iosPort: nil, androidSerial: "emulator-5554")
        XCTAssertFalse(ApiMonitorCommand.shouldProbeBridge(state: state))
    }

    // MARK: - DeviceRuntimeState.info(bridgeRunning:) の受け渡し

    func testInfoCarriesBridgeRunningThrough() {
        let state = DeviceRuntimeState(target: androidPhysicalTarget(), state: "connected", detail: "",
                                       iosPort: nil, androidSerial: "14141JEC204922")
        XCTAssertEqual(state.info(health: nil, renderMode: nil, inRun: false, recording: false,
                                  bridgeRunning: true).bridgeRunning, true)
        XCTAssertEqual(state.info(health: nil, renderMode: nil, inRun: false, recording: false,
                                  bridgeRunning: false).bridgeRunning, false)
    }

    /// **観測不能(nil)を false に丸めない** —— 呼び手(引数省略)の既定値は nil のまま届く
    func testInfoDefaultsBridgeRunningToNilNotFalse() {
        let state = DeviceRuntimeState(target: androidPhysicalTarget(), state: "connected", detail: "",
                                       iosPort: nil, androidSerial: "14141JEC204922")
        XCTAssertNil(state.info(health: nil, renderMode: nil, inRun: false, recording: false).bridgeRunning)
    }

    func testInfoOnNonAndroidPhysicalIsNilByConstruction() {
        // 呼び出し元(ApiMonitorCommand のループ)は shouldProbeBridge を通った台の serial だけを
        // 引くので、iOS/仮想機には bridgeRunning を渡さない。ここでは「渡さなければ nil のまま」
        // という info() 側の既定を固定する(呼び出し側の絞り込みは shouldProbeBridge のテストで守る)
        let state = DeviceRuntimeState(target: iosPhysicalTarget(), state: "connected", detail: "",
                                       iosPort: 8134, androidSerial: nil)
        XCTAssertNil(state.info(health: nil, renderMode: nil, inRun: false, recording: false).bridgeRunning)
    }
}
