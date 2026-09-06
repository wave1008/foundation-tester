// `api monitor`(既定 2 秒周期)から呼ばれる simctl は締切付きで撃つ。CoreSimulatorService が
// 凍ると `xcrun simctl list devices -j` は無期限に返らず、モニターの1周ごと固まる。
// 走査で守る呼び出し: SimulatorCatalog.swift の `["xcrun", "simctl", "list", "devices", "-j"]`。

import XCTest
@testable import FTBridgeClient

final class SimulatorCatalogTimeoutTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// 既定はリテラルで固定する(差し替え口経由のテストだけだと既定を戻す変更が緑のまま通る)
    func testSimctlTimeoutIsPinned() {
        XCTAssertEqual(SimulatorCatalog.simctlTimeoutSeconds, 15)
    }

    func testEveryShellRunInSimulatorCatalogCarriesATimeout() throws {
        let path = repoRoot.appendingPathComponent("Sources/FTBridgeClient/SimulatorCatalog.swift")
        let calls = try ShellCallScanner.calls(in: path)
        XCTAssertTrue(calls.contains { $0.contains("\"xcrun\", \"simctl\", \"list\", \"devices\", \"-j\"") },
                      "走査が simctl list の呼び出しを拾えていない(書式を見直す)")
        let untimed = calls.filter { !$0.contains("timeout:") }
        XCTAssertEqual(untimed, [], "締切の無い Shell.run(モニターの周期を握る): \(untimed)")
    }
}

/// `Shell.run(` / `Shell.runData(` の呼び出しを、括弧が閉じるまでの窓で切り出す
/// (引数は複数行に跨る)。FTAndroidTests 側に同じ走査がある(テストターゲットを跨いで共有しない)
enum ShellCallScanner {
    static func calls(in file: URL) throws -> [String] {
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        var calls: [String] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            guard let open = line.range(of: "Shell.run(") ?? line.range(of: "Shell.runData(") else { continue }
            var joined = String(line[open.lowerBound...])
            var depth = 0
            var closed = false
            for ch in joined { if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 } }
            if depth <= 0 { closed = true }
            var next = index + 1
            while !closed, next < lines.count {
                joined += "\n" + lines[next]
                for ch in lines[next] { if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 } }
                if depth <= 0 { closed = true }
                next += 1
            }
            calls.append(joined)
        }
        return calls
    }
}
