// 供給の計画段が、別の実在するワークスペースのブリッジを止めないこと(BridgeOwnership)。
// 実害: 別クローンの供給が本線の XCUITest ランナーを「再利用」に選び、自分の台帳にツールチェーンの
// 記録が無いので起動し直して止めた。版が同じなら起動し直さずに使い(.reuseForeign)、
// 再利用できないなら止めずにそのデバイスだけ断る(.blockedByForeign)。

import XCTest
import FTCore
@testable import FTBridgeClient

final class ForeignBridgeOwnershipPlanTests: XCTestCase {
    private var repoRoot: URL!
    private let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
    private let other = BridgeOwnership.foreign(owner: "/other-clone")

    override func setUpWithError() throws {
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftforeignplan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func plan(engine: String, bundleID: String? = nil, digest: String? = nil,
                      running: [UInt16: BridgeProvisioner.RunningBridge]) throws
        -> BridgeProvisioner.EnginePlan {
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130,
                                            // この Mac で生きているブリッジ(lsof)に結果を左右させない
                                            portHeldByAnotherDevice: { _, _ in false })
        var claimed: Set<UInt16> = []
        var used = Set(running.keys)
        return try provisioner.planBridge(
            engine: engine, preferred: nil, name: sim.name, sim: sim, bundleID: bundleID,
            appIsCurrent: [:], preinstallAppPath: nil, running: running, starting: [:],
            inappSourceDigest: digest, claimed: &claimed, usedPorts: &used)
    }

    private func xcuitest(version: Int?, ownership: BridgeOwnership)
        -> [UInt16: BridgeProvisioner.RunningBridge] {
        [8125: .init(udid: "UDID-A", name: sim.name, engine: "xcuitest", protocolVersion: version,
                     sessionBundleID: nil, ownership: ownership)]
    }

    private func inapp(bundleID: String?, digest: String?, ownership: BridgeOwnership)
        -> [UInt16: BridgeProvisioner.RunningBridge] {
        [8125: .init(udid: "UDID-A", name: sim.name, engine: "inapp",
                     protocolVersion: BridgeAPI.bridgeProtocolVersion, sessionBundleID: bundleID,
                     sourceDigest: digest, ownership: ownership)]
    }

    func testForeignCurrentXCUITestRunnerIsUsedAsIs() throws {
        guard case .reuseForeign(let port, let owner) = try plan(
            engine: "xcuitest",
            running: xcuitest(version: BridgeAPI.bridgeProtocolVersion, ownership: other)) else {
            return XCTFail("別のワークスペースの同じ版のランナーは起動し直さずに使うはず")
        }
        XCTAssertEqual(port, 8125)
        XCTAssertEqual(owner, "/other-clone")
    }

    /// 陰性対照: 自分のランナーは従来どおり .reuse(ツールチェーン・劣化の判定を通る)
    func testOwnCurrentXCUITestRunnerKeepsTheUsualReuse() throws {
        guard case .reuse(let port) = try plan(
            engine: "xcuitest",
            running: xcuitest(version: BridgeAPI.bridgeProtocolVersion, ownership: .own)) else {
            return XCTFail("自分のランナーは .reuse のはず")
        }
        XCTAssertEqual(port, 8125)
    }

    func testForeignStaleXCUITestRunnerIsNotStopped() throws {
        guard case .blockedByForeign(let port, let owner, _) = try plan(
            engine: "xcuitest",
            running: xcuitest(version: BridgeAPI.bridgeProtocolVersion - 1, ownership: other)) else {
            return XCTFail("別のワークスペースの古いランナーは止めずに断るはず")
        }
        XCTAssertEqual(port, 8125)
        XCTAssertEqual(owner, "/other-clone")
    }

    /// 自分のもの・孤児(申告先が消えた)の古いランナーは従来どおり止めて起動する
    func testOwnAndOrphanStaleRunnersAreStillReplaced() throws {
        for ownership in [BridgeOwnership.own, .orphan(owner: "/deleted-clone"), .unknown] {
            guard case .launch(_, _, let stopStalePort, _) = try plan(
                engine: "xcuitest",
                running: xcuitest(version: BridgeAPI.bridgeProtocolVersion - 1,
                                  ownership: ownership)) else {
                return XCTFail("\(ownership): 古いランナーは止めて起動するはず")
            }
            XCTAssertEqual(stopStalePort, 8125, "\(ownership)")
        }
    }

    /// 別のワークスペースの in-app ブリッジは dylib の出所がこちらの台帳に無い。出所の不一致を
    /// 理由に止めない(注入先アプリと版が同じなら使う)
    func testForeignInAppBridgeOfTheSameAppIsUsedDespiteUnknownDigest() throws {
        guard case .reuseForeign(let port, _) = try plan(
            engine: "inapp", bundleID: "com.example.app", digest: "mine",
            running: inapp(bundleID: "com.example.app", digest: nil, ownership: other)) else {
            return XCTFail("別のワークスペースの同じアプリの in-app ブリッジは使うはず")
        }
        XCTAssertEqual(port, 8125)
    }

    /// 陰性対照: 自分の in-app ブリッジは従来どおり出所の不一致で止めて起動する
    func testOwnInAppBridgeWithAnotherDigestIsStillReplaced() throws {
        guard case .launch(_, _, let stopStalePort, _) = try plan(
            engine: "inapp", bundleID: "com.example.app", digest: "mine",
            running: inapp(bundleID: "com.example.app", digest: "older", ownership: .own)) else {
            return XCTFail("自分の出所違いの in-app ブリッジは止めて起動するはず")
        }
        XCTAssertEqual(stopStalePort, 8125)
    }

    func testForeignInAppBridgeOfAnotherAppIsNotStopped() throws {
        guard case .blockedByForeign(let port, _, _) = try plan(
            engine: "inapp", bundleID: "com.example.mine",
            running: inapp(bundleID: "com.example.theirs", digest: nil, ownership: other)) else {
            return XCTFail("別のワークスペースの別アプリの in-app ブリッジは止めずに断るはず")
        }
        XCTAssertEqual(port, 8125)
    }
}
