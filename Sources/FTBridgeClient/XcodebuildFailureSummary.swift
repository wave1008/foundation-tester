// xcodebuild の失敗出力から人が読む本文を組み立てる。
//
// `-destination` が実体を見つけられないと xcodebuild は `error:` 行を先に書き、その**後**に
// 対象外だった宛先を1つ1行で列挙する(`{ platform:… } doesn't match …` が数十行)。
// 単純な末尾30行(Shell.Result.tail)では、この一覧に本当の原因行が押し出されて見えなくなる
// (実測: `Unable to find a device matching the provided destination specifier` が
// 一覧の後ろに隠れ、画面には一覧しか出なかった)。

import Foundation

public enum XcodebuildFailureSummary {
    /// - Parameters:
    ///   - output: xcodebuild の生出力(全体。末尾30行に切ってから渡すと原因行ごと切り捨て得るため不可)
    ///   - tailLineCount: 呼び出し側の既存の tail と同じ上限を渡すこと
    public static func summarize(output: String, tailLineCount: Int) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // 行番号で管理する(テキスト一致で dedup すると、たまたま同文の別行を消してしまう)
        let usableIndices = lines.indices.filter { !isIneligibleDestinationLine(lines[$0]) }
        let errorIndices = usableIndices.filter { lines[$0].contains("error:") }
        guard !errorIndices.isEmpty else {
            // 見つからなければ単純な末尾(署名エラー等はここに乗らないので変えない)
            return lines.suffix(tailLineCount).joined(separator: "\n")
        }
        let errorIndexSet = Set(errorIndices)
        let remainderIndices = usableIndices.filter { !errorIndexSet.contains($0) }
        let tailRemainderIndices = remainderIndices.suffix(max(0, tailLineCount - errorIndices.count))
        return (errorIndices + Array(tailRemainderIndices)).prefix(tailLineCount)
            .map { lines[$0] }.joined(separator: "\n")
    }

    /// 対象外の宛先1件を表す行(`{ platform:… }`)と、その一覧の見出し行
    private static func isIneligibleDestinationLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("{ platform:") || trimmed.contains("Ineligible destinations")
    }
}
