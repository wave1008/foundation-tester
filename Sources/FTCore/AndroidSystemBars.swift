// AndroidSystemBars.swift
// `adb shell dumpsys window` の出力から、Android のジェスチャナビゲーションバー(画面下端で
// OS がタッチを消費する帯)の矩形を読む純粋パーサ。ジェスチャナビゲーションの端末では
// この帯が a11y ツリーに載らない(木の根はアクティブウィンドウ1枚だけで、ナビゲーションバーは
// 別ウィンドウ)ため、木の遮蔽判定では原理的に見えない —— スクロールで潜った行がこの帯へ重なると、
// タップは OS に消費されアプリへ届かない(`StepExecutor.liftCoveredTarget` がタップ前に容器を
// 送って避けるための入力になる)

import Foundation

public enum AndroidSystemBars {

    /// - Returns: `type=navigationBars`・`sideHint=BOTTOM`・`visible=true` を持つ最初の
    ///   `InsetsSource` 行から `frame=[l,t][r,b]` を読んだ矩形。行が無い・非表示・矩形が読めない・
    ///   幅高さが0以下のときは nil(呼び手は覆い無し側に倒す)。
    ///   **`mandatorySystemGestures` は見ない** —— タップを実際に消費するのは `navigationBars` の
    ///   帯で、3ボタン navigation でも同じ型で(より高い)矩形が出るため、この1条件だけで
    ///   両方の navigation スタイルを覆う
    public static func bottomNavigationBar(_ dumpsysWindow: String) -> FTRect? {
        guard let line = dumpsysWindow.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: {
                $0.contains("type=navigationBars") && $0.contains("sideHint=BOTTOM")
                    && $0.contains("visible=true")
            }) else { return nil }
        guard let frame = parseFrame(in: line), frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    /// `frame=[l,t][r,b]` を切り出す(dumpsys の `InsetsSource` 行の書式)
    private static func parseFrame(in line: Substring) -> FTRect? {
        guard let openRange = line.range(of: "frame=[") else { return nil }
        let tail = line[openRange.upperBound...]
        guard let firstClose = tail.firstIndex(of: "]") else { return nil }
        let firstPair = tail[tail.startIndex..<firstClose]
        let afterFirst = tail[tail.index(after: firstClose)...]
        guard afterFirst.first == "[",
              let secondClose = afterFirst.firstIndex(of: "]") else { return nil }
        let secondPair = afterFirst[afterFirst.index(after: afterFirst.startIndex)..<secondClose]
        guard let (l, t) = parsePair(firstPair), let (r, b) = parsePair(secondPair) else { return nil }
        return FTRect(x: l, y: t, width: r - l, height: b - t)
    }

    private static func parsePair(_ text: Substring) -> (Double, Double)? {
        let parts = text.split(separator: ",")
        guard parts.count == 2,
              let a = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let b = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (a, b)
    }
}
