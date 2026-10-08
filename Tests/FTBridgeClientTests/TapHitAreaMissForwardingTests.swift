// `lastTapHitAreaMiss` を**包むドライバが必ず素通しする**こと。既定実装は nil なので、転送を足し忘れたラッパーが
// 1つ挟まるだけで、in-app の当たり判定の申告がそのエンジン構成では一度も注記にならない(テストも緑のまま)。
// AddMediaForwardingTests と同じ作法: `lastActionNote` を持つ型(= 操作の申告を運ぶ型)を走査して検出する。

import XCTest

final class TapHitAreaMissForwardingTests: XCTestCase {

    func testEveryDriverCarryingLastActionNoteAlsoCarriesTheHitAreaMiss() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var missing: [String] = []
        var checked = 0
        for dir in ["Sources/FTBridgeClient", "Sources/FTAndroid", "Sources/FTCore"] {
            let base = root.appendingPathComponent(dir)
            let files = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "swift" {
                guard let source = try? String(contentsOf: file, encoding: .utf8),
                      source.contains("var lastActionNote: String?") else { continue }
                checked += 1
                if !source.contains("var lastTapHitAreaMiss: TapHitAreaMiss?") { missing.append(file.lastPathComponent) }
            }
        }
        XCTAssertGreaterThan(checked, 5, "走査対象が見つからない = パスかシグネチャの書式が変わった")
        XCTAssertTrue(missing.isEmpty, "lastActionNote を運ぶ型は lastTapHitAreaMiss も素通しすること: \(missing)")
    }
}
