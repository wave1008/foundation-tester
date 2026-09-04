// 「ブリッジの宛先ホスト」が**必ず**クライアントへ渡ることのソース走査。
//
// `BridgeClient(port:)` の host は既定で 127.0.0.1。シミュレータ・USB トンネル・Android では
// それで合うので、**渡し忘れてもコンパイルは通り、テストも緑のまま**、LAN 経由の実機でだけ
// 「接続拒否」になる(2026-09-04 iPhone 13: xcuitest の SystemUIDriver が host 無しで作られ、
// 不在確認・遅延 exist・アラート操作 = システム UI 層を参照するステップだけ 18/34 が赤。
// USB(iproxy)ではループバックで隠れる)。落とすのはここだけ。同型: CommandNamePlumbingTests。

import XCTest
@testable import FTBridgeClient

final class BridgeHostPlumbingTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// **ループバックで正しい**呼び出し元(理由つき)。ここに足すときは理由を書く
    private let loopbackByConstruction: [String: String] = [
        "Sources/FTBridgeClient/BridgeClient.swift": "init 自身",
        "Sources/FTBridgeClient/InAppDriver.swift": "in-app はシミュレータ専用(dylib 注入は実機不可)",
        "Sources/FTBridgeClient/InAppLauncher.swift": "同上(注入先のプローブ)",
        "Sources/FTAndroid/AndroidBridge.swift": "adb forward の先は常にループバック",
    ]

    /// init(port:host:…) で host を受け取るラッパー。受け取った値以外を渡してはいけない
    private let passesHostThrough: Set<String> = [
        "Sources/FTBridgeClient/SystemUIDriver.swift",
        "Sources/FTBridgeClient/AppAttachDriver.swift",
    ]

    /// `BridgeClient(` の全呼び出しが `host:` を渡していること
    func testEveryBridgeClientConstructionPassesHost() throws {
        let sources = repoRoot.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        var missing: [String] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
            if loopbackByConstruction[relative] != nil { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard line.contains("BridgeClient(") else { continue }
                // 型名・doc コメント・`as? BridgeClient` 等は呼び出しではない
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                guard line.range(of: #"BridgeClient\(\s*(port|$)"#, options: .regularExpression) != nil
                else { continue }
                scanned += 1
                // 引数は複数行に跨る。括弧が閉じるまでを窓にする
                var joined = ""
                var depth = 0
                var started = false
                for candidate in lines[index...] {
                    joined += candidate + "\n"
                    for ch in candidate {
                        if ch == "(" { depth += 1; started = true }
                        if ch == ")" { depth -= 1 }
                    }
                    if started, depth <= 0 { break }
                }
                if !joined.contains("host:") {
                    missing.append("\(relative):\(index + 1) \(trimmed)")
                }
                // ラッパー(呼び手から host を受け取る型)は**その引数をそのまま**渡すこと ——
                // `host: BridgeEndpoint.loopbackHost` と書けば上の検査は通るが、実機では同じ穴
                if passesHostThrough.contains(relative), !joined.contains("host: host") {
                    missing.append("\(relative):\(index + 1) \(trimmed) — must forward its host parameter")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 10, "走査が呼び出しを拾えていない(パターンを見直す)")
        XCTAssertEqual(missing, [], "host: を渡していない BridgeClient の生成(LAN 経由の実機で接続拒否になる)")
    }
}
