// TimeBoundParse.swift
// "--since"/"--until" のような時刻境界オプションの文字列を Date へ変換する唯一の実装。
// fleetest results / fleetest api results(RunResultsQuery.parseSince)と
// fleetest api host-metrics-summary が共有する(呼び出し元を増やすときもここへ集約すること)。

import Foundation

public enum TimeBoundParse {

    /// 受理する3形: "YYYY-MM-DD"(UTC 0時)/ "<num>[smhd]"(小数可・0以下は拒否・now から遡る相対期間)/
    /// "@<epoch>"(GNU `date -d @<epoch>` に倣い "@" 接頭辞必須・小数可)。**裸の数値は拒否**——
    /// epoch として読むと "30d" の打ち間違いの "30" が epoch 30(≈1970年 = 実質全期間)として
    /// 黙って通ってしまう。どれにも一致しなければ nil(呼び出し側でエラーにすること)
    public static func parse(_ raw: String, now: Date = Date()) -> Date? {
        if let absolute = parseAbsoluteDate(raw) { return absolute }
        if let relative = parseRelativeDuration(raw, now: now) { return relative }
        return parseEpoch(raw)
    }

    /// parse(_:now:) が nil を返したときに呼び手が投げる文言を組む。オプション名だけ渡せば済むように
    /// ここへ集約する(「判定は1箇所・文言は呼び手ごと」の規律だが、同じ文法を2通りに説明しないため
    /// 文言のテンプレート自体は共有する)
    public static func rejection(option: String, raw: String) -> String {
        "\(option) must be a duration (e.g. 90s/30m/2h/30d), a date (YYYY-MM-DD) or an epoch (@1757280000): \(raw)"
    }

    private static func parseAbsoluteDate(_ raw: String) -> Date? {
        guard raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }

    private static func parseRelativeDuration(_ raw: String, now: Date) -> Date? {
        guard raw.range(of: #"^[0-9]+(?:\.[0-9]+)?[smhd]$"#, options: .regularExpression) != nil,
              let unitChar = raw.last, let amount = Double(raw.dropLast()), amount > 0 else { return nil }
        let unitSeconds: TimeInterval
        switch unitChar {
        case "s": unitSeconds = 1
        case "m": unitSeconds = 60
        case "h": unitSeconds = 3600
        case "d": unitSeconds = 86400
        default: return nil  // 正規表現で [smhd] に限定済みのため到達しない
        }
        return now.addingTimeInterval(-amount * unitSeconds)
    }

    /// "@" 接頭辞必須。裸の数値を epoch と読まない理由は parse(_:now:) の doc 参照。
    /// **isFinite を通す** —— `Double("nan")` / `Double("inf")` は成功するので、外すと
    /// 比較が常に false になる Date が下流へ流れて窓の絞り込みが黙って効かなくなる
    private static func parseEpoch(_ raw: String) -> Date? {
        guard raw.hasPrefix("@"), let epoch = Double(raw.dropFirst()), epoch.isFinite else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}
