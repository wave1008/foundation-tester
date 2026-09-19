// 起動途中のランナーを引き取ったとき(BridgeProvisioner の adopt)は、応答してから版を確かめる。
// 起動途中は /status に答えないので再利用の判定(版一致)を通らずに引き取られ、旧ビルドのまま使われた
// (2026-09-19: v119 のツールの bridge up が v118 のランナーを返した)。

import XCTest
@testable import FTBridgeClient
import FTCore

final class AdoptedRunnerVersionTests: XCTestCase {

    private func status(version: Int?) -> StatusResponse {
        StatusResponse(ready: true, device: "sim", osVersion: "-", sessionBundleID: nil,
                       engine: "xcuitest", protocolVersion: version)
    }

    func testOnlyTheCurrentVersionIsKept() {
        XCTAssertFalse(BridgeProvisioner.adoptedRunnerIsStale(status(version: BridgeAPI.bridgeProtocolVersion)))
        XCTAssertTrue(BridgeProvisioner.adoptedRunnerIsStale(status(version: BridgeAPI.bridgeProtocolVersion - 1)))
        XCTAssertTrue(BridgeProvisioner.adoptedRunnerIsStale(status(version: nil)), "版を名乗らない旧ランナーも旧ビルド")
    }

    /// 引き取りの経路は、応答(waitUntilReady の戻り値)を判定に掛けて、旧ビルドなら建て直す
    func testTheAdoptPathChecksTheVersionAfterTheRunnerAnswers() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTBridgeClient/BridgeProvisioner.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        // 列挙の定義(`case .adopt(let port): return port`)と取り違えないよう、引き取りの経路に固有の文言を起点にする
        let start = try XCTUnwrap(source.range(of: "taking over the starting"))
        let end = try XCTUnwrap(source.range(of: "case .launch(let port", range: start.upperBound..<source.endIndex))
        let adopt = String(source[start.upperBound..<end.lowerBound])
        let ready = try XCTUnwrap(adopt.range(of: "status = try await launcher.waitUntilReady("),
                                  "応答した /status を受け取っていない")
        let check = try XCTUnwrap(adopt.range(of: "if Self.adoptedRunnerIsStale(status) {"),
                                  "引き取った後に版を確かめていない")
        XCTAssertLessThan(ready.lowerBound, check.lowerBound)
        let afterCheck = adopt[check.upperBound...]
        let restart = try XCTUnwrap(afterCheck.range(of: "return try await stopAndRelaunch()"))
        let takenOver = try XCTUnwrap(afterCheck.range(of: "took over the"))
        XCTAssertLessThan(restart.lowerBound, takenOver.lowerBound, "旧ビルドなら引き取りを報告する前に建て直す")
    }
}
