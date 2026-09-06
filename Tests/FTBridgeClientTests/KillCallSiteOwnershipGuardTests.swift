// BridgeLauncher.swift / IOSDeviceTransport.swift の kill(pid, SIGTERM/SIGKILL) 呼び出しは、
// PID 再利用(TTL 自主終了後に .pid ファイルが残ったまま無関係プロセスがその pid を拾う)で
// 無関係プロセスを撃たないよう、必ず「その pid が今も自分たちのプロセスか」を確認してから
// 撃つこと(CLAUDE.md「プロセスの生存管理は3つの定義元に寄せる」)。
//
// 関数単位で機械的に確認する: kill( を含む関数の本体に、所有権を確認している証拠
// (FleetestRunner/iproxy のコマンド照合、または isOurRunner/isIproxy の呼び出し)が
// 含まれているかを見る。**新しい無防備な kill( を書いたら落ちる**。

import Foundation
import XCTest

final class KillCallSiteOwnershipGuardTests: XCTestCase {

    private static let markers = ["FleetestRunner", "iproxy", "isOurRunner(", "isIproxy("]

    /// 既に確認済みの pid だけを受け取る契約の共有部品(呼び出し元 stop()/stopAndWait()/
    /// stopAll()/stopMatching() 側で確認してから渡す)。単体では判定語彙が現れないので対象外
    private static let exemptFunctions: Set<String> = [
        "BridgeLauncher.confirmDeathThenRemovePidFile",
        "BridgeLauncher.confirmDeaths",
        // stopMatching は udid 文字列がコマンドラインに含まれることを確認してから撃つ
        // (このバグ修正のスコープ外。CLAUDE.md 指示によりここは変更しない)
        "BridgeLauncher.stopMatching",
    ]

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private struct FunctionBody {
        let name: String
        let text: String
    }

    /// ソースを「トップレベル/ネストした関数」単位へ大まかに分割する。波括弧のネストを数えて
    /// 本体の終端を決めるだけの簡易パーサ(この2ファイルには波括弧を含む文字列リテラルが
    /// 無いことを前提にする。増えたら見直す)
    private func functions(in source: String, file: String) -> [FunctionBody] {
        var results: [FunctionBody] = []
        let pattern = try! NSRegularExpression(pattern: #"func\s+(\w+)\s*\("#)
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches {
            guard let matchRange = Range(match.range, in: source),
                  let nameRange = Range(match.range(at: 1), in: source) else { continue }
            let name = String(source[nameRange])
            guard let braceStart = source.range(of: "{", range: matchRange.upperBound..<source.endIndex)
            else { continue }
            var depth = 0
            var idx = braceStart.lowerBound
            var end = source.endIndex
            while idx < source.endIndex {
                let ch = source[idx]
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        end = source.index(after: idx)
                        break
                    }
                }
                idx = source.index(after: idx)
            }
            results.append(FunctionBody(name: "\(file).\(name)", text: String(source[braceStart.lowerBound..<end])))
        }
        return results
    }

    func testEveryKillCallIsGuardedByAnOwnershipCheck() throws {
        for relativePath in ["Sources/FTBridgeClient/BridgeLauncher.swift",
                              "Sources/FTBridgeClient/IOSDeviceTransport.swift"] {
            let url = repoRoot().appendingPathComponent(relativePath)
            let source = try String(contentsOf: url, encoding: .utf8)
            let file = (relativePath as NSString).lastPathComponent
                .replacingOccurrences(of: ".swift", with: "")
            for function in functions(in: source, file: file) {
                guard function.text.contains("kill(") else { continue }
                guard !Self.exemptFunctions.contains(function.name) else { continue }
                let hasMarker = Self.markers.contains { function.text.contains($0) }
                XCTAssertTrue(hasMarker, """
                    \(function.name) が kill( を呼ぶが、pid の所有権確認語彙\
                    (\(Self.markers.joined(separator: "/")))が見当たらない。PID 再利用で無関係\
                    プロセスを撃たないよう、撃つ前に isOurRunner/isIproxy 相当の確認を入れること。
                    """)
            }
        }
    }
}
