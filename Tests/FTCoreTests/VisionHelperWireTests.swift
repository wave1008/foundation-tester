// 補助プロセス(vision-serve)の通信と門の単体テスト。デバイス・補助プロセスの起動は要らない。
// Vision を使うテストは同時に走らせない(SharedResource.visionML)。

import CoreGraphics
import FTTestSupport
import ImageIO
import Vision
import XCTest
@testable import FTCore

final class VisionHelperWireTests: XCTestCase {

    override func invokeTest() {
        do { try SharedResource.visionML.locked { super.invokeTest() } } catch { XCTFail("\(error)") }
    }

    func testFrameRoundTripKeepsTheRequest() throws {
        let png = Data((0..<300).map { UInt8($0 % 251) })
        let frame = try VisionHelperWire.encode(VisionHelperWire.Request(png: png))
        XCTAssertEqual(VisionHelperWire.payloadLength(header: frame.prefix(4)), frame.count - 4)
        XCTAssertEqual(try VisionHelperWire.decode(VisionHelperWire.Request.self, fromFrame: frame).png, png)
    }

    func testMalformedFramesAreRefused() throws {
        let frame = try VisionHelperWire.encode(VisionHelperWire.Request(png: Data([1, 2, 3])))
        XCTAssertThrowsError(try VisionHelperWire.decode(VisionHelperWire.Request.self, fromFrame: frame.dropLast()),
                             "本体が長さより短い")
        XCTAssertThrowsError(try VisionHelperWire.decode(VisionHelperWire.Request.self, fromFrame: frame + Data([0])),
                             "本体が長さより長い")
        var huge = UInt32(VisionHelperWire.maxFrameBytes + 1).bigEndian
        XCTAssertNil(VisionHelperWire.payloadLength(header: Data(bytes: &huge, count: 4)), "上限超えの長さは読まない")
        XCTAssertNil(VisionHelperWire.payloadLength(header: Data([0, 0, 1])), "4 バイトに満たない")
    }

    /// 補助の応答の形で往復しても特徴量は距離 0(門 `isConsistent` の許容幅の内)
    func testFeaturePrintSurvivesTheResponseRoundTrip() async throws {
        let print = try await FindImage.featurePrint(VisionHelperServer.probeImage)
        let frame = try VisionHelperWire.encode(VisionHelperWire.Response(status: .ok, print: print))
        let decoded = try VisionHelperWire.decode(VisionHelperWire.Response.self, fromFrame: frame)
        XCTAssertEqual(decoded.status, .ok)
        let restored = try XCTUnwrap(decoded.print)
        XCTAssertEqual(Double(try print.distance(to: restored)), 0, accuracy: FindImage.selfDistanceTolerance)
    }

    func testPNGRoundTripKeepsTheFeaturePrint() async throws {
        let png = try XCTUnwrap(VisionHelperClient.pngData(VisionHelperServer.probeImage))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let before = try await FindImage.featurePrint(VisionHelperServer.probeImage)
        let after = try await FindImage.featurePrint(decoded)
        XCTAssertTrue(FindImage.isConsistent(selfDistance: Double(try before.distance(to: after))),
                      "PNG を介した特徴量が in-process と一致しない(補助の値が距離の基準からずれる)")
    }

    // MARK: - 補助側の門

    func testHealthGateRefusesDegenerateAndInconsistentObservations() {
        XCTAssertTrue(VisionHelperServer.isHealthy(probeDistanceToBlank: 1.2, probeSelfDistance: 0))
        XCTAssertFalse(VisionHelperServer.isHealthy(probeDistanceToBlank: 0, probeSelfDistance: 0), "縮退")
        XCTAssertFalse(VisionHelperServer.isHealthy(probeDistanceToBlank: 1.2, probeSelfDistance: 0.33), "測り直しの不一致")
    }

    func testRespondAnswersUnhealthyBeforeLookingAtTheRequestAndRearmsOnGateFailure() async throws {
        let png = try XCTUnwrap(VisionHelperClient.pngData(VisionHelperServer.probeImage))
        let payload = try JSONEncoder().encode(VisionHelperWire.Request(png: png))
        let notHealthy = await VisionHelperServer.respond(to: payload, healthy: false,
                                                          checkHealth: { XCTFail("暖機前は門を撃たない"); return true },
                                                          computePrint: { _ in XCTFail("暖機前は計算しない"); throw VisionHelperError.unhealthy })
        XCTAssertEqual(notHealthy.response.status, .unhealthy)
        XCTAssertFalse(notHealthy.healthy)
        let degraded = await VisionHelperServer.respond(to: payload, healthy: true, checkHealth: { false },
                                                        computePrint: { _ in XCTFail("門で落ちたら計算しない"); throw VisionHelperError.unhealthy })
        XCTAssertEqual(degraded.response.status, .unhealthy)
        XCTAssertFalse(degraded.healthy, "門で落ちたら暖機をやり直す側へ戻す")
        let ok = await VisionHelperServer.respond(to: payload, healthy: true, checkHealth: { true },
                                                  computePrint: { try await FindImage.featurePrint($0) })
        XCTAssertEqual(ok.response.status, .ok)
        XCTAssertNotNil(ok.response.print)
        XCTAssertTrue(ok.healthy)
        let broken = await VisionHelperServer.respond(to: Data("x".utf8), healthy: true, checkHealth: { true },
                                                      computePrint: { try await FindImage.featurePrint($0) })
        XCTAssertEqual(broken.response.status, .failed)
    }

    /// 探り画像は白紙と別物(健全な Vision なら特徴量が離れる)。0 になる機械では補助は常に unhealthy = 既存の経路のまま
    func testProbeImageIsDistinguishableFromBlankOnAHealthyMachine() async throws {
        let healthy = await VisionHelperServer.checkHealth()
        XCTAssertTrue(healthy, "この機械の Vision は探り画像と白紙を見分けられない(補助の探り画像を見直す)")
    }

