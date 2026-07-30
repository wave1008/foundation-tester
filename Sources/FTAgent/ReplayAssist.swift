// 再生失敗時のみ呼ばれる FM フック群(Healer/Verifier/Triager、各セクションは下記 MARK 参照)。

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
    @Guide(description: "The element that should stand in for the broken locator. Copy exactly one label (the quoted string) or id= value from the current element list, verbatim")
    var elementText: String

    @Guide(description: "Confidence that the replacement plays the same role as the original")
    var confidence: RepairConfidence

    @Guide(description: "Reason for the decision, in one English sentence")
    var rationale: String
}

@Generable
struct ScreenVerdict {
    @Guide(description: "Whether the screenshot matches the expected state")
    var pass: Bool

    @Guide(description: "Reason for the verdict, in one English sentence; if it does not match, say what differs")
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
    @Guide(description: "Failure class. App defect=appBug, timing-related=flakiness, locator stale after a UI change=locatorDrift, environment problem=envIssue")
    var failureClass: FailureClass

    @Guide(description: "What happened, in one or two English sentences")
    var summary: String

    @Guide(description: "The next action to fix it, in one English sentence")
    var suggestedFix: String
}

// MARK: - ReplayDelegate 実装

public final class FMReplayDelegate: ReplayDelegate {

    public init() {}

    // MARK: Healer

