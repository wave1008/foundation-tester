// ReplayAssist.swift
// M3: 再生失敗時のみ呼ばれる FM フック群。
// - Healer   : 壊れたロケータの修復案(elementText 方式 — M2 の知見を踏襲)
// - Verifier : screenMatches のマルチモーダル画面検証(スクリーンショット + 期待状態)
// - Triager  : 失敗の分類と修正案(可能ならスクリーンショットも見る)

import CoreGraphics
import Foundation
import FoundationModels
import FTCore
import ImageIO

// MARK: - @Generable 型

@Generable
enum RepairConfidence {
    case high
    case medium
    case low
}

@Generable
struct LocatorRepairSuggestion {
    @Guide(description: "壊れたロケータの代役となる要素。現在の画面一覧にある「」内の label か id= の文字列をそのまま1つコピー")
    var elementText: String

    @Guide(description: "代役が同じ役割の要素だと言える確信度")
    var confidence: RepairConfidence

    @Guide(description: "判断理由(日本語で1文)")
    var rationale: String
}

@Generable
struct ScreenVerdict {
    @Guide(description: "スクリーンショットが期待する状態と一致しているか")
    var pass: Bool

    @Guide(description: "判定理由(日本語で1文。不一致の場合は何が違うか)")
    var reason: String
}

@Generable
enum FailureClass {
    case appBug
    case flakiness
    case locatorDrift
    case envIssue
}

@Generable
struct TriageSuggestion {
    @Guide(description: "失敗の分類。アプリの不具合=appBug、タイミング起因=flakiness、UI変更でロケータが古い=locatorDrift、環境問題=envIssue")
    var failureClass: FailureClass

    @Guide(description: "何が起きたか(日本語で1〜2文)")
    var summary: String

    @Guide(description: "修正のための次の一手(日本語で1文)")
    var suggestedFix: String
}

// MARK: - ReplayDelegate 実装

public final class FMReplayDelegate: ReplayDelegate {

    public init() {}

    // MARK: Healer

    public func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealProposal? {
        let rendered = SnapshotRenderer.render(snapshot)
        let session = LanguageModelSession(instructions: """
        あなたは UI テストのロケータ修復者です。アプリの UI 変更で見つからなくなった要素の
        代役を、現在の画面の要素一覧から選びます。役割・意味が同じ要素だけを選び、
        確信が持てない場合は confidence を low にしてください。
        """)
        let prompt = """
        見つからなくなったステップ: \(step.summary)
        \(step.note.map { "このステップの意図: \($0)" } ?? "")

        現在の画面の要素一覧:
        \(rendered)

        このステップの対象として最も適切な要素を1つ選んでください。
        """
        do {
            let suggestion = try await session.respond(
                to: prompt,
                generating: LocatorRepairSuggestion.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 250)
            ).content

            guard let element = Self.resolveByText(suggestion.elementText, in: snapshot) else {
                return nil
            }
            let confidence: String
            switch suggestion.confidence {
            case .high: confidence = "high"
            case .medium: confidence = "medium"
            case .low: confidence = "low"
            }
            return HealProposal(element: element, confidence: confidence,
                                rationale: String(suggestion.rationale.prefix(120)))
        } catch {
            return nil
        }
    }

    // MARK: Verifier(マルチモーダル)

    public func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? {
        guard let cgImage = Self.cgImage(fromPNG: screenshotPNG) else { return nil }
        let session = LanguageModelSession(instructions: """
        あなたは UI テストの画面検証者です。スクリーンショットを見て、
        期待する状態と一致しているかを厳密に判定します。
        """)
        do {
            let verdict = try await session.respond(
                generating: ScreenVerdict.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200)
            ) {
                "期待する画面の状態: \(expected)\n以下のスクリーンショットがこの状態と一致しているか判定してください。"
                Attachment(cgImage)
            }.content
            return (verdict.pass, String(verdict.reason.prefix(200)))
        } catch {
            return nil
        }
    }

    // MARK: Triager

    public func triage(goal: String?, stepDescription: String, failureReason: String,
                       snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? {
        let rendered = snapshot.map { SnapshotRenderer.render($0) } ?? "(取得できず)"
        let instructions = """
        あなたは UI テストの失敗を分析するトリアージ担当です。
        失敗したステップ・現在の画面から、失敗の種類を分類し修正案を出します。
        分類の目安:
        - 画面にエラーメッセージが表示されている、または操作は成功したのに期待画面に
          遷移していない → appBug
        - 同じ役割らしい要素が別の名前で存在する → locatorDrift
        - 要素はあるが待ち時間不足に見える → flakiness
        """
        let text = """
        \(goal.map { "テストの目標: \($0)\n" } ?? "")失敗したステップ: \(stepDescription)
        失敗理由: \(failureReason)

        失敗時点の画面の要素一覧:
        \(rendered)

        この失敗を分析してください。
        """
        // まずスクリーンショット付きで試み、マルチモーダル不可ならテキストのみで再試行
        if let png = screenshotPNG, let cgImage = Self.cgImage(fromPNG: png) {
            let response = try? await LanguageModelSession(instructions: instructions).respond(
                generating: TriageSuggestion.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 300)
            ) {
                text
                "失敗時点のスクリーンショット:"
                Attachment(cgImage)
            }
            if let suggestion = response?.content {
                return Self.info(from: suggestion)
            }
        }
        guard let suggestion = try? await LanguageModelSession(instructions: instructions).respond(
            to: text,
            generating: TriageSuggestion.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 300)
        ).content else {
            return nil
        }
        return Self.info(from: suggestion)
    }

    // MARK: - Helpers

    static func info(from suggestion: TriageSuggestion) -> TriageInfo {
        let name: String
        switch suggestion.failureClass {
        case .appBug: name = "appBug"
        case .flakiness: name = "flakiness"
        case .locatorDrift: name = "locatorDrift"
        case .envIssue: name = "envIssue"
        }
        // 縮退ループの繰り返し文対策: ガイドで指定した文数で強制的に切る
        return TriageInfo(failureClass: name,
                          summary: String(firstSentences(suggestion.summary, 2).prefix(300)),
                          suggestedFix: String(firstSentences(suggestion.suggestedFix, 1).prefix(300)))
    }

    static func firstSentences(_ text: String, _ count: Int) -> String {
        let parts = text.split(separator: "。", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return text }
        return parts.prefix(count).joined(separator: "。") + "。"
    }

    /// Explorer と同じ思想のテキスト→要素解決(修復用の簡易版)
    static func resolveByText(_ text: String, in snapshot: SnapshotResponse) -> ElementInfo? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        raw = raw.replacingOccurrences(of: "「", with: "")
                 .replacingOccurrences(of: "」", with: "")
                 .replacingOccurrences(of: "id=", with: "")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        return snapshot.elements.first { $0.identifier == raw }
            ?? snapshot.elements.first { $0.label == raw }
            ?? snapshot.elements.first { ($0.identifier ?? "").localizedCaseInsensitiveContains(raw) }
            ?? snapshot.elements.first { ($0.label ?? "").localizedCaseInsensitiveContains(raw) }
    }

    static func cgImage(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
