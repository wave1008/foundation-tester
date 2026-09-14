// `Process.waitUntilExit()` を Sources に書かない(Shell.swift の ProcessExitWait 宣言の理由 = RunLoop 通知に
// 依存し、Swift Concurrency の協調スレッド上では終了通知を取りこぼして永久ハングし得る)。
// 待つときは `ProcessExitWait.prepare*`(run() より前に設定)を使う。9/6 台帳 §3.1 の残件で
// RunnerProfileTransfer / RemoteMonitorFanout / RemoteDeviceFanout / RemoteProjectSync の 4 箇所を置き換えた。
// 例外は専用 Thread の診断(`sample`)だけ —— 増やすときは理由をここへ書く

import XCTest

final class ProcessWaitSourceScanTests: XCTestCase {
    private static let allowed: Set<String> = [
        // OCR の刺さりを採る診断。専用 Thread(Thread.sleep 済み)の上で /usr/bin/sample を待つだけ
        "Sources/FTCore/RegionText.swift",
    ]

    func testNoWaitUntilExitOutsideTheAllowlist() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !Self.allowed.contains(relative) else { continue }
            let code = try String(contentsOf: url, encoding: .utf8)
            for line in code.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.contains("waitUntilExit()") { offenders.append(relative); break }
            }
        }
        XCTAssertEqual(offenders, [], "waitUntilExit() が残っている(ProcessExitWait.prepare* を使うこと)")
    }
}
