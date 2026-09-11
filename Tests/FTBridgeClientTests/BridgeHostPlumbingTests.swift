// 「ブリッジの宛先ホスト」が**必ず**クライアントへ渡ることのソース走査。
//
// `BridgeClient(port:)` の host は既定で 127.0.0.1。シミュレータ・USB トンネル・Android では
// それで合うので、**渡し忘れてもコンパイルは通り、テストも緑のまま**、LAN 経由の実機でだけ
// 「接続拒否」になる(2026-09-04 iPhone 13: xcuitest の SystemUIDriver が host 無しで作られ、
// 不在確認・遅延 exist・アラート操作 = システム UI 層を参照するステップだけ 18/34 が赤。
// USB(iproxy)ではループバックで隠れる)。落とすのはここだけ。同型: CommandNamePlumbingTests。
//
// **`endpoint:` 形も合格**とする —— `BridgeEndpoint` は host・port・token を丸ごと持つので、
// 宛先だけ取り出して渡し直す余地が無い(`host:` より強い)。トークンの渡し忘れは
// BridgeClientPhysicalTokenTests が別に見る。
//
// **host だけでは足りない**(2026-09-08 iPhone SE3・USB): usb トンネルの実機は host が
// ループバックのまま token を要求するので、`host:` だけ渡した生成は token を推測できず
// (BridgeClient.inferredToken はループバック + physicalUDID 無しで短絡)401 になる。
// モニターの scanBridgeStatuses がこの形で、**生きているブリッジが「未起動」に見えた**。
// 生成には `endpoint:`(記録を丸ごと)か `physicalUDID:`(実機だと分かっている)を必ず添える。

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
                // `endpoint:` 形は host と token を丸ごと運ぶ(host: より強い) ——
                // 宛先を取り出して渡し直す余地が無いので、渡し忘れが起こり得ない
                if !joined.contains("host:") && !joined.contains("endpoint:") {
                    missing.append("\(relative):\(index + 1) \(trimmed)")
                }
                // host だけでは usb トンネルの token を解決できない(ファイル冒頭)
                if !joined.contains("endpoint:") && !joined.contains("physicalUDID:") {
                    missing.append("\(relative):\(index + 1) \(trimmed)"
                                   + " — must pass endpoint: or physicalUDID: (usb tunnel token)")
                }
                // ラッパー(呼び手から host を受け取る型)は**その引数をそのまま**渡すこと ——
                // `host: BridgeEndpoint.loopbackHost` と書けば上の検査は通るが、実機では同じ穴
                if passesHostThrough.contains(relative),
                   !joined.contains("host: host"), !joined.contains("endpoint:") {
                    missing.append("\(relative):\(index + 1) \(trimmed) — must forward its host parameter")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 10, "走査が呼び出しを拾えていない(パターンを見直す)")
        XCTAssertEqual(missing, [], "宛先か token を運べていない BridgeClient の生成"
                       + "(LAN 経由の実機で接続拒否 / usb トンネルの実機で 401 になる)")
    }

    /// **シナリオの子プロセスへ渡す iOS の接続(`port:` を持つ `DriverConnection(`)も host と実機判定を運ぶ**。
    /// 子は `DriverConnection.host` / `physical` から BridgeClient を作るので、ポートだけ渡すと
    /// 127.0.0.1・physical=false で走る(2026-09-11 物理 iPhone 13: MCP の ft_run_scenario の
    /// プロファイル無し経路がこの形で、LAN の実機に接続拒否 3/3)。上の走査は `BridgeClient(` しか見ないので網の外だった
    func testEveryIOSDriverConnectionCarriesHostAndPhysical() throws {
        let sources = repoRoot.appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        var missing: [String] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("DriverConnection(") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
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
                // ポートを持たない接続(Android・dry-run)は宛先が要らない
                guard joined.contains("port:") else { continue }
                scanned += 1
                if !joined.contains("host:") || !joined.contains("physical:") {
                    missing.append("\(relative):\(index + 1) \(trimmed)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 0, "走査が呼び出しを拾えていない(パターンを見直す)")
        XCTAssertEqual(missing, [], "host と physical を運ばない iOS の DriverConnection の生成"
                       + "(子プロセスが LAN の実機で接続拒否 / usb トンネルの実機で 401 になる)。"
                       + " --port 直指定なら PortDirectIOSTarget(port:).connection(simulatorUDID:) を使う")
    }
}
