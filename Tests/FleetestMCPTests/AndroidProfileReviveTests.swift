// MCP のプロファイル解決(resolveProfileTarget)は、Android の AVD が起動していなければ
// run(ProfileRunner/ApiRunCommand)と同じ AndroidLaneRecovery で起こしてから serial を解決すること。
// 起こさないと avdNotRunning で止まり、`profile setup --auto-device` が選んだ未起動の AVD で ft_* が
// 最初から使えなかった(iOS は provision がシミュレータを起こす)。素通りしてもコンパイルは通るので
// ソース走査で固定する。

import XCTest

final class AndroidProfileReviveTests: XCTestCase {

    private static func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testAndroidProfileResolutionRevivesBeforeResolvingTheSerial() throws {
        let code = try Self.source("Sources/fleetest-mcp/MCPServer+Dispatch.swift")
        let resolve = try XCTUnwrap(code.range(of: "AndroidDeviceCatalog.resolveSerial(spec: device.spec)"),
                                    "MCP の Android の serial 解決が見つからない(走査の前提が崩れた)")
        let before = String(code[code.startIndex..<resolve.lowerBound])
        let branch = try XCTUnwrap(before.range(of: "} else {", options: .backwards),
                                   "Android の分岐の始まりが見つからない")
        let body = String(before[branch.upperBound...])
        XCTAssertTrue(body.contains("AndroidLaneRecovery.plan("),
                      "起動していない AVD を選ぶ段が serial 解決の前に無い")
        XCTAssertTrue(body.contains("AndroidLaneRecovery.bootMissingDevices("),
                      "起動していない AVD を起こす段が serial 解決の前に無い")
        XCTAssertTrue(body.contains("ProfileWorkerFactory.awaitDurableAndroidBridges("),
                      "起こした後にブリッジの定着を待っていない(run と手順が食い違う)")
    }
}
