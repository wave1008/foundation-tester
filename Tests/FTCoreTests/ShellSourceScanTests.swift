// `readDataToEndOfFile` を子プロセスのパイプに使わない(CLAUDE.md「Shell.run は子孫ごと止め、
// 出力の EOF を待ち切らない」)。EOF まで戻らないので期限が置けず、刺さった adb / 未知の対話
// プロンプトで永久に返らない。子プロセスは `Shell.run` / `Shell.runData`(timeout・stdin・
// 子孫ごとの停止を持つ)を通す。**新しい `readDataToEndOfFile` を Sources に書いたら落ちる**。
//
// 例外(自分の stdin を EOF まで読む = 呼び手が閉じる契約で、子プロセスではない)は
// `allowed` に理由付きで登録する。

import Foundation
import XCTest

final class ShellSourceScanTests: XCTestCase {

    /// Sources からの相対パス → 許す理由
    private static let allowed: [String: String] = [
        "fleetest/ApiApplyHealCommand.swift": "自分の stdin(拡張が JSON を書いて閉じる契約)。子プロセスではない",
        "FTCoreSimShim/FTCoreSimShim.m": "`xcode-select -p`(端末に触らない・孫無し・出力 1 行)。刺さる形が無い",
        "fleetest-simstream/main.m": "同上(`xcode-select -p`)",
    ]

    func testNoChildPipeIsReadToEndOfFileOutsideTheAllowlist() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        var offenders: [String] = []
        var seenAllowed: Set<String> = []
        for case let url as URL in enumerator where ["swift", "m"].contains(url.pathExtension) {
            let source = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//")[0]
                guard code.contains("readDataToEndOfFile") else { continue }
                if Self.allowed[relative] != nil {
                    seenAllowed.insert(relative)
                } else {
                    offenders.append("\(relative):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], """
            子プロセスのパイプを readDataToEndOfFile で読んでいる —— Shell.run / Shell.runData \
            (timeout / stdin 付き)へ寄せる。子プロセスでないなら allowed に理由を書く
            """)
        XCTAssertEqual(seenAllowed, Set(Self.allowed.keys),
                       "allowed に載っているのに実在しない(消えたら登録も消す)")
    }
}
