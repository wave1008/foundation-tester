// in-app ブリッジの再利用は「版が同じ」だけでは足りず、**注入済み dylib の出所**まで一致を要求する
// ことの固定。
//
// これが無いと、ブリッジのソースを直しても稼働中のブリッジがそのまま使われ、**変更が1度も
// 実行されないまま緑になる**。実測(2026-08-20): InAppBridge/Sources/InAppSettle.swift を
// 書き換えて run しても dylib は作り直されず(mtime が動かない)、版を 72 → 71 に戻して run しても
// 稼働中の v72 ブリッジがそのまま応答した。**版の一致だけでは掛からない** ——
// 版を上げ忘れた変更が素通りするうえ、決定を行うプロセスが run 内の swift build より前に
// 起動していると、比較に使う定数自体が1ビルド古い。digest は**その場のソースから計算する**ので
// どちらにも掛かる。

import XCTest
import FTCore
@testable import FTBridgeClient

final class InAppSourceDigestReuseTests: XCTestCase {
    private var repoRoot: URL!

    override func setUpWithError() throws {
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftinappdigest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func planInApp(running: [UInt16: BridgeProvisioner.RunningBridge],
                           digest: String?) throws -> BridgeProvisioner.EnginePlan {
        let provisioner = BridgeProvisioner(repoRoot: repoRoot, portRange: 8123...8130)
        var claimed: Set<UInt16> = []
        var used = Set(running.keys)
        let sim = SimDeviceInfo(udid: "UDID-A", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)
        return try provisioner.planBridge(
            engine: "inapp", preferred: nil, name: sim.name, sim: sim,
            bundleID: "com.example.app", appIsCurrent: [:], preinstallAppPath: nil,
            running: running, starting: [:], inappSourceDigest: digest,
            claimed: &claimed, usedPorts: &used)
    }

    private func runningInApp(digest: String?) -> [UInt16: BridgeProvisioner.RunningBridge] {
        [8123: .init(udid: "UDID-A", name: "iPhone 17 Pro", engine: "inapp",
                     protocolVersion: BridgeAPI.bridgeProtocolVersion,
                     sessionBundleID: "com.example.app", sourceDigest: digest)]
    }

    /// 出所が同じなら従来どおり再利用する(建て直しのコストを毎回払わない)
    func testReusesWhenTheInjectedDylibCameFromTheSameSources() throws {
        guard case .reuse(let port) = try planInApp(running: runningInApp(digest: "abc123"),
                                                    digest: "abc123") else {
            return XCTFail("同じ出所の in-app ブリッジを再利用していない")
        }
        XCTAssertEqual(port, 8123)
    }

    /// **ソースが変わったら再利用しない**。ここが落ちると、ブリッジへの変更が実行されないまま
    /// 緑になる(この機構の存在理由そのもの)
    func testRelaunchesWhenTheSourcesChangedSinceTheDylibWasInjected() throws {
        guard case .launch = try planInApp(running: runningInApp(digest: "old-digest"),
                                           digest: "new-digest") else {
            return XCTFail("ソースが変わったのに稼働中の in-app ブリッジを再利用している"
                           + "(変更が1度も実行されないまま緑になる)")
        }
    }

    /// 旧版が書いた記録(出所なし)も**出所不明として建て直す** —— 更新直後の1回だけ余分に
    /// 建て直すが、「古い dylib のまま緑」を残すよりよい
    func testRelaunchesWhenTheRunningBridgeHasNoRecordedOrigin() throws {
        guard case .launch = try planInApp(running: runningInApp(digest: nil),
                                           digest: "new-digest") else {
            return XCTFail("出所不明の in-app ブリッジを再利用している")
        }
    }

    /// **陰性対照**: こちらが digest を計算できない構成(受け手パッケージ等)では判定材料が
    /// 無いので、判定材料が無いことを理由に毎回建て直さない(従来どおり版と注入先で判定)
    func testKeepsReusingWhenTheCurrentDigestCannotBeComputed() throws {
        guard case .reuse = try planInApp(running: runningInApp(digest: "whatever"),
                                          digest: nil) else {
            return XCTFail("digest が計算できないだけで建て直している")
        }
    }

    /// 状態ファイルの往復と**旧形式(2語)の後方互換**。読めなくなると全ブリッジが毎回
    /// 建て直しになる(遅くなるだけだが、原因が読めない)
    func testStateFileRoundTripAndLegacyTwoFieldRecord() throws {
        let dir = repoRoot.appendingPathComponent(".fleetest")
        InAppBridgeState.write(stateDir: dir, port: 8123, udid: "UDID-A",
                               bundleID: "com.example.app", sourceDigest: "digest-1")
        XCTAssertEqual(InAppBridgeState.sourceDigest(stateDir: dir, port: 8123), "digest-1")

        let legacy = InAppBridgeState.url(stateDir: dir, port: 8124)
        try "UDID-B com.example.other".write(to: legacy, atomically: true, encoding: .utf8)
        let parsed = InAppBridgeState.read(at: legacy)
        XCTAssertEqual(parsed?.udid, "UDID-B")
        XCTAssertEqual(parsed?.bundleID, "com.example.other")
        XCTAssertNil(parsed?.sourceDigest, "旧形式は出所不明として読むこと")
    }
}
