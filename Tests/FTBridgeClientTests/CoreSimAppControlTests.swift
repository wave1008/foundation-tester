// CoreSimulator 直叩き(FTCoreSimShim)によるインストール確認と、simctl get_app_container の
// 等価性検証。実マシンの CoreSimulator/simctl に触れるため FT_LIVE_SIM=1 のときのみ実行(CI では走らない)。
// SimulatorCatalogCoreSimTests.swift と同じ作法(シム利用不能なら XCTSkip)。

import XCTest
@testable import FTBridgeClient
import FTCore

final class CoreSimAppControlTests: XCTestCase {

    /// com.apple.springboard は全 iOS シミュレータに常駐する(SystemUIDriver が既に依拠している契約)
    private static let installedBundleID = "com.apple.springboard"
    private static let missingBundleID = "com.foundationtester.definitely-not-installed"

    private func bootedUDID() throws -> String {
        let devices = try SimulatorCatalog.devicesViaSimctl()
        guard let udid = devices.first(where: { $0.booted })?.udid else {
            throw XCTSkip("起動中のシミュレータが無い")
        }
        return udid
    }

    private func requireShim() throws -> String {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FT_LIVE_SIM"] == "1",
                          "FT_LIVE_SIM=1 のときのみ")
        let udid = try bootedUDID()
        guard CoreSimAppControl.isInstalled(udid: udid, bundleID: Self.installedBundleID) != nil else {
            throw XCTSkip("CoreSimulator シム利用不能(この環境では simctl フォールバックのみ)")
        }
        return udid
    }

    private func isInstalledViaSimctl(udid: String, bundleID: String) throws -> Bool {
        let result = try Shell.run(["xcrun", "simctl", "get_app_container", udid, bundleID])
        return result.status == 0
            && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func testInstalledAppMatchesSimctl() throws {
        let udid = try requireShim()
        let viaShim = CoreSimAppControl.isInstalled(udid: udid, bundleID: Self.installedBundleID)
        let viaSimctl = try isInstalledViaSimctl(udid: udid, bundleID: Self.installedBundleID)
        XCTAssertEqual(viaShim, viaSimctl)
        XCTAssertEqual(viaShim, true)
    }

    func testMissingAppMatchesSimctl() throws {
        let udid = try requireShim()
        let viaShim = CoreSimAppControl.isInstalled(udid: udid, bundleID: Self.missingBundleID)
        let viaSimctl = try isInstalledViaSimctl(udid: udid, bundleID: Self.missingBundleID)
        XCTAssertEqual(viaShim, viaSimctl)
        XCTAssertEqual(viaShim, false)
    }

    /// 2回目以降の確認が simctl より速いこと(初回は dlopen+ctx 初期化を含むため除外)
    func testCoreSimIsFasterThanSimctl() throws {
        let udid = try requireShim()
        _ = CoreSimAppControl.isInstalled(udid: udid, bundleID: Self.installedBundleID)
        let t0 = Date()
        _ = CoreSimAppControl.isInstalled(udid: udid, bundleID: Self.installedBundleID)
        let shimSec = Date().timeIntervalSince(t0)
        let t1 = Date()
        _ = try isInstalledViaSimctl(udid: udid, bundleID: Self.installedBundleID)
        let simctlSec = Date().timeIntervalSince(t1)
        XCTAssertLessThan(shimSec, simctlSec,
                          "shim \(shimSec * 1000)ms >= simctl \(simctlSec * 1000)ms")
    }
}
