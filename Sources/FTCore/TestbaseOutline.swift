// TestbaseOutline.swift
// テスト設計の元資料(TestProjects/<name>/docs/testbases/*.md)→ シナリオ下書きの中間モデルと、
// FM を使わない決定的パーサ。FM(FTFoundationModels.TestbaseDrafter)が使えないときの土台であり、
// 同時に「FM 出力の受け皿の型」でもある(両者は同じ ScenarioDraft を返す契約)。
// レンダリング(Swift DSL 化)は FTDSL.ScenarioDraftCodeGen。

import Foundation

/// シナリオ 1 本の下書き(scene の並び)
public struct ScenarioDraft: Sendable, Equatable {
    /// @Test に入れる説明
    public var title: String
    public var scenes: [DraftScene]

    public init(title: String, scenes: [DraftScene]) {
        self.title = title
        self.scenes = scenes
    }
}

/// scene 1 つ分。3 つの配列は CAE(condition / action / expectation)にそのまま対応し、
/// 中身はコマンドではなく**自然言語の手順文**(レンダラがコマンド候補へ写像する)
public struct DraftScene: Sendable, Equatable {
    public var number: Int
    public var title: String
    public var condition: [String]
    public var action: [String]
    public var expectation: [String]

    public init(number: Int, title: String, condition: [String] = [],
                action: [String] = [], expectation: [String] = []) {
        self.number = number
        self.title = title
        self.condition = condition
        self.action = action
        self.expectation = expectation
    }

    public var isEmpty: Bool { condition.isEmpty && action.isEmpty && expectation.isEmpty }
}

public enum TestbaseOutline {

    /// CAE のどのバケットに入れるかを決めるキーワード。行頭ラベル(`前提:`)と
    /// 小見出し(`### 前提条件`)の両方でこれを見る
    static let conditionKeywords = ["前提", "条件", "事前", "given", "setup", "準備"]
    static let actionKeywords = ["操作", "手順", "実行", "when", "action", "ステップ"]
    static let expectationKeywords = ["期待", "確認", "結果", "検証", "then", "expect", "観点"]

    /// テストベース Markdown を決定的に構造化する(FM 不使用)。
    /// 規則:
    /// - 最初の `#` 見出し = シナリオ説明(無ければ fallbackTitle)
    /// - `##` 見出し = scene(1 つも無ければ全体で 1 scene)
    /// - `###` 以下の見出し・`前提:`/`操作:`/`期待:` の行頭ラベルで CAE のバケットを切り替える
    /// - ラベルの無い行は現在のバケット(初期値 action)。ただし「〜こと」で終わる行は
    ///   テスト観点の書き方なので expectation に寄せる
    public static func parse(markdown: String, fallbackTitle: String) -> ScenarioDraft {
        var title: String?
        var scenes: [DraftScene] = []
        var current: DraftScene?
        var bucket = Bucket.action

        func flush() {
            if let scene = current, !scene.isEmpty { scenes.append(scene) }
            current = nil
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let heading = headingLevel(line) {
                let text = cleanup(String(line.dropFirst(heading)))
                if text.isEmpty { continue }
                switch heading {
                case 1:
                    if title == nil { title = text }
                case 2:
                    flush()
                    current = DraftScene(number: scenes.count + 1, title: text)
                    bucket = .action
                default:
                    // 小見出しは CAE の切り替えとしてのみ使う(該当しなければ現状維持)
                    if let matched = matchBucket(label: text) { bucket = matched }
                }
                continue
            }
            let (text, explicit) = strippedBullet(line)
            if text.isEmpty { continue }
            if current == nil { current = DraftScene(number: scenes.count + 1, title: title ?? fallbackTitle) }
            let target = explicit ?? (text.hasSuffix("こと") ? .expectation : bucket)
            switch target {
            case .condition: current?.condition.append(text)
            case .action: current?.action.append(text)
            case .expectation: current?.expectation.append(text)
            }
        }
        flush()

        if scenes.isEmpty {
            scenes = [DraftScene(number: 1, title: title ?? fallbackTitle,
                                 action: ["(テストベースから手順を読み取れませんでした)"])]
        }
        // scene 番号は出現順で振り直す(空 scene を捨てた分の穴を残さない)
        for index in scenes.indices { scenes[index].number = index + 1 }
        return ScenarioDraft(title: title ?? fallbackTitle, scenes: scenes)
    }

    enum Bucket { case condition, action, expectation }

    /// 見出し記号(`#` の個数)。見出しでなければ nil
    static func headingLevel(_ line: String) -> Int? {
        var count = 0
        for char in line {
            if char == "#" { count += 1 } else { break }
        }
        guard count > 0, count < line.count else { return nil }
        let next = line[line.index(line.startIndex, offsetBy: count)]
        return next == " " ? count : nil
    }

    /// 箇条書き記号・チェックボックス・強調を除いた本文と、行頭ラベルで明示された CAE
    static func strippedBullet(_ line: String) -> (text: String, explicit: Bucket?) {
        var text = line
        for marker in ["- ", "* ", "+ ", "> "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count))
        }
        // "1. " / "1) " の連番
        if let range = text.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            text = String(text[range.upperBound...])
        }
        for marker in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count))
        }
        var explicit: Bucket?
        // 行頭ラベル("前提: " / "Given: " / "**操作**: " 等)。CAE キーワードに一致したときだけ剥がす
        // (「エラー: 通信失敗」のような本文中のコロンを壊さない)
        if let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            let label = cleanup(String(text[text.startIndex..<colon]))
            if label.count <= 12, let matched = matchBucket(label: label) {
                explicit = matched
                text = String(text[text.index(after: colon)...])
            }
        }
        return (cleanup(text), explicit)
    }

    static func matchBucket(label: String) -> Bucket? {
        let lowered = label.lowercased()
        if conditionKeywords.contains(where: lowered.contains) { return .condition }
        if actionKeywords.contains(where: lowered.contains) { return .action }
        if expectationKeywords.contains(where: lowered.contains) { return .expectation }
        return nil
    }

    /// Markdown の装飾(強調・インラインコード)と前後の記号を落とす
    static func cleanup(_ text: String) -> String {
        var result = text
        for marker in ["**", "__", "`", "*"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " 　\t-:："))
    }

    /// テストベースのディレクトリから対象ファイルを選ぶ。name 指定があればそれ、
    /// 無ければ .md が 1 つのときだけ自動採用(複数なら候補一覧を返して呼び出し側にエラーを出させる)
    public static func candidates(in dir: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
