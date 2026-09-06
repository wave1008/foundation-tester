import Foundation

/// 正規表現の**事前検証**。`String.range(of:options:.regularExpression)` は不正なパターンで
/// throw せず nil を返すだけなので、否定形(`textMatchesNot` / `notExist("textMatches=…")`)は
/// 閉じ忘れの括弧1つで**永久に緑**になる。セレクタ・DSL・値検証の入口はここを通す
public enum RegexValidation {
    /// 不正なら理由(利用者向け文言)。正当なら nil
    public static func error(for pattern: String) -> String? {
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return "\"\(pattern)\" is not a valid regular expression (\(error.localizedDescription))"
        }
    }
}
