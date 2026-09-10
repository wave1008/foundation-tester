// 供給フェーズの lease(SupplyLeaseHolder)を orchestrator へ手放す配線を固定する。
//
// **型では守れない継ぎ目**: 注入する writeRunLease から handOff を落としても run は緑のまま通り、
// 担当を終えた台の lease を供給側のハートビートが run の最後まで書き戻す(モニターの配信が
// 張られては畳まれる)。`fleetest run` と `fleetest api run` は注入を別々に持つので両方を見る。

import XCTest

final class SupplyLeaseHandOffWiringTests: XCTestCase {

    private static let sources = ["Sources/fleetest/ProfileRunner.swift",
                                  "Sources/fleetest/ApiRunCommand.swift"]

    private static func code(_ path: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    /// 各ファイルの writeRunLease は1本で、**書いた後に**手放す(逆順だと一瞬 lease が消える)
    func testEveryInjectedRunLeaseWriterHandsTheKeyOffAfterWriting() throws {
        for path in Self.sources {
            let lines = try Self.code(path)
            let starts = lines.indices.filter { lines[$0].hasPrefix("writeRunLease: {") }
            XCTAssertEqual(starts.count, 1, "\(path): writeRunLease の注入が \(starts.count) 本")
            guard let start = starts.first,
                  let end = lines[start...].firstIndex(where: { $0 == "}," }) else {
                return XCTFail("\(path): writeRunLease のクロージャが読めない(走査の前提が崩れた)")
            }
            let body = Array(lines[start..<end])
            guard let write = body.firstIndex(where: { $0.hasPrefix("RunLease.write(") }) else {
                return XCTFail("\(path): writeRunLease が RunLease.write を呼んでいない")
            }
            guard let handOff = body.firstIndex(where: { $0 == "supplyLease?.handOff(key: key)" }) else {
                return XCTFail("\(path): writeRunLease が供給側の lease を手放していない")
            }
            XCTAssertGreaterThan(handOff, write, "\(path): 書く前に手放している")
        }
    }
}
