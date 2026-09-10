// `FileHandle.availableData` を読むループは**1回ごとに autoreleasepool で区切る**。
//
// `availableData` が返す NSData は自動解放で、抜けないループ(子プロセスの出力を EOF まで読む
// `while true` / `Thread` / 長く生きる readabilityHandler)の中では区切りが来るまで1つも解放されない。
// 実害: 拡張が1日じゅう生かす `api monitor` がリモートの監視の出力を読むループで溜め続け、
// 稼働 1 時間 35 分で約 1.2 GB(読み込みの塊 6 万 7 千個・1 個 16 KB 前後)。
// **新しい `availableData` を Sources に書いて区切りを忘れると落ちる**(型では守れない継ぎ目)。
//
// 判定は「`availableData` の行から上へ数行以内に `autoreleasepool` があるか」。区切りの内側で
// 読む形(`let eof: Bool = autoreleasepool { let chunk = handle.availableData ... }`)に揃えてある。

import Foundation
import XCTest

final class AvailableDataAutoreleaseScanTests: XCTestCase {

    /// `availableData` の行から上へ遡って `autoreleasepool` を探す行数
    private static let lookback = 4

    func testEveryAvailableDataReadIsInsideAnAutoreleasePool() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var reads = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//")[0]
                guard code.contains(".availableData") else { continue }
                reads += 1
                let window = lines[max(0, index - Self.lookback)...index]
                    .map { $0.components(separatedBy: "//")[0] }
                if !window.contains(where: { $0.contains("autoreleasepool") }) {
                    offenders.append("\(relative):\(index + 1)")
                }
            }
        }
        // 走査が Sources に届いていることの確認(0 件だと「常に緑」と区別できない)
        XCTAssertGreaterThanOrEqual(reads, 6, "availableData の読みが見つからない —— 走査の前提が崩れた")
        XCTAssertEqual(offenders, [],
                       "availableData を autoreleasepool の外で読んでいる(抜けないループで NSData が溜まる): "
                       + offenders.joined(separator: ", "))
    }
}
