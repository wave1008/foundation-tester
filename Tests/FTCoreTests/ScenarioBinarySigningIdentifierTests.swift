// `ScenarioHost.pinSigningIdentifier`: シナリオ実行バイナリの署名 ID(Identifier)を製品名に揃える
// (Vision の OCR のコンパイルキャッシュの鍵。docs/performance-tuning.md §3.33)。
// 本物の codesign で確かめる(写した /bin/echo に掛ける = SwiftPM のビルドは要らない)

import XCTest
@testable import FTCore

final class ScenarioBinarySigningIdentifierTests: XCTestCase {

    func testParsesTheIdentifierLine() {
        let output = "Executable=/tmp/x\nIdentifier=fleetest-scenarios-E2E-CMP-55554944f6ff\nFormat=Mach-O thin (arm64)\n"
        XCTAssertEqual(ScenarioHost.signingIdentifier(fromCodesignOutput: output),
                       "fleetest-scenarios-E2E-CMP-55554944f6ff")
        XCTAssertNil(ScenarioHost.signingIdentifier(fromCodesignOutput: "/tmp/x: code object is not signed at all\n"))
    }

    func testPinsTheIdentifierToTheProductNameAndLeavesAPinnedBinaryAlone() throws {
        let name = "fleetest-scenarios-PinProbe"
        let binary = try copiedEcho(named: name)
        XCTAssertNotEqual(try identifier(of: binary), name, "前提: 写しの ID は元(com.apple.echo)のまま")

        var messages: [String] = []
        ScenarioHost.pinSigningIdentifier(binary: binary, productName: name, log: { messages.append($0) })
        XCTAssertEqual(try identifier(of: binary), name)
        XCTAssertEqual(messages, [])
        XCTAssertEqual(try Shell.run([binary.path, "still-runs"]).output, "still-runs\n", "署名し直した後も起動できる")

        // 揃っていれば撃たない(codesign -f は新しい inode に置き換えるので、inode が同じ = 書いていない)
        let inode = try inodeNumber(of: binary)
        ScenarioHost.pinSigningIdentifier(binary: binary, productName: name, log: { messages.append($0) })
        XCTAssertEqual(try inodeNumber(of: binary), inode)
        XCTAssertEqual(messages, [])
    }

    func testReportsAFailureInsteadOfThrowing() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-pin-missing-\(UUID().uuidString)/fleetest-scenarios-Missing")
        var messages: [String] = []
        ScenarioHost.pinSigningIdentifier(binary: missing, productName: "fleetest-scenarios-Missing",
                                          log: { messages.append($0) })
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages.first?.contains("Could not set the code-signing identifier") == true, "\(messages)")
    }

    /// ビルドした出口と、ビルドを省いた出口の両方で揃える(swift test も同じ product を作り直して ID を戻すので、
    /// 省いた run でも ID が UUID 入りのことがある)
    func testBuildPinsOnBothExits() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/ScenarioHost.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public static func build(project: TestProject"))
        let end = try XCTUnwrap(source.range(of: "static func pinSigningIdentifier(", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])

        let skipped = try XCTUnwrap(body.range(of: "skipping the scenario build"))
        let skipReturn = try XCTUnwrap(body.range(of: "return", range: skipped.upperBound..<body.endIndex))
        XCTAssertNotNil(body.range(of: "pinSigningIdentifier(binary:", range: skipped.upperBound..<skipReturn.lowerBound),
                        "ビルドを省いた出口で揃えていない")

        // 条件を足して実質呼ばない形(`if false, …`)も落とすため、ブロックごと決まった形で探す
        let built = try XCTUnwrap(body.range(of: "\"swift\", \"build\", \"--product\""))
        let pinAfterBuild = "        if let runner = try? runnerURL(project: project) {\n"
            + "            pinSigningIdentifier(binary: runner, productName: project.productName, log: log)\n"
            + "        }"
        XCTAssertNotNil(body.range(of: pinAfterBuild, range: built.upperBound..<body.endIndex),
                        "ビルドした後に揃えていない")
    }

    // MARK: - 補助(production の解析を使わずに読む)

    private func copiedEcho(named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: binary)
        return binary
    }

    private func identifier(of binary: URL) throws -> String? {
        let result = try Shell.run(["/usr/bin/codesign", "-dv", binary.path])
        XCTAssertEqual(result.status, 0, result.output)
        return result.output.components(separatedBy: "\n")
            .first { $0.hasPrefix("Identifier=") }?
            .replacingOccurrences(of: "Identifier=", with: "")
    }

    private func inodeNumber(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}
