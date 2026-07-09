// ScenarioEvent.swift
// ftester-scenarios(サブプロセス)とホスト(CLI/GUI/MCP)の間で交わす NDJSON イベントの DTO。
// Foundation 以外に依存しないこと(ホスト側の軽量パースを保つ)。
// kind: scenarioStarted / sceneStarted / step / sceneFinished / fixSuggestion / scenarioFinished / log
// step は tap/exist 等 1 操作の結果(既存 StepResult と同語彙)。

import Foundation

public struct ScenarioEvent: Codable, Sendable {
    public var kind: String
    /// このイベントを処理したワーカーの識別子("<platform>:<デバイス論理名>"。
    /// ftester api monitor の monitorDevices の id と同一規則)。
    /// --profile 指定時のワーカー並列実行(ftester api run)でのみ設定され、
    /// 逐次実行では nil のまま(nil はエンコード時にキーごと省略されるため既存の NDJSON
    /// 契約は変わらない)
    public var worker: String?
    /// シナリオ ID(クラス名.メソッド名)
    public var scenario: String?
    /// シナリオのタイトル(@Test の引数)
    public var title: String?
    public var scene: Int?
    public var sceneTitle: String?
    /// condition / action / expectation(CAE ブロック外は nil)
    public var section: String?
    /// ステップの通し番号(シナリオ内)
    public var index: Int?
    /// ステップの人間可読な説明(例: tap "#login_btn||ログイン")
    public var description: String?
    /// passed / passedViaFallback / healed / failed / skipped
    public var status: String?
    /// 失敗理由・フォールバック内容・修正提案文など
    public var detail: String?
    /// コマンド呼び出し元のソース位置(修正提案用)
    public var file: String?
    public var line: Int?
    /// kind == fixSuggestion(強い提案)の旧セレクタ・新セレクタ(GUI の確認シート用)
    public var oldSelector: String?
    public var newSelector: String?
    /// scenarioFinished / sceneFinished 用
    public var passed: Bool?
    public var reportPath: String?
    /// kind == log(ユーザー print の混入行など)
    public var message: String?

    public init(kind: String) {
        self.kind = kind
    }

    /// NDJSON 1 行にエンコードする(改行を含まない)
    public func encodedLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let line = String(data: data, encoding: .utf8) else {
            return #"{"kind":"log","message":"(encode error)"}"#
        }
        return line.replacingOccurrences(of: "\n", with: " ")
    }

    public static func decode(line: String) -> ScenarioEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ScenarioEvent.self, from: data)
    }
}

public extension StepResult.Status {
    /// ScenarioEvent.status 用の文字列表現と詳細
    var eventStatus: (status: String, detail: String?) {
        switch self {
        case .passed:
            return ("passed", nil)
        case .passedViaFallback(let locator):
            return ("passedViaFallback", "フォールバック \(locator.summary) で解決")
        case .healed(let locator):
            return ("healed", "自己修復: \(locator.summary)")
        case .failed(let reason):
            return ("failed", reason)
        case .skipped(let reason):
            return ("skipped", reason)
        }
    }
}
