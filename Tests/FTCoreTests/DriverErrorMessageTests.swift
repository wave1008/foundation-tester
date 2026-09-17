// DriverError.errorDescription は構成(プラットフォーム込みのエンジン・実機か)ごとに
// その構成で起こりうる原因だけを並べる(DriverErrorContext/DriverErrorMessage 参照)。
//
// 2026-09-16 の負荷テストで実際に踏んだ2件:
// - Android エミュレータの adb 断に iOS inapp/hybrid 向けの案内(「シミュレータ専用」)が付いた
// - iOS xcuitest ランナーを外から殺した接続拒否で「アプリが落ちた」が第一容疑にされた
//   (xcuitest はアプリと別プロセスなので的外れ)

import XCTest
@testable import FTCore

final class DriverErrorMessageTests: XCTestCase {

    private let iosInAppSimulator = DriverErrorContext(engine: .iosInApp, physicalDevice: false)
    private let iosXCUITestSimulator = DriverErrorContext(engine: .iosXCUITest, physicalDevice: false)
    private let iosXCUITestPhysical = DriverErrorContext(engine: .iosXCUITest, physicalDevice: true)
    private let androidEmulator = DriverErrorContext(engine: .android, physicalDevice: false)
    private let androidPhysical = DriverErrorContext(engine: .android, physicalDevice: true)

    // MARK: - unreachable: 構成ごとの文面を等号固定する

    func testUnreachableIOSInAppSimulator() {
        let text = DriverErrorMessage.unreachable(context: iosInAppSimulator, detail: "connection refused")
        XCTAssertEqual(text,
            "Cannot reach the driver (not running, or slow to respond). In hybrid/mixed runs the"
                + " backgrounded app can be suspended, so TCP is accepted but no HTTP response comes"
                + " back. Check: fleetest bridge up."
                + " connection refused")
    }

    func testUnreachableIOSXCUITestPhysical() {
        let text = DriverErrorMessage.unreachable(context: iosXCUITestPhysical, detail: "timed out")
        XCTAssertEqual(text,
            "Cannot reach the driver (not running, or slow to respond)."
                + " Check: fleetest bridge up. timed out")
    }

    func testUnreachableAndroidEmulator() {
        let text = DriverErrorMessage.unreachable(context: androidEmulator,
                                                   detail: "adb forward failed: adb: device offline")
        XCTAssertEqual(text,
            "Cannot reach the driver (not running, or slow to respond). Check: adb devices,"
                + " `fleetest doctor`, or try `fleetest bridge up --platform android`."
                + " adb forward failed: adb: device offline")
    }

    func testUnreachableAndroidPhysical() {
        let text = DriverErrorMessage.unreachable(context: androidPhysical,
                                                   detail: "adb forward failed: adb: device offline")
        XCTAssertEqual(text,
            "Cannot reach the driver (not running, or slow to respond). Check: adb devices,"
                + " `fleetest doctor`, or try `fleetest bridge up --platform android`."
                + " adb forward failed: adb: device offline")
    }

    /// **Android の文面には "xcuitest" も "inapp"/"hybrid" も出ない**(2026-09-16 に実際に踏んだ
    /// 事故: Android の一時的な adb 断に iOS 向けの案内が付いた)
    func testAndroidUnreachableMessagesNeverMentionIOSEngines() {
        for context in [androidEmulator, androidPhysical] {
            let text = DriverErrorMessage.unreachable(context: context, detail: "device offline")
            XCTAssertFalse(text.lowercased().contains("xcuitest"), text)
            XCTAssertFalse(text.lowercased().contains("inapp"), text)
            XCTAssertFalse(text.lowercased().contains("hybrid"), text)
        }
    }

    // MARK: - connectionRefused: 構成ごとの文面を等号固定する

    func testConnectionRefusedIOSInApp() {
        let text = DriverErrorMessage.connectionRefused(context: iosInAppSimulator, detail: "refused")
        XCTAssertEqual(text,
            "Connection to the driver was refused (nothing listening on the port). If this happened"
                + " mid-run, the app under test most likely exited or crashed (on iOS inapp the bridge"
                + " lives inside the app, so it becomes unreachable the moment the app dies)."
                + " If the app has not been started yet, check: fleetest bridge up. Detail: refused")
    }

