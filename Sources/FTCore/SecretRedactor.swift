// SecretRedactor.swift
// `account()` が返した値(パスワード等)を、このプロセスが書き出す全ての出口で `***` に置き換える登録簿。
// 出口: `FTDriveCore.recordStep`(ステップの説明・失敗の detail = レコードと NDJSON の両方)・
// `ConsoleOut` の文字列出力(NDJSON・テキストログ・stderr の最後の網)・`ScenarioReportWriter`(Markdown と
// 失敗時の要素一覧)。**塞げないもの**: 失敗時のスクリーンショット・ライブ操作の画面(画素の中の文字)。
//
// 登録簿は**プロセス大域**(1プロセス = 1シナリオ)。`ConsoleOut` は FTCore の静的な口なので、
// 呼び手から注入できない。登録が無いとき(fleetest 本体の親プロセス・全テスト)は `redact` は素通し。

import Foundation

public final class SecretRedactor: Sendable {
    public static let shared = SecretRedactor()

    /// これより短い値は登録しない。根拠: 1〜3 文字の値(`1234` 未満の PIN・`ab` 等)は無関係な文字列
    /// (ステップの説明・要素名・JSON のキー)にも一致して出力を壊す一方、秘密としての価値も低い。
    /// 4 は一般的な数字 PIN の最短長で、これ以上は伏せる側へ倒す。登録されなかったことは docs に書いてある
    public static let minimumLength = 4

    /// 置換後の文字列
    public static let mask = "***"

    /// 長い値から順に(ある値が別の値の一部のとき、長いほうを先に置換して断片を残さない)
    private let forms = LockedValue<[String]>([])

    public init() {}

    /// 値を登録する。`minimumLength` 未満は無視。**JSON の文字列としてエスケープした形も併せて登録する**
    /// (NDJSON の行では引用符・バックスラッシュ・制御文字が `\"` 等に変わる)
    public func register(_ value: String) {
        guard value.count >= Self.minimumLength else { return }
        var add = [value]
        if let escaped = Self.jsonEscaped(value), escaped != value { add.append(escaped) }
        forms.withLock { list in
            for form in add where !list.contains(form) { list.append(form) }
            list.sort { $0.count > $1.count }
        }
    }

    public func register(_ values: [String]) { values.forEach(register) }

    /// 登録済みの値を `***` へ。登録が無ければ入力をそのまま返す
    public func redact(_ text: String) -> String {
        let list = forms.withLock { $0 }
        guard !list.isEmpty else { return text }
        var out = text
        for form in list where out.contains(form) { out = out.replacingOccurrences(of: form, with: Self.mask) }
        return out
    }

    /// テスト用: 登録を空にする
    public func removeAll() { forms.withLock { $0.removeAll() } }

    /// JSON 文字列リテラルの中身(両端の引用符を除く)。`/` はエスケープしない(`encodedLine` と同じ書式)
    static func jsonEscaped(_ value: String) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8),
              text.count >= 2 else { return nil }
        return String(text.dropFirst().dropLast())
    }
}

public extension StepResult.Status {
    /// 理由の文字列(失敗・スキップ・結論なし)へ `transform` を掛けた同じ種類の状態
    func mappingReasons(_ transform: (String) -> String) -> StepResult.Status {
        switch self {
        case .failed(let reason): return .failed(transform(reason))
        case .skipped(let reason): return .skipped(transform(reason))
        case .inconclusive(let reason): return .inconclusive(transform(reason))
        case .passed, .passedViaFallback, .healed: return self
        }
    }
}
