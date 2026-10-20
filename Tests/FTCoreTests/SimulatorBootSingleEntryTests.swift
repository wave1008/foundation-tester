// Simulator の起動(simctl boot / bootstatus)は `SimulatorBoot.swift` の1箇所だけが撃つ。
// 直に撃くと起動前の掃除と機械全体で同時2台の枠(SimulatorBootSlots)を素通りする。

import Foundation
import XCTest

final class SimulatorBootSingleEntryTests: XCTestCase {
    private static let bootPattern = #""simctl"\s*,\s*"(boot|bootstatus)""#

    func testOnlySimulatorBootSwiftRunsSimctlBoot() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var inEntry = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//")[0]
                guard code.range(of: Self.bootPattern, options: .regularExpression) != nil else { continue }
                if url.lastPathComponent == "SimulatorBoot.swift" {
                    inEntry += 1
                } else {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(inEntry, 1, "the scan did not reach SimulatorBoot.swift")
        // xcodebuild の自動起動も枠を通す: ランナーを起こす前に入口を撃つ
        let launcher = try String(contentsOf: root.appendingPathComponent("FTBridgeClient/BridgeLauncher.swift"), encoding: .utf8)
        let start = try XCTUnwrap(launcher.range(of: "public func startDetached() throws {"))
        let boot = try XCTUnwrap(launcher.range(of: "SimulatorBoot.ensureBooted(", range: start.upperBound..<launcher.endIndex),
                                 "startDetached does not boot the simulator through SimulatorBoot.ensureBooted")
        let xcodebuild = try XCTUnwrap(launcher.range(of: "process.run()", range: start.upperBound..<launcher.endIndex))
        XCTAssertLessThan(boot.lowerBound, xcodebuild.lowerBound, "startDetached launches xcodebuild before booting the simulator")
        XCTAssertEqual(offenders, [],
                       "simctl boot / bootstatus outside SimulatorBoot.ensureBooted: " + offenders.joined(separator: ", "))
    }
}