    public func healLocator(step: FlowStep, snapshot: SnapshotResponse) async -> HealProposal? {
        // FM はホスト全体で直列化される資源(FMLock 参照)
        guard await FMGate.enter() else { return nil }
        defer { FMGate.leave() }
        let rendered = SnapshotRenderer.render(snapshot)
        let session = LanguageModelSession(instructions: """
        You repair locators for UI tests. An element can no longer be found after a UI change;
        pick its stand-in from the current element list. Choose only an element with the same
        role and meaning, and set confidence to low when unsure.
        """)
        let prompt = """
        Step whose element is missing: \(step.summary)
        \(step.note.map { "Intent of this step: \($0)" } ?? "")

        Elements on the current screen:
        \(rendered)

        Pick the single element that best matches this step's target.
        """
        let healStartedAt = Date()
        do {
            let suggestion = try await session.respond(
                to: prompt,
                generating: LocatorRepairSuggestion.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 250)
            ).content

            FMHealth.record(kind: "heal", ms: OcclusionVerifier.elapsedMs(healStartedAt), ok: true)
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
                                rationale: Self.sanitizeRationale(suggestion.rationale))
        } catch {
            FMHealth.record(kind: "heal", ms: OcclusionVerifier.elapsedMs(healStartedAt), ok: false,
                            error: "heal: \(FMHealth.describe(error))")
            return nil
        }
    }

    /// rationale(@Guide は「日本語で1文」)は構造化出力から外れて後続を巻き込むことがある。
    /// 実測(2026-07-22): 「…適切な代わりとなる。」} with tools:[] | 私は UI テストのロケータ修復者です…」
    /// のようにセッションのトランスクリプトが末尾に連結された。修正提案とヒールキャッシュの
    /// 両方に永続化されるため、発生源で1文に切り詰める。
    static func sanitizeRationale(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = trimmed.firstIndex(of: "。") {
            return String(trimmed[...end])
        }
        // 句点が無いときは崩れの目印で切る(見つからなければ従来どおり長さで頭打ち)
        for marker in ["」}", "} with", " with tools", "\n"] {
            if let r = trimmed.range(of: marker) {
                return String(trimmed[..<r.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return String(trimmed.prefix(120))
    }

    // MARK: Verifier(マルチモーダル)

    public func verifyScreen(expected: String, screenshotPNG: Data) async -> (pass: Bool, reason: String)? {
        // Attachment(画像入力)は macOS 27+。26 では判定不能(nil)= screenMatches は skip。
        // 通常は StepExecutor が FMVisionSupport で手前で止めるので、ここは保険
        guard #available(macOS 27, *) else { return nil }
        guard let cgImage = Self.cgImage(fromPNG: screenshotPNG) else { return nil }
        // FM はホスト全体で直列化される資源(FMLock 参照)
        guard await FMGate.enter() else { return nil }
        defer { FMGate.leave() }
        let session = LanguageModelSession(instructions: """
        You verify screens for UI tests. Look at the screenshot and judge strictly
        whether it matches the expected state.
        """)
        let screenStartedAt = Date()
        do {
            let verdict = try await session.respond(
                generating: ScreenVerdict.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200)
            ) {
                "Expected screen state: \(expected)\nDecide whether the screenshot below matches this state."
                Attachment(cgImage)
            }.content
            FMHealth.record(kind: "screenIs", ms: OcclusionVerifier.elapsedMs(screenStartedAt), ok: true)
            return (verdict.pass, String(verdict.reason.prefix(200)))
        } catch {
            FMHealth.record(kind: "screenIs", ms: OcclusionVerifier.elapsedMs(screenStartedAt),
                            ok: false, error: "screenIs: \(FMHealth.describe(error))")
            return nil
        }
    }

    // MARK: Occlusion guard(PoC)

    public func verifyElementVisible(expectedText: String, frame: FTRect, screen: FTRect,
                                     screenshotPNG: Data) async
        -> (visible: Bool, state: String, reason: String, observedText: String)? {
        guard let r = await OcclusionVerifier().verifyCropped(
            expectedText: expectedText, frame: frame, screen: screen, screenshotPNG: screenshotPNG)
        else { return nil }
        return (r.visible, r.state, r.reason, r.observedText)
    }

    // MARK: Triager

    public func triage(goal: String?, stepDescription: String, failureReason: String,
                       snapshot: SnapshotResponse?, screenshotPNG: Data?) async -> TriageInfo? {
        let rendered = snapshot.map { SnapshotRenderer.render($0) } ?? "(not available)"
        // **出力言語を決めるのは instructions ではなく @Guide の description**(2026-07-30 実測)。
        // instructions を英語にしても @Guide に「日本語で1文」が残っている間は日本語で返り続けた。
        // 出力言語を変えるときは TriageSuggestion / ScreenVerdict / LocatorRepairSuggestion の
        // @Guide も直すこと
        let instructions = """
        You triage UI test failures.
        From the failed step and the current screen, classify the failure and suggest a fix.
        Answer in English.
        Classification guide:
        - An error message is shown on screen, or the interaction succeeded but the app did
          not move to the expected screen -> appBug
        - An element that seems to play the same role exists under a different name -> locatorDrift
        - The element is present but the wait looks too short -> flakiness
        """
        let text = """
        \(goal.map { "Test goal: \($0)\n" } ?? "")Failed step: \(stepDescription)
        Failure reason: \(failureReason)

        Elements on screen at the moment of failure:
        \(rendered)

        Analyse this failure.
        """
        // FM はホスト全体で直列化される資源(FMLock 参照)。マルチモーダル→テキストの
        // 2 回分をまとめて 1 回の取得で回す(間で他ワーカーに割り込ませない)
        guard await FMGate.enter() else { return nil }
        defer { FMGate.leave() }
        // マルチモーダル失敗時のフォールバックとしてテキストのみでも再試行する
        // (Attachment は macOS 27+。26 では常にテキストのみの経路を通る)
        //
        // **試行ごとに FMHealth へ記録する**(heal / screenIs と同じ規約)。記録は失敗率の分母と
        // FMBreaker の両方を養う(FMHealth.record → FMBreaker.recordSuccess/Failure)ので、
        // 記録を欠くと ①結果 JSON の fm に triage が出ず「呼ばれていない」と誤読され
        // ②triage の失敗がブレーカを進めないため、FM が死んだホストで失敗するシナリオが
        // 毎回 2 試行ぶんの時間を捨て続ける。画像経路とテキスト経路は別の FM 呼び出しなので
        // それぞれ 1 件として数える(画像が死んでテキストだけ生きている状態が失敗率に出る)。
        if #available(macOS 27, *), let png = screenshotPNG, let cgImage = Self.cgImage(fromPNG: png) {
            let imageStartedAt = Date()
            do {
                let suggestion = try await LanguageModelSession(instructions: instructions).respond(
                    generating: TriageSuggestion.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 300)
                ) {
                    text
                    "Screenshot at the moment of failure:"
                    Attachment(cgImage)
                }.content
                FMHealth.record(kind: "triage", ms: OcclusionVerifier.elapsedMs(imageStartedAt), ok: true)
                return Self.info(from: suggestion)
            } catch {
                // ここでは return しない(下のテキストのみ経路で再試行する)
                FMHealth.record(kind: "triage", ms: OcclusionVerifier.elapsedMs(imageStartedAt),
                                ok: false, error: "triage(image): \(FMHealth.describe(error))")
            }
        }
        let textStartedAt = Date()
        do {
            let suggestion = try await LanguageModelSession(instructions: instructions).respond(
                to: text,
                generating: TriageSuggestion.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 300)
            ).content
            FMHealth.record(kind: "triage", ms: OcclusionVerifier.elapsedMs(textStartedAt), ok: true)
            return Self.info(from: suggestion)
        } catch {
            FMHealth.record(kind: "triage", ms: OcclusionVerifier.elapsedMs(textStartedAt),
                            ok: false, error: "triage: \(FMHealth.describe(error))")
            return nil
        }
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

    /// elementText→要素解決(テキスト一致で要素を引く簡易版)
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
