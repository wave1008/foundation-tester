// `fleetest run`(Fleetest.swift の RunScenarios)と `fleetest api run`(ApiRunCommand.swift)は
// 手写しの2実装なので、RunDeviceMachineAmbiguity の判定を片方だけへ足すと、その経路の run だけが
// 黙って全機械で回り続ける(RunCommandFlagParityTests/RunRejectionParityTests と同じ理由でソース走査を置く)。

import Foundation
import XCTest
@testable import fleetest

final class RunDeviceMachineAmbiguityWiringTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static let entryPoints = ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"]

    /// 曖昧な --device の断りは両方の run() が1回ずつ呼ぶ
    func testBothEntryPointsCallRejectionMessageOnce() throws {
        for path in Self.entryPoints {
            let text = try source(path)
            XCTAssertEqual(text.components(separatedBy: "RunDeviceMachineAmbiguity.rejectionMessage(").count - 1,
                           1, "\(path): rejectionMessage を呼ぶ箇所が1つでない")
        }
    }

    /// --all-machines と --runner/--device-machine の併用不可は両方の validate() が1回ずつ呼ぶ
    func testBothEntryPointsCallAllMachinesConflictMessageOnce() throws {
        for path in Self.entryPoints {
            let text = try source(path)
            XCTAssertEqual(
                text.components(separatedBy: "RunDeviceMachineAmbiguity.allMachinesConflictMessage(").count - 1,
                1, "\(path): allMachinesConflictMessage を呼ぶ箇所が1つでない")
        }
    }

    /// **`DeviceMachineRunner.plan` より前**(機械ごとに分ける前・デバイスに触る前に断る)
    func testRejectionMessageIsCheckedBeforeDeviceMachineRunnerPlan() throws {
        for path in Self.entryPoints {
            let text = try source(path)
            let rejection = try XCTUnwrap(
                text.range(of: "RunDeviceMachineAmbiguity.rejectionMessage("), path)
            let plan = try XCTUnwrap(text.range(of: "DeviceMachineRunner.plan("), path)
            XCTAssertLessThan(rejection.lowerBound, plan.lowerBound,
                              "\(path): DeviceMachineRunner.plan の後で断っている")
        }
    }

    /// `--all-machines` フラグそのものも両方が宣言している(片方だけ足すとフラグの集合が割れる。
    /// RunCommandFlagParityTests が共通フラグは固定しないので、ここで別途固定する)
    func testBothEntryPointsDeclareTheFlag() throws {
        for path in Self.entryPoints {
            let text = try source(path)
            XCTAssertTrue(text.contains(".customLong(\"all-machines\")"), "\(path): --all-machines が無い")
        }
    }
}
