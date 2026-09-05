// プロセス生存判定は `ProcessLiveness`(Sources/FTCore/ProcessLiveness.swift)の1箇所に置く
// (CLAUDE.md §判定は1箇所に置く)。`kill(pid, 0)` はゾンビにも成功するので、新しい呼び出しを
// 見た目で見逃さないようソースを走査して固定する —— **新しい `kill(x, 0)` を書いたら落ちる**。
//
// 例外は2つだけ、どちらも「自分が起こした子を SIGKILL する直前の確認」で、ゾンビでも直後に
// kill するだけなので誤判定の実害が無い(生存判定として使っていない):
//   - Sources/FTCore/ScenarioHost.swift
//   - Sources/FTCore/IOSSimulatorVideoRecorder.swift

import Foundation
import XCTest

final class ProcessLivenessSourceScanTests: XCTestCase {

    private static let exempt: Set<String> = [
        "Sources/FTCore/ScenarioHost.swift",
        "Sources/FTCore/IOSSimulatorVideoRecorder.swift",
    ]

    /// `kill(<式>, 0)` の呼び出し形(第2引数がリテラル 0 のシグナル送信 = 生存確認のみに使う形)。
    /// SIGTERM/SIGKILL 等の実際のシグナル送信には一致しない
    private static let pattern = try! NSRegularExpression(pattern: #"kill\([^,()]+,\s*0\s*\)"#)

    private struct Hit {
        let file: String
        let line: Int
        let text: String
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FTCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
    }

    private static func scan() -> [Hit] {
        let root = repoRoot
        let sourcesRoot = root.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var found: [Hit] = []
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            guard url.pathExtension == "swift" else { continue }
            let relative = "Sources" + url.path.dropFirst(sourcesRoot.path.count)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, substring) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(substring)
                // 行コメント(`//`/`///`)より右側は無視する —— ProcessLiveness.swift の doc は
                // この呼び出し形を文章として説明のために書いており、実際の呼び出しではない
                let codePart = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
                let nsCode = codePart as NSString
                let matches = Self.pattern.matches(in: codePart, range: NSRange(location: 0, length: nsCode.length))
                guard !matches.isEmpty else { continue }
                found.append(Hit(file: relative, line: index + 1, text: line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return found
    }

    private static let hits: [Hit] = scan()

    func testKillWithSignalZeroOnlyAppearsInTheExemptedFiles() {
        let offenders = Self.hits.filter { !Self.exempt.contains($0.file) }
        XCTAssertTrue(offenders.isEmpty, """
            生存判定に `kill(pid, 0)` を直接使わない —— ゾンビにも成功するので \
            ProcessLiveness.isAlive(_:) を使うこと(Sources/FTCore/ProcessLiveness.swift)。
            \(offenders.map { "\($0.file):\($0.line) \($0.text)" }.joined(separator: "\n"))
            """)
    }
}
