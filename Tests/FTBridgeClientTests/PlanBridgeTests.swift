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
                      sim: SimDeviceInfo,
                      starting: [String: [UInt16]] = [:]) throws -> BridgeProvisioner.EnginePlan {
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130)
        var claimed: Set<UInt16> = []
        var used = Set(running.keys)
        return try provisioner.planBridge(
            engine: "xcuitest", preferred: nil, name: sim.name, sim: sim, bundleID: nil,
            appIsCurrent: [:], preinstallAppPath: nil, running: running, starting: starting,
            claimed: &claimed, usedPorts: &used)
    }

    /// **別プロセスが起動した直後(= /status 未応答)のランナーは running に映らない**。
    /// ここで新しい空きポートを採ると同一デバイスに 2 本目が立ち、OS の 1 デバイス 1 ランナー
    /// 制約でどちらも上がらない(再起動直後に実害化)。引き取って announce を待つのが正しい
    func testAdoptsStartingRunnerInsteadOfLaunchingSecond() throws {
        let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        let running: [UInt16: BridgeProvisioner.RunningBridge] = [
            8123: .init(udid: "UDID-OTHER", name: "iPhone 17 Pro", engine: "xcuitest",
                        protocolVersion: BridgeAPI.bridgeProtocolVersion, sessionBundleID: nil),
        ]
        guard case .adopt(let port) = try plan(running: running, sim: sim,
                                               starting: ["UDID-A": [8128]]) else {
            return XCTFail("起動中ランナーは adopt するはず(新規ポートで 2 本目を立てない)")
        }
        XCTAssertEqual(port, 8128)
    }

    /// announce 済みの再利用が優先(adopt は再利用できないときの経路)
    func testReuseWinsOverAdopt() throws {
        let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        let running: [UInt16: BridgeProvisioner.RunningBridge] = [
            8125: .init(udid: "UDID-A", name: "iPhone 17 Pro", engine: "xcuitest",
                        protocolVersion: BridgeAPI.bridgeProtocolVersion, sessionBundleID: nil),
        ]
        guard case .reuse(let port) = try plan(running: running, sim: sim,
                                               starting: ["UDID-A": [8128]]) else {
            return XCTFail("announce 済みブリッジがあれば reuse")
        }
        XCTAssertEqual(port, 8125)
    }

    /// 別デバイスの起動中ランナーは引き取らない(自分のデバイスの分だけ見る)
    func testIgnoresStartingRunnerOfOtherDevice() throws {
        let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        guard case .launch = try plan(running: [:], sim: sim, starting: ["UDID-B": [8128]]) else {
            return XCTFail("別デバイスの起動中ランナーは無関係なので launch するはず")
        }
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

    /// **旧版の inapp ブリッジは同一アプリでも再利用しない**。dylib を作り直しても
    /// bridgeProtocolVersion を上げ忘れると稼働中の旧ブリッジが掴まれ、追加した
    /// エンドポイントが 404 になる/変えた挙動が反映されない(調査中に実際に踏んだ)。
    /// xcuitest 側だけが版ゲートを持っていた時期があるので、inapp 側の退行をここで止める
    func testInAppDoesNotReuseStaleProtocolVersion() throws {
        let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        let running: [UInt16: BridgeProvisioner.RunningBridge] = [
            8125: .init(udid: "UDID-A", name: "iPhone 17 Pro", engine: "inapp",
                        protocolVersion: BridgeAPI.bridgeProtocolVersion - 1,
                        sessionBundleID: "com.example.appA"),
        ]
        guard case .launch(let port, _, let stopStalePort, _) =
                try planInApp(bundleID: "com.example.appA", running: running, sim: sim) else {
            return XCTFail("旧版の inapp ブリッジは同一アプリでも reuse せず launch のはず")
        }
        XCTAssertNotEqual(port, 8125, "旧版が握っているポートを新規起動に使わない")
        XCTAssertEqual(stopStalePort, 8125, "旧版の inapp ブリッジは停止対象にする")
    }

    /// 版を申告しない inapp ブリッジ(この定数導入前のビルド)も同じ扱いにする。
    func testInAppDoesNotReuseBridgeWithoutProtocolVersion() throws {
        let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        let running: [UInt16: BridgeProvisioner.RunningBridge] = [
            8125: .init(udid: "UDID-A", name: "iPhone 17 Pro", engine: "inapp",
                        protocolVersion: nil,
                        sessionBundleID: "com.example.appA"),
        ]
        guard case .launch(let port, _, let stopStalePort, _) =
                try planInApp(bundleID: "com.example.appA", running: running, sim: sim) else {
            return XCTFail("版申告の無い inapp ブリッジは reuse せず launch のはず")
        }
        XCTAssertNotEqual(port, 8125)
        XCTAssertEqual(stopStalePort, 8125)
    }
}