    func testConnectionRefusedIOSXCUITestPhysical() {
        let text = DriverErrorMessage.connectionRefused(context: iosXCUITestPhysical, detail: "refused")
        XCTAssertEqual(text,
            "Connection to the driver was refused (nothing listening on the port). If this happened"
                + " mid-run, the XCUITest runner most likely stopped, or the physical device"
                + " disconnected (USB/Wi-Fi) — on xcuitest the bridge runs in a separate process from"
                + " the app under test, so a crashed app alone would not explain this."
                + " If the app has not been started yet, check: fleetest bridge up. Detail: refused")
    }

    func testConnectionRefusedIOSXCUITestSimulator() {
        let text = DriverErrorMessage.connectionRefused(context: iosXCUITestSimulator, detail: "refused")
        XCTAssertEqual(text,
            "Connection to the driver was refused (nothing listening on the port). If this happened"
                + " mid-run, the XCUITest runner most likely stopped (on xcuitest the bridge runs in a"
                + " separate process from the app under test, so a crashed app alone would not explain"
                + " this). If the app has not been started yet, check: fleetest bridge up. Detail: refused")
    }

    func testConnectionRefusedAndroidEmulator() {
        let text = DriverErrorMessage.connectionRefused(context: androidEmulator, detail: "refused")
        XCTAssertEqual(text,
            "Connection to the driver was refused (nothing listening on the port). If this happened"
                + " mid-run, the Android bridge (a separate instrumentation process) most likely"
                + " stopped — it does not live inside the app under test. If the app has not been"
                + " started yet, check: adb devices. Detail: refused")
    }

    func testConnectionRefusedAndroidPhysical() {
        let text = DriverErrorMessage.connectionRefused(context: androidPhysical, detail: "refused")
        XCTAssertEqual(text,
            "Connection to the driver was refused (nothing listening on the port). If this happened"
                + " mid-run, the Android bridge (a separate instrumentation process) most likely"
                + " stopped — it does not live inside the app under test. If the app has not been"
                + " started yet, check: adb devices. Detail: refused")
    }

    /// **xcuitest の接続拒否では「アプリが落ちた」を第一容疑にしない**(2026-09-16 に実際に踏んだ:
    /// iOS 実機の xcuitest ランナーを外から殺したときにこの文言が出て誤誘導した)。
    /// xcuitest はブリッジがアプリと別プロセスなので、inapp 専用の説明を出してはいけない
    func testXCUITestConnectionRefusedDoesNotBlameTheAppFirst() {
        for context in [iosXCUITestSimulator, iosXCUITestPhysical] {
            let text = DriverErrorMessage.connectionRefused(context: context, detail: "refused")
            XCTAssertFalse(text.contains("app under test most likely exited or crashed"), text)
            XCTAssertTrue(text.contains("XCUITest runner most likely stopped"), text)
        }
    }

    /// **Android の接続拒否の文面にも "xcuitest" は出ない**
    func testAndroidConnectionRefusedNeverMentionsXCUITest() {
        for context in [androidEmulator, androidPhysical] {
            let text = DriverErrorMessage.connectionRefused(context: context, detail: "refused")
            XCTAssertFalse(text.lowercased().contains("xcuitest"), text)
        }
    }

    // MARK: - DriverError.errorDescription 経由でも同じ文面が出る(配線の固定)

    func testDriverErrorErrorDescriptionDelegatesToDriverErrorMessage() {
        let unreachable = DriverError.bridgeUnreachable(context: androidEmulator, detail: "device offline")
        XCTAssertEqual(unreachable.errorDescription,
                       DriverErrorMessage.unreachable(context: androidEmulator, detail: "device offline"))

        let refused = DriverError.bridgeConnectionRefused(context: iosXCUITestPhysical, detail: "refused")
        XCTAssertEqual(refused.errorDescription,
                       DriverErrorMessage.connectionRefused(context: iosXCUITestPhysical, detail: "refused"))
    }
}
