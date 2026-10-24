// `fleetest run`(Fleetest.swift の RunScenarios)と `fleetest api run`(ApiRunCommand.swift)の
// `--device` の曖昧さの断り(run() の中・プロファイルを読む)は2本に別々にあり、片方だけへ足すと、その経路の
// run だけが黙って全機械で回り続ける。`--all-machines` の宣言と併用不可の検査は RunCommonOptions で共有
// (取り込みと呼び出しを走査で固定する。RunCommandFlagParityTests/RunRejectionParityTests と同じ理由)。

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
    private static let commonOptions = "Sources/fleetest/RunCommonOptions.swift"

    /// 曖昧な --device の断りは両方の run() が1回ずつ呼ぶ
    func testBothEntryPointsCallRejectionMessageOnce() throws {
        for path in Self.entryPoints {
            let text = try source(path)
            XCTAssertEqual(text.components(separatedBy: "RunDeviceMachineAmbiguity.rejectionMessage(").count - 1,
                           1, "\(path): rejectionMessage を呼ぶ箇所が1つでない")
        }
    }

    /// --all-machines と --runner/--device-machine の併用不可は共有の検査(RunCommonOptions)に1箇所だけ置き、
    /// 両方の validate() がそれを1回ずつ呼ぶ
    func testBothEntryPointsCallAllMachinesConflictMessageOnce() throws {
        let shared = try source(Self.commonOptions)
        XCTAssertEqual(
            shared.components(separatedBy: "RunDeviceMachineAmbiguity.allMachinesConflictMessage(").count - 1,
            1, "\(Self.commonOptions): allMachinesConflictMessage を呼ぶ箇所が1つでない")
        for path in Self.entryPoints {
            let text = try source(path)
            XCTAssertEqual(text.components(separatedBy: "common.validateRunnerAndMachines(").count - 1,
                           1, "\(path): validateRunnerAndMachines を呼ぶ箇所が1つでない")
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

    /// `--all-machines` フラグそのものは共有の宣言(RunCommonOptions)にあり、両方がそれを取り込んでいる
    /// (片方が取り込みをやめるとフラグの集合が割れる。RunCommandFlagParityTests は共通フラグを固定しない)
    func testBothEntryPointsDeclareTheFlag() throws {
        XCTAssertTrue(try source(Self.commonOptions).contains(".customLong(\"all-machines\")"),
                      "\(Self.commonOptions): --all-machines が無い")
        for path in Self.entryPoints {
            let text = try source(path)
            XCTAssertTrue(text.contains("@OptionGroup var common: RunCommonOptions"),
                          "\(path): RunCommonOptions を取り込んでいない")
        }
    }
}
