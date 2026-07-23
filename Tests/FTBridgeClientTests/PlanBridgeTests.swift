// planBridge(副作用なし・await なし)の稼働ブリッジ相関を検証する。
// 特に同名 sim 複数 booted で udid が nil に落ちたときの名前フォールバック(二重起動回避)。

import XCTest
import FTCore
@testable import FTBridgeClient

final class PlanBridgeTests: XCTestCase {
    private var repoRoot: URL!

    override func setUpWithError() throws {
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftplanbridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent(".ftester"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func plan(running: [UInt16: BridgeProvisioner.RunningBridge],
                      sim: SimDeviceInfo) throws -> BridgeProvisioner.EnginePlan {
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130)
        var claimed: Set<UInt16> = []
        var used = Set(running.keys)
        return try provisioner.planBridge(
            engine: "xcuitest", preferred: nil, name: sim.name, sim: sim, bundleID: nil,
            appIsCurrent: [:], preinstallAppPath: nil, running: running,
            claimed: &claimed, usedPorts: &used)
    }

    /// 同名 sim 複数 booted で udid=nil に落ちた稼働ブリッジは、名前一致で再利用する(二重起動回避)。
    func testReusesNilUdidBridgeByName() throws {
        let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        let running: [UInt16: BridgeProvisioner.RunningBridge] = [
            8125: .init(udid: nil, name: "iPhone 17 Pro", engine: "xcuitest",
                        protocolVersion: BridgeAPI.bridgeProtocolVersion, sessionBundleID: nil),
        ]
        guard case .reuse(let port) = try plan(running: running, sim: sim) else {
            return XCTFail("nil-udid でも名前一致で reuse するはず")
        }
        XCTAssertEqual(port, 8125)
    }

    /// 名前も一致しない nil-udid ブリッジは再利用せず新規起動(別デバイスを誤って掴まない)。
    func testDoesNotReuseNilUdidWithDifferentName() throws {
        let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        let running: [UInt16: BridgeProvisioner.RunningBridge] = [
            8125: .init(udid: nil, name: "iPad Pro", engine: "xcuitest",
                        protocolVersion: BridgeAPI.bridgeProtocolVersion, sessionBundleID: nil),
        ]
        guard case .launch = try plan(running: running, sim: sim) else {
            return XCTFail("名前不一致は reuse せず launch のはず")
        }
    }

    /// 従来どおり udid 一致は再利用する(名前フォールバックが通常経路を壊さない)。
    func testReusesByUdidWhenPresent() throws {
        let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        let running: [UInt16: BridgeProvisioner.RunningBridge] = [
            8127: .init(udid: "UDID-A", name: "iPhone 17 Pro", engine: "xcuitest",
                        protocolVersion: BridgeAPI.bridgeProtocolVersion, sessionBundleID: nil),
        ]
        guard case .reuse(let port) = try plan(running: running, sim: sim) else {
            return XCTFail("udid 一致は reuse するはず")
        }
        XCTAssertEqual(port, 8127)
    }

    private func planInApp(bundleID: String,
                           running: [UInt16: BridgeProvisioner.RunningBridge],
                           sim: SimDeviceInfo) throws -> BridgeProvisioner.EnginePlan {
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130)
        var claimed: Set<UInt16> = []
        var used = Set(running.keys)
        return try provisioner.planBridge(
            engine: "inapp", preferred: nil, name: sim.name, sim: sim, bundleID: bundleID,
            appIsCurrent: [:], preinstallAppPath: nil, running: running,
            claimed: &claimed, usedPorts: &used)
    }

    /// inapp は注入先アプリ(sessionBundleID)が一致するときだけ再利用する。
    func testInAppReusesOnlyMatchingBundleID() throws {
        let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        let running: [UInt16: BridgeProvisioner.RunningBridge] = [
            8125: .init(udid: "UDID-A", name: "iPhone 17 Pro", engine: "inapp",
                        protocolVersion: BridgeAPI.bridgeProtocolVersion,
                        sessionBundleID: "com.example.appA"),
        ]
        guard case .reuse(let port) = try planInApp(bundleID: "com.example.appA",
                                                    running: running, sim: sim) else {
            return XCTFail("同一アプリの inapp ブリッジは reuse するはず")
        }
        XCTAssertEqual(port, 8125)
    }

    /// 別アプリに注入された inapp ブリッジは再利用せず、停止対象(stopStalePort)として新規起動する。
    /// 再利用すると、対象アプリ前面化で旧アプリが suspend → probe 無応答 → 誤ルーティング →
    /// 旧アプリが握ったポートで relaunch して bind 失敗、の連鎖で全滅する(2026-07-23 実害)。
    func testInAppDoesNotReuseForeignBundleID() throws {
        let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        let running: [UInt16: BridgeProvisioner.RunningBridge] = [
            8125: .init(udid: "UDID-A", name: "iPhone 17 Pro", engine: "inapp",
                        protocolVersion: BridgeAPI.bridgeProtocolVersion,
                        sessionBundleID: "com.example.appA"),
        ]
        guard case .launch(let port, _, let stopStalePort, _) =
                try planInApp(bundleID: "com.example.appB", running: running, sim: sim) else {
            return XCTFail("別アプリの inapp ブリッジは reuse せず launch のはず")
        }
        XCTAssertNotEqual(port, 8125, "旧アプリが握っているポートを新規起動に使わない")
        XCTAssertEqual(stopStalePort, 8125, "別アプリの旧ブリッジは停止対象にする")
    }

    /// sessionBundleID を返さない旧 inapp ブリッジも再利用しない(注入先不明のまま掴まない)。
    func testInAppDoesNotReuseUnknownBundleID() throws {
        let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        let running: [UInt16: BridgeProvisioner.RunningBridge] = [
            8125: .init(udid: "UDID-A", name: "iPhone 17 Pro", engine: "inapp",
                        protocolVersion: BridgeAPI.bridgeProtocolVersion,
                        sessionBundleID: nil),
        ]
        guard case .launch = try planInApp(bundleID: "com.example.appB",
                                           running: running, sim: sim) else {
            return XCTFail("注入先不明の inapp ブリッジは reuse しないはず")
        }
    }
}
