// 記録操作(ライブ操作タブ)からのシナリオ名生成。1回のFM呼び出しで完結する(Explorer.swift の
// 1ステップ1セッション方針と同様、履歴を持ち回らない)。

import Foundation
import FoundationModels

@Generable
struct ScenarioNameSuggestion {
    @Guide(description: "テストクラス名向けの簡潔でシンプルな日本語名。操作対象の画面名や機能名を優先する(15文字以内、拡張子・引用符・記号を含めない)")
    var name: String
    @Guide(description: "この操作列が何を確認するテストかを表す簡潔な日本語の説明文(1文、40文字以内)")
    var description: String
}

/// name=クラス名(ファイル名)向けのシンプル名、description=@Test に入れる操作内容の説明。
public struct ScenarioNaming: Sendable {
    public let name: String
    public let description: String
    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public enum ScenarioNamer {

    static let instructions = """
    あなたはモバイルアプリの UI テスト記録から、テストシナリオのクラス名と説明を作る係です。
    渡される操作の要約(1行ずつ)とアプリ名から、次の2つを作ってください。
    - name: テストクラス名向けの簡潔な名詞句。操作対象の画面名・機能名を優先する。
      15文字以内、ファイル拡張子(.swift 等)や引用符・記号を含めない、
      「〜のテスト」「〜シナリオ」のような冗長な接尾辞は付けない。
    - description: この操作列が何をするテストかを端的に表す簡潔な1文(40文字以内)。
    """

    /// summary: 記録した操作の1行ずつの要約(例 "tap ログイン / type メール ... / swipe up")。
    /// appName: アプリ表示名 or bundle。FM 不可用/失敗時は nil を返す(呼び出し側が既定名にフォールバック)。
    public static func suggest(summary: String, appName: String) async -> ScenarioNaming? {
        guard FMDoctor.check().available else { return nil }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let prompt = "アプリ: \(appName)\n\n操作内容:\n\(summary)"
            let response = try await session.respond(
                to: prompt,
                generating: ScenarioNameSuggestion.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 120))
            let name = firstSentence(response.content.name, maxCount: 20)
            let desc = firstSentence(response.content.description, maxCount: 40)
            guard !name.isEmpty else { return nil }
            return ScenarioNaming(name: name, description: desc.isEmpty ? name : desc)
        } catch {
            return nil
        }
    }

    /// FM は「1文・N 文字以内」の指示を守らず、最初の1文の後にプロンプトのエコーや
    /// 追加の文を連ねることがある(オンデバイス FM の不安定さ。実測で @Test に長文が混入した)。
    /// 最初の文終端(「。」/改行)までで切り、前後のノイズ文字を除き、maxCount で頭打ちにする。
    static func firstSentence(_ raw: String, maxCount: Int) -> String {
        var text = raw
        if let end = text.rangeOfCharacter(from: CharacterSet(charactersIn: "。\n\r")) {
            text = String(text[..<end.lowerBound])
        }
        var noise = CharacterSet.whitespacesAndNewlines
        noise.formUnion(CharacterSet(charactersIn: "「」『』｛｝{}[]()（）〈〉《》\"'“”‘’　"))
        text = text.trimmingCharacters(in: noise)
        if text.count > maxCount { text = String(text.prefix(maxCount)) }
        return text
    }
}
