// MachineBadgeColor.swift
// リモートマシン登録簿(RemoteHostEntry.color)のバッジ色。**唯一の定義元** ——
// vscode-fleetest はパレットを持たず `fleetest api remote-machines` の machineColors を読む。

import Foundation

public enum MachineBadgeColor {
    /// 自動割り当て順 = 拡張の表示順。文字色は拡張側で #1f1f1f 固定
    /// (全色が黒字で読めるパステルであることが前提)
    public static let palette: [(key: String, hex: String)] = [
        ("gray", "#d4d4d4"),
        ("rose", "#f6c1cc"),
        ("sky", "#bcd6f5"),
        ("lemon", "#f3e79b"),
        ("mint", "#b9e6cf"),
        ("lavender", "#dcc8f2"),
        ("peach", "#f9d3b4"),
        ("aqua", "#b5e3e8"),
        ("lime", "#d3ecae"),
        ("pink", "#f3c4e6"),
        ("periwinkle", "#c9cdf6"),
        ("sand", "#e6d8c0"),
    ]

    public static func isKnown(_ key: String) -> Bool {
        palette.contains { $0.key == key }
    }

    /// 使用数最小の鍵を返す(同数はパレット順で先のもの)。nil・未知の鍵は数えない
    public static func autoAssign(usedBy others: [String?]) -> String {
        var counts: [String: Int] = [:]
        for other in others {
            guard let other, isKnown(other) else { continue }
            counts[other, default: 0] += 1
        }
        // Sequence.min(by:) は同点なら先に現れた要素を返す(Swift 標準の規約)ので、
        // パレット順の並びがそのままタイブレークになる
        return palette.min { (counts[$0.key] ?? 0) < (counts[$1.key] ?? 0) }!.key
    }
}
