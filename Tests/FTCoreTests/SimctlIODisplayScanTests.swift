// `simctl io <udid> screenshot|recordVideo` は**内蔵画面が2枚ある機種(iPhone Duo)で画面の指定が無いと
// exit 22** になる(録画は毎回空・モニターの撮影も失敗していた)。画面の選び方は
// `FTCore.SimulatorActiveDisplay` の1箇所(表示中の画面を devicectl で引く)。**新しく `simctl io` で
// 撮る/録る行を書いて、そこを通さなかったら落ちる**(その行に `SimulatorActiveDisplay` が無い)。
// 定義元(SimulatorActiveDisplay.swift)は「まず指定なしで撮る」行を持つので対象外。

import Foundation
import XCTest

final class SimctlIODisplayScanTests: XCTestCase {
    private static let definer = "FTCore/SimulatorActiveDisplay.swift"

    func testEverySimctlIOCaptureGoesThroughTheActiveDisplaySelection() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        var offenders: [String] = []
        var routed = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard relative != Self.definer else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//")[0]
                guard code.contains("\"io\""),
                      code.contains("\"screenshot\"") || code.contains("\"recordVideo\"") else { continue }
                if code.contains("SimulatorActiveDisplay") {
                    routed += 1
                } else {
                    offenders.append("\(relative):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], """
            simctl io の screenshot / recordVideo が画面を選んでいない —— 2画面の機種で exit 22 になる。\
            SimulatorActiveDisplay.simctlIOArguments(udid:) か simctlScreenshot を通す
            """)
        // 走査が録画の3行(IOSSimulatorVideoRecorder ×2・HostRecordingProbe)に届いていること
        XCTAssertGreaterThanOrEqual(routed, 3, "走査が simctl io の呼び出しに届いていない")
    }
}
