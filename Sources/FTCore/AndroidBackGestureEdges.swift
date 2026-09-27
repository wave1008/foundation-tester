// AndroidBackGestureEdges.swift
// `adb shell dumpsys activity service com.android.systemui/.SystemUIService` の出力から、
// ジェスチャナビゲーションが back として奪う左右の帯幅(px)を読む純粋パーサ。
// swipeBy(座標ドラッグ)の始点・終点をこの帯の外へ逃がすために ScrollGeometry.panPath が使う
// (帯の内側に始点/終点を置くと、そのドラッグが back として消費され画面がアプリから離脱する)。

import Foundation

public enum AndroidBackGestureEdges {

    /// - Returns: `mIsGestureHandlingEnabled=true` のときだけ `(mEdgeWidthLeft, mEdgeWidthRight)`。
    ///   `false`(3ボタン navigation)は除外不要なので `(0, 0)`。ブロックが無い/値が読めないときは
    ///   nil(呼び手は除外しない側に倒す)。**`EdgeBackGestureHandler:` ブロックはダンプ中に複数回
    ///   現れうるが、値は同一なので最初の1つを採る**
    public static func parse(_ dumpsys: String) -> (left: Double, right: Double)? {
        guard let block = block(named: "EdgeBackGestureHandler:", in: dumpsys) else { return nil }
        guard let enabled = boolValue(named: "mIsGestureHandlingEnabled", in: block) else { return nil }
        guard enabled else { return (0, 0) }
        guard let left = doubleValue(named: "mEdgeWidthLeft", in: block),
              let right = doubleValue(named: "mEdgeWidthRight", in: block) else { return nil }
        return (left, right)
    }

    /// ヘッダ行より深いインデントの行だけをブロックとして切り出す(次に同じ/浅いインデントの
    /// 非空行が来たら終端)
    private static func block(named header: String, in dumpsys: String) -> [Substring]? {
        let lines = dumpsys.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(header)
        }) else { return nil }
        let headerIndent = indent(of: lines[start])
        var body: [Substring] = []
        for line in lines[(start + 1)...] {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard indent(of: line) > headerIndent else { break }
            body.append(line)
        }
        return body
    }

    private static func indent(of line: Substring) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func rawValue(named key: String, in block: [Substring]) -> String? {
        for line in block {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key)=") else { continue }
            return String(trimmed.dropFirst(key.count + 1))
        }
        return nil
    }

    private static func boolValue(named key: String, in block: [Substring]) -> Bool? {
        switch rawValue(named: key, in: block) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func doubleValue(named key: String, in block: [Substring]) -> Double? {
        rawValue(named: key, in: block).flatMap(Double.init)
    }
}
