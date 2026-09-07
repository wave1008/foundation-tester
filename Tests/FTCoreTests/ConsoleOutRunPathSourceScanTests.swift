// 出力は `FTCore.ConsoleOut` だけを通す(Sources/FTCore/ConsoleOut.swift の doc 参照)。
// 素の `print(` はパイプ相手だと libc のブロックバッファに載り、**行の途中で flush されうる**。
// その隙に無防備な `FileHandle.standard*.write(` が割り込むと1行が裂ける(実例:
// `exist "#row_01"` が `ex` と `ist "#row_01"` に分裂)。stdout と stderr を同じ宛先へ束ねる
// (`fleetest ... > log 2>&1` / FleetRunner.runEntry が子の両者を1本の Pipe へ合流させる)と、
// どのサブコマンドでも起こりうる。
//
// **経路ごとに「ここは安全」と論じない**。走査対象のターゲット全域でゼロ許容にし、
// 例外は allowlist に等号で固定する —— 黙って増やせないようにするのが目的。
//
// **生バイトを stdout へ流すターゲット(fleetest-simstream / -androidstream / -devicepoll)は
// 走査しない**: あちらの stdout は行ではなく映像フレームで、ConsoleOut の契約(行 or 自前区切りの
// バイト列)に当てはまらない。

import Foundation
import XCTest

final class ConsoleOutRunPathSourceScanTests: XCTestCase {

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FTCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Sources")
    }

    /// 走査するターゲット(行を書く側すべて)
    private static let scannedTargets = [
        "fleetest", "fleetest-mcp", "FTCore", "FTBridgeClient",
        "FTAndroid", "FTScenarioRunner", "FTRemote", "FTDSL", "FTFoundationModels",
    ]

    /// **例外は2つだけ**。増やすときはここに理由を書く(等号で固定してあるので黙っては増えない)
    ///   - ConsoleOut.swift: 口そのものの実装(と doc の中の `print(` の言及)
    ///   - ParentDeathWatch.swift: kqueue のコールバック文脈から呼ばれるのでロックを取らせない
    private static let allowed: Set<String> = [
        "FTCore/ConsoleOut.swift",
        "FTCore/ParentDeathWatch.swift",
    ]

    /// `print(` の直前が識別子文字(英数字/`_`)でない = 「Fingerprint(」等の識別子の一部ではない
    /// 本物の呼び出し形だけを拾う
    private static let printPattern = try! NSRegularExpression(pattern: #"(?:^|[^a-zA-Z0-9_])print\("#)
    private static let rawWritePattern = try! NSRegularExpression(
        pattern: #"FileHandle\.standard(?:Output|Error)\.write\("#)

    /// コメント(`//` より右)を落とした行配列
    private static func codeLines(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.components(separatedBy: "\n").map { $0.components(separatedBy: "//")[0] }
    }

    private static func swiftFiles(in target: String) -> [URL] {
        let root = sourcesRoot.appendingPathComponent(target)
        guard let walker = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted {
            $0.path < $1.path
        }
    }

    /// 走査対象のどこにも素の print(/FileHandle.standard*.write( が残っていないこと
    func testNoBareConsoleWritesOutsideConsoleOut() throws {
        var offenders: [String] = []
        var scannedFiles = 0
        for target in Self.scannedTargets {
            for url in Self.swiftFiles(in: target) {
                let relative = target + "/" + url.path
                    .components(separatedBy: "/Sources/" + target + "/").last!
                if Self.allowed.contains(relative) { continue }
                scannedFiles += 1
                for (index, line) in try Self.codeLines(url).enumerated() {
                    let ns = line as NSString
                    let range = NSRange(location: 0, length: ns.length)
                    let hasPrint = !Self.printPattern.matches(in: line, range: range).isEmpty
                    let hasRawWrite = !Self.rawWritePattern.matches(in: line, range: range).isEmpty
                    if hasPrint || hasRawWrite {
                        offenders.append("\(relative):\(index + 1): "
                                         + line.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
        // **走査が空振りしていないことを先に確かめる**(パスがズレると0件で緑になる)
        XCTAssertGreaterThan(scannedFiles, 100, "走査対象が見つかっていない(パスの解決を疑う)")
        XCTAssertEqual(offenders, [],
                       "出力は FTCore.ConsoleOut.out/err を通すこと(素の print / FileHandle 直書きは"
                       + "行が裂ける)。例外を足すなら allowed へ理由付きで:\n"
                       + offenders.joined(separator: "\n"))
    }

    /// **例外の集合を等号で固定する**。allowlist が育つのを機械で止める
    func testTheAllowlistIsExactlyTheTwoKnownExceptions() {
        XCTAssertEqual(Self.allowed, ["FTCore/ConsoleOut.swift", "FTCore/ParentDeathWatch.swift"])
    }
}