    // MARK: - 実ソケットでの往復(同一プロセス内のサーバスレッド)

    /// async の文脈から DispatchSemaphore.wait を直接呼べないので同期関数で包む
    private static func waitForServer(_ finished: DispatchSemaphore) {
        _ = finished.wait(timeout: .now() + 10)
    }

    func testClientTalksToTheServerOverARealSocket() async throws {
        let path = "/tmp/ftvh-\(getpid())-\(UInt32.random(in: 0..<1_000_000)).sock"
        let stop = LockedValue(false)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            _ = VisionHelperServer.run(socketPath: path, shouldStop: { stop.value }, log: { _ in })
            finished.signal()
        }
        thread.start()
        defer {
            stop.withLock { $0 = true }
            Self.waitForServer(finished)
            unlink(path)
        }
        let client = VisionHelperClient(socketPath: path, deadlineSeconds: 10)
        // 暖機が終わるまでは unhealthy で答える(終わるまで待つ)
        var remotePrint: FeaturePrintObservationBox?
        for _ in 0..<40 {
            do {
                remotePrint = FeaturePrintObservationBox(try await client.featurePrint(VisionHelperServer.probeImage))
                break
            } catch VisionHelperError.unhealthy, VisionHelperError.unavailable {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        let remote = try XCTUnwrap(remotePrint, "補助が健全にならない")
        let local = try await FindImage.featurePrint(VisionHelperServer.probeImage)
        XCTAssertTrue(FindImage.isConsistent(selfDistance: Double(try local.distance(to: remote.value))),
                      "補助の特徴量が in-process と一致しない")
    }

    /// 注入は値 "1" のときだけ効き、効いた値は門の測り直しで食い違う(= 救済の経路を本物の異常と同じ形で通せる)
    func testAnomalyInjectionIsExplicitAndFailsTheConsistencyGate() async throws {
        XCTAssertFalse(VisionAnomalyInjection.isActive(environment: [:]))
        XCTAssertFalse(VisionAnomalyInjection.isActive(environment: ["FT_FAKE_VISION_ANOMALY": "0"]))
        XCTAssertTrue(VisionAnomalyInjection.isActive(environment: ["FT_FAKE_VISION_ANOMALY": "1"]))
        let real = try await FindImage.featurePrint(VisionHelperServer.probeImage)
        let fake = try await VisionAnomalyInjection.degeneratePrint()
        XCTAssertFalse(FindImage.isConsistent(selfDistance: Double(try real.distance(to: fake))))
    }

    func testSocketPathFitsSunPathAndLivesUnderTheMachineStateDirectory() throws {
        let path = try XCTUnwrap(VisionHelperWire.socketPath(parentPID: 12345,
                                                             home: URL(fileURLWithPath: "/Users/someone")))
        XCTAssertEqual(path, "/Users/someone/.fleetest/vision-12345.sock")
        let longHome = URL(fileURLWithPath: "/" + String(repeating: "a", count: 120))
        XCTAssertNil(VisionHelperWire.socketPath(parentPID: 12345, home: longHome), "収まらなければ補助を起こさない")
    }

    func testNoClientWithoutTheEnvironmentVariable() {
        XCTAssertNil(VisionHelperClient.fromEnvironment([:]))
        XCTAssertNil(VisionHelperClient.fromEnvironment([VisionHelperWire.socketEnvironmentKey: ""]))
        XCTAssertEqual(VisionHelperClient.fromEnvironment([VisionHelperWire.socketEnvironmentKey: "/x.sock"])?.socketPath, "/x.sock")
    }

    /// 補助を起こすのは見本があり、実行ファイルが fleetest のときだけ
    func testHostStartsOnlyForTemplatesAndTheFleetestExecutable() {
        XCTAssertTrue(VisionHelperHost.shouldStart(hasTemplates: true, executableName: "fleetest"))
        XCTAssertFalse(VisionHelperHost.shouldStart(hasTemplates: false, executableName: "fleetest"))
        XCTAssertFalse(VisionHelperHost.shouldStart(hasTemplates: true, executableName: "xctest"))
        XCTAssertFalse(VisionHelperHost.shouldStart(hasTemplates: true, executableName: nil))
    }

    /// 起動は RunOrchestrator.run の1か所・環境変数は ScenarioHost.childEnvironment から(run / api run の両方がここを通る)
    func testHelperIsWiredAtTheSharedRunEntryAndTheChildEnvironment() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let orchestrator = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/RunOrchestrator.swift"), encoding: .utf8)
        XCTAssertTrue(orchestrator.contains("VisionHelperHost.acquire(project: project)"))
        XCTAssertTrue(orchestrator.contains("visionHelper?.release()"))
        let host = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/ScenarioHost.swift"), encoding: .utf8)
        XCTAssertTrue(host.contains("env[VisionHelperWire.socketEnvironmentKey] = VisionHelperHost.activeSocketPath"))
        let helper = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/VisionHelperHost.swift"), encoding: .utf8)
        XCTAssertTrue(helper.contains("ParentDeathWatch.childEnvironment()"), "親の死に連動させる")
        let commands = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/ApiCommands.swift"), encoding: .utf8)
        XCTAssertTrue(commands.contains("ApiVisionServeCommand.self"))
    }
}

/// テスト内で非 Sendable の特徴量を `var` 越しに持つための入れ物(テストは1スレッドで読む)
private struct FeaturePrintObservationBox: @unchecked Sendable {
    let value: FeaturePrintObservation
    init(_ value: FeaturePrintObservation) { self.value = value }
}
