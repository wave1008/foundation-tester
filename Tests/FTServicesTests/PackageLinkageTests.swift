import XCTest

/// 保証するのは「シナリオ実行バイナリの推移的なリンク依存に FTServices / Yams が入らないこと」だけ。
/// Package.swift をテキストで読む(SwiftPM のグラフは参照しない)。SwiftPM は使う product に関わらず
/// パッケージを取得・解決するので、受け手でも Yams の取得は起きる(リンクだけを避ける)。
final class PackageLinkageTests: XCTestCase {
    private struct TargetBlock {
        let name: String
        let body: String
    }

    private static var packageText: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FTServicesTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Package.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func blocks() -> [TargetBlock] {
        let openers = [".target(", ".executableTarget(", ".testTarget(", ".macro("]
        var lines = packageText.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.contains("targets: [") }) { lines = Array(lines[start...]) }
        var result: [TargetBlock] = []
        var current: [String] = []
        func flush() {
            let body = current.joined(separator: "\n")
            if let range = body.range(of: "name: \""),
               let end = body[range.upperBound...].firstIndex(of: "\"") {
                result.append(TargetBlock(name: String(body[range.upperBound..<end]), body: body))
            }
            current = []
        }
        for raw in lines {
            var line = raw
            if let comment = line.range(of: "//") { line = String(line[..<comment.lowerBound]) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if openers.contains(where: { trimmed.hasPrefix($0) }) { flush() }
            current.append(line)
        }
        flush()
        return result
    }

    func testFTServicesDependsOnYams() throws {
        let block = try XCTUnwrap(Self.blocks().first { $0.name == "FTServices" }, "FTServices target not found")
        XCTAssertTrue(block.body.contains("\"Yams\""))
    }

    func testScenarioSideTargetsDoNotDependOnFTServicesOrYams() throws {
        let blocks = Self.blocks()
        let scenarioSide = blocks.filter {
            $0.name == "FTCore" || $0.name == "FTDSL" || $0.name == "FTScenarioRunner"
                || $0.name.hasPrefix("fleetest-scenarios-")
        }
        // 走査が空振りしていないこと: 3つの名前つきターゲットは必ずある
        XCTAssertTrue(["FTCore", "FTDSL", "FTScenarioRunner"].allSatisfy { name in scenarioSide.contains { $0.name == name } })
        for block in scenarioSide {
            XCTAssertFalse(block.body.contains("FTServices"), "\(block.name) must not depend on FTServices")
            XCTAssertFalse(block.body.contains("Yams"), "\(block.name) must not depend on Yams")
        }
    }
}
