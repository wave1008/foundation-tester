// iOS 27 Simulator の PosterBoard(壁紙ギャラリー)は、版を作り直すたびにスナップショットキャッシュを作り、
// 古い版の分を消さない(Sources/FTBridgeClient/SimulatorPosterCache.swift の doc)。
// **simctl で boot / bootstatus -b(Shutdown なら boot する)を撃つ関数は、必ず同じ関数の中で、
// その呼び出しより前に `SimulatorBootCleanup.beforeBoot`(壁紙のスナップショットと古い統合ログの掃除)を呼ぶ**。新しい boot 経路を足して purge を呼び忘れても
// コンパイルも実行時の失敗も起きない(起動が遅くキャッシュが溜まるだけ)ので、この走査で守る。

import Foundation
import XCTest

final class SimulatorPosterCachePurgeWiringTests: XCTestCase {

    private static let purgeCall = "SimulatorBootCleanup.beforeBoot("
    // `Shell.run(["xcrun", "simctl", "boot", …])` / `…, "bootstatus", …` の形だけを狙う
    // (コメント・エラー文言の素の文字列は事前に "//" 以降を落とすので当たらない)
    private static let bootPattern = #""simctl"\s*,\s*"(boot|bootstatus)""#

    func testEverySimctlBootCallHasAPosterCachePurgeInTheSameFunction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var bootCalls = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            // 定義そのものは対象外(purge の中に boot 呼び出しは無いが、名前の一致で誤検知しない)
            guard url.lastPathComponent != "SimulatorBootCleanup.swift" else { continue }
            let codeLines = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n").map(Self.stripLineComment)
            for (index, code) in codeLines.enumerated() {
                guard code.range(of: Self.bootPattern, options: .regularExpression) != nil else { continue }
                bootCalls += 1
                guard let range = Self.functionRange(codeLines: codeLines, containing: index) else {
                    offenders.append("\(url.lastPathComponent):\(index + 1) (enclosing func not found)")
                    continue
                }
                // **boot より前に**あること(後ろに置くと台は Booted なので purge は何もしない)
                if !codeLines[range.lowerBound...index].joined(separator: "\n").contains(Self.purgeCall) {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        // 既知4箇所(SimulatorBoot.ensureBooted / DeviceBooter.bootOne /
        // ProfileWorkerFactory.recoverFrozenIOSWorkers(2行) / BridgeProvisioner.rebootSimulator)。
        // 走査が Sources に届いていることの確認(0 件だと「常に緑」と区別できない)
        XCTAssertGreaterThanOrEqual(bootCalls, 4,
                                    "simctl boot / bootstatus -b の呼び出しが見つからない —— 走査の前提が崩れた")
        XCTAssertEqual(offenders, [],
                       "起動直前に SimulatorBootCleanup.beforeBoot を呼んでいない simctl boot 経路: "
                       + offenders.joined(separator: ", "))
    }

    private static func stripLineComment(_ line: String) -> String {
        line.components(separatedBy: "//")[0]
    }

    /// `targetIndex` を含む関数の行範囲(`func` 宣言行 〜 対応する閉じ括弧の行)。近似(コメント除去済みの
    /// 行だけでブレースを数える)—— 対象関数に文字列リテラル中の `{`/`}` は無いので足りる
    private static func functionRange(codeLines: [String], containing targetIndex: Int) -> ClosedRange<Int>? {
        var funcStart: Int?
        var i = targetIndex
        while i >= 0 {
            if codeLines[i].range(of: #"\bfunc\s+\w"#, options: .regularExpression) != nil {
                funcStart = i
                break
            }
            i -= 1
        }
        guard let start = funcStart else { return nil }
        var depth = 0
        var opened = false
        for j in start..<codeLines.count {
            for ch in codeLines[j] {
                if ch == "{" { depth += 1; opened = true }
                if ch == "}" { depth -= 1 }
            }
            if opened, depth <= 0 { return start...j }
        }
        return start...(codeLines.count - 1)
    }
}
