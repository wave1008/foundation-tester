import XCTest
@testable import FTBridgeClient

/// ライブ操作の自動起動の門: 同じ端末の別ポートに**残骸と言えないランナー**(待受している・起動途中・別のワークスペース)が
/// 居れば2本目を起動しない。忙しいランナーは /status に答えず走査に載らないが待受は続き、起動途中のランナーはまだ待ち受けていない。
final class SimulatorRunnerElsewhereGateTests: XCTestCase {

    private let busy: (pid: Int32, port: UInt16) = (101, 8129)
    private let gone: (pid: Int32, port: UInt16) = (102, 8130)

    /// 仕分けは判定の答えのとおり(残骸と言えたものだけ leftovers・それ以外は live)
    func testPartitionFollowsTheLeftoverVerdict() {
        let split = BridgeLauncher.partitionRunnersElsewhere([busy, gone], isLeftover: { _, port in port == 8130 })
        XCTAssertEqual(split.live.map(\.port), [8129])
        XCTAssertEqual(split.leftovers.map(\.port), [8130])
    }

    func testNoOtherRunnersMeansNothingBlocks() {
        let split = BridgeLauncher.partitionRunnersElsewhere([], isLeftover: { _, _ in true })
        XCTAssertTrue(split.live.isEmpty && split.leftovers.isEmpty)
    }

    private func leftover(_ connect: BridgeDiscovery.ConnectProbe, ownedHere: Bool = true, readyMarked: Bool = false,
                          verdict: StartingRunnerVerdict = .restart) -> Bool {
        BridgeLauncher.isLeftoverRunner(connect: connect, ownedHere: ownedHere, readyMarked: readyMarked,
                                        startVerdict: verdict)
    }

    /// 待ち受けている・不明(溢れた backlog の reset・300ms の時間切れ)は居る側
    func testListeningOrUnknownIsNeverALeftover() {
        XCTAssertFalse(leftover(.connected, readyMarked: true))
        XCTAssertFalse(leftover(.unknown, readyMarked: true))
    }

    /// **起動途中(一度も ready になっていない・起動予算の内側かログが伸びている)は、待ち受けていなくても止めない**
    func testAStartingRunnerIsNotALeftoverEvenThoughNothingListensYet() {
        XCTAssertFalse(leftover(.refused, readyMarked: false, verdict: .wait))
    }

    /// 一度 ready になって待受が消えた(2本目に殺されたランナーの xcodebuild)・起動予算を超えてログも止まった、は残骸
    func testReadyOnceOrStuckPastTheBudgetIsALeftover() {
        XCTAssertTrue(leftover(.refused, readyMarked: true, verdict: .wait))
        XCTAssertTrue(leftover(.refused, readyMarked: false, verdict: .restart))
    }

    /// 別のワークスペースのランナー(持ち主を読めないものも)は止めない
    func testAnotherWorkspacesRunnerIsNeverALeftover() {
        XCTAssertFalse(leftover(.refused, ownedHere: false, readyMarked: true))
    }

    /// 持ち主: 読めるコマンド行はその持ち主で決め、空白を含むパスのクローン(runnerProcess が読めない)は `.fleetest/` の位置で決める
    func testRunnerOwnershipIncludingAPathWithSpaces() {
        let here = URL(fileURLWithPath: "/tmp/ws-here")
        let command = "xcodebuild test-without-building -xctestrun /tmp/ws-here/.fleetest/DerivedData/Build/Products/"
            + "FleetestRunner-8152.xctestrun -destination id=UD-1"
        XCTAssertTrue(BridgeLauncher.runnerIsOwned(command: command, repoRoot: here))
        XCTAssertFalse(BridgeLauncher.runnerIsOwned(command: command, repoRoot: URL(fileURLWithPath: "/tmp/ws-other")))
        let spaced = URL(fileURLWithPath: "/tmp/My Projects/ws")
        let spacedCommand = "xcodebuild test-without-building -xctestrun /tmp/My Projects/ws/.fleetest/DerivedData/Build/Products/"
            + "FleetestRunner-8152.xctestrun -destination id=UD-1"
        XCTAssertTrue(BridgeLauncher.runnerIsOwned(command: spacedCommand, repoRoot: spaced), "空白入りのパスで自分のランナーを読めない")
        XCTAssertFalse(BridgeLauncher.runnerIsOwned(command: spacedCommand, repoRoot: URL(fileURLWithPath: "/tmp/ws")),
                       "別のクローンの末尾が一致しただけで自分のものと読んでいる")
    }

    func testMessageReadsCorrectlyForSimulatorAndPhysical() {
        let sim = LauncherError.deviceRunnerElsewhere(device: "UD-1", port: 8129, pid: 5, physical: false)
            .errorDescription ?? ""
        XCTAssertTrue(sim.hasPrefix("simulator UD-1"), sim)
        XCTAssertFalse(sim.contains("physical device"), sim)
        XCTAssertTrue(sim.contains("fleetest bridge down --port 8129"), sim)
        let phys = LauncherError.deviceRunnerElsewhere(device: "UD-2", port: 8150, pid: 6, physical: true)
            .errorDescription ?? ""
        XCTAssertTrue(phys.hasPrefix("physical device UD-2"), phys)
    }

    /// 呼び手は判定を自前で書かず、観測をつなぐ口(`partitionRunnersElsewhere(_:repoRoot:)`)を通す。
    /// 接続拒否だけで仕分ける閉包を書くと、起動途中のランナーを残骸として止める形に戻る
    func testCallersGoThroughTheWiredPartition() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var callers: [String: Int] = [:]
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "BridgeLauncher.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            var rest = text[...]
            while let range = rest.range(of: "partitionRunnersElsewhere(") {
                let call = rest[range.upperBound...].prefix(400)
                let closing = call.range(of: ")\n") ?? call.range(of: ")")
                let args = closing.map { call[..<$0.upperBound] } ?? call
                XCTAssertTrue(args.contains("repoRoot: repoRoot"),
                              "\(url.lastPathComponent): 観測の口を通していない: \(args)")
                XCTAssertFalse(args.contains("isLeftover:"), "\(url.lastPathComponent): 判定を自前で書いている")
                callers[url.lastPathComponent, default: 0] += 1
                rest = rest[range.upperBound...]
            }
        }
        XCTAssertEqual(callers, ["LiveBridgeAutoStarter.swift": 1, "ApiLiveCommand.swift": 1, "XCUIBridgeResolver.swift": 1])
    }
}
