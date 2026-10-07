// XCUITest ランナーで、一致しないかもしれない問い合わせ(`firstMatch`)に直接 `snapshot()` を撃たない。
// 一致する要素が無いと `snapshot()` は約 2 秒待ってから失敗する(実測 Xcode 27・Simulator: 焦点の無い画面の
// /snapshot が焦点の問い合わせだけで毎回 2.05s → `exists` を先に聞いて 0.02s)。アプリの木の
// `app.snapshot()` / `root` 以外の `.snapshot()` は、同じ行で `exists` を確かめてから読む

import XCTest

final class RunnerQuerySnapshotGuardTests: XCTestCase {

    func testQuerySnapshotsAreGuardedByExists() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runner/FleetestRunnerUITests")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(names.contains("BridgeRouter.swift"), "走査が Runner に届いていない")
        var checked = 0
        var offenders: [String] = []
        for name in names {
            let lines = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                .components(separatedBy: "\n")
            for (i, raw) in lines.enumerated() {
                let line = raw.components(separatedBy: "//").first ?? raw
                guard line.contains(".snapshot()"),
                      !line.contains("app.snapshot()"), !line.contains("springboard.snapshot()") else { continue }
                checked += 1
                if !line.contains(".exists") { offenders.append("\(name):\(i + 1): \(raw.trimmingCharacters(in: .whitespaces))") }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 2, "走査が焦点の問い合わせ(withFocusedFlag / focusMark)に届いていない")
        XCTAssertEqual(offenders, [], "exists を確かめずに問い合わせへ snapshot() を撃っている")
    }
}
