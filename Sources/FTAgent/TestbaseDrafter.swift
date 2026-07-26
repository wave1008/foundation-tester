// テスト設計の元資料(docs/testbases/*.md)→ シナリオ下書き(ScenarioDraft)の FM 変換。
// 1回のFM呼び出しで完結する(履歴を持ち回らない)。
// 失敗・FM 不可用時は nil を返し、呼び出し側が決定的パーサ(TestbaseOutline.parse)へ落ちる契約。

import Foundation
import FoundationModels
import FTCore

@Generable
struct TestbaseSceneSuggestion {
    @Guide(description: "この場面が何を確かめるかの短い日本語タイトル(20文字以内)")
    var title: String
    @Guide(description: "この場面を始める前の状態・準備。1項目1文の日本語。無ければ空配列", .count(0...3))
    var condition: [String]
    @Guide(description: "アプリに対して行う操作。1項目1操作の日本語。", .count(1...5))
    var action: [String]
    @Guide(description: "操作後に画面で確認できること。1項目1観点の日本語。", .count(1...4))
    var expectation: [String]
}

@Generable
struct TestbaseDraftSuggestion {
    @Guide(description: "このテストが何を確認するかを表す簡潔な日本語1文(40文字以内)")
    var title: String
    @Guide(description: "テストの場面を順に並べたもの", .count(1...4))
    var scenes: [TestbaseSceneSuggestion]
}

public enum TestbaseDrafter {

    /// 4K コンテキスト対策。テストベースは長くなりがちなので先頭からこの文字数だけ渡す
    /// (超過分は切り捨てて警告する。全文を要約させるより「頭から確実に」の方が下書きとして使える)
    public static let maxInputCharacters = 2400

    static let instructions = """
    あなたはモバイルアプリのテスト設計書を読み、UI テストの下書き構造に起こす係です。
    渡された設計書から、テストの場面(scene)を順に組み立ててください。
    - condition: その場面を始める前の状態・準備(画面を開く、ログイン済みにする等)
    - action: アプリへの操作(タップする、入力する等。1項目1操作)
    - expectation: 操作の後に画面で確認できること(1項目1観点)
    設計書に書かれていないことを創作しないでください。日本語で簡潔に書いてください。
    """

    /// markdown: テストベース全文(長い場合は maxInputCharacters で切られる)。
    /// FM 不可用・失敗・空応答では nil(呼び出し側は TestbaseOutline.parse へフォールバックする)
    public static func draft(markdown: String, fallbackTitle: String) async -> ScenarioDraft? {
        guard FMDoctor.check().available else { return nil }
        let input = String(markdown.prefix(maxInputCharacters))
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: "テスト設計書:\n\(input)",
                generating: TestbaseDraftSuggestion.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 700))
            return convert(response.content, fallbackTitle: fallbackTitle)
        } catch {
            return nil
        }
    }

    /// FM 応答 → ScenarioDraft。空タイトル・空 scene のような 3B モデルの出し損ないは
    /// ここで弾き、1 つも残らなければ nil(= フォールバック)にする
    static func convert(_ suggestion: TestbaseDraftSuggestion, fallbackTitle: String) -> ScenarioDraft? {
        var scenes: [DraftScene] = []
        for suggested in suggestion.scenes {
            let scene = DraftScene(
                number: scenes.count + 1,
                title: clean(suggested.title, maxCount: 30).isEmpty
                    ? "場面\(scenes.count + 1)" : clean(suggested.title, maxCount: 30),
                condition: sanitize(suggested.condition),
                action: sanitize(suggested.action),
                expectation: sanitize(suggested.expectation))
            if !scene.isEmpty { scenes.append(scene) }
        }
        guard !scenes.isEmpty else { return nil }
        let title = clean(suggestion.title, maxCount: 40)
        return ScenarioDraft(title: title.isEmpty ? fallbackTitle : title, scenes: scenes)
    }

    static func sanitize(_ items: [String]) -> [String] {
        items.map { clean($0, maxCount: 60) }.filter { !$0.isEmpty }
    }

    /// 箇条書き記号・引用符などのノイズを落として頭打ちにする
    /// (オンデバイス FM は「N 文字以内・記号なし」の指示を守り切らない。ScenarioNamer と同じ事情)
    static func clean(_ raw: String, maxCount: Int) -> String {
        var noise = CharacterSet.whitespacesAndNewlines
        noise.formUnion(CharacterSet(charactersIn: "-*・「」『』\"'“”‘’　"))
        var text = raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: noise)
        if text.count > maxCount { text = String(text.prefix(maxCount)) }
        return text
    }
}
