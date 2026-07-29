// FTSeconds.swift
// 秒数を人にもコードにも出せる文字列表現の唯一の生成元。FTDSL の StepCommandText.formatSeconds /
// StepDescription.formatSeconds はここへ委譲する(同じ変換を複数箇所に持たない)。

import Foundation

public enum FTSeconds {
    /// 5.0 → "5" / 1.2 → "1.2" / 0.5 → "0.5"。整数値相当は小数点なしで出す
    public static func format(_ seconds: Double) -> String {
        if seconds == seconds.rounded(), abs(seconds) < 1e15 {
            return String(Int(seconds))
        }
        return String(seconds)
    }
}
