// 利用者に見せる行へ**素の** `\(error)` を埋めない(列挙値のダンプになる)。
//
// 2026-09-18 の負荷テストで実際に出ていた: 「the in-app bridge did not respond in time:
// bridgeConnectionRefused(context: FTCore.DriverErrorContext(engine: …iosXCUITest …), detail: …)」
// 「failed to restore original orientation: bridgeConnectionRefused(context: …)」。
// 正しい形は `ErrorText.user(_:)`(または一次情報だけを組み立てる専用の関数)。

import XCTest
@testable import FTCore

final class ErrorTextScanTests: XCTestCase {
    /// ConsoleOut の 1 行に素の `\(error)` / `\(err)` が入っていないか。**走査対象は Sources 全体**
    func testNoConsoleLineInterpolatesARawError() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 100, "走査が Sources に届いていない")

        var offenders: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                guard trimmed.contains("ConsoleOut.") else { continue }
                guard trimmed.contains("\\(error)") || trimmed.contains("\\(err)") else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1) \(trimmed)")
            }
        }
        XCTAssertEqual(offenders, [], "ErrorText.user(_:) を通すこと:\n" + offenders.joined(separator: "\n"))
    }

    func testUserTextPrefersTheLocalizedDescription() {
        let context = DriverErrorContext(engine: .iosInApp, physicalDevice: false)
        let text = ErrorText.user(DriverError.bridgeConnectionRefused(context: context, detail: "boom"))
        XCTAssertFalse(text.contains("bridgeConnectionRefused"), text)
        XCTAssertFalse(text.contains("DriverErrorContext"), text)
        XCTAssertTrue(text.contains("boom"), text)
    }
}
