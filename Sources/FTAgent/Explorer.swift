// Explorer.swift
// M2: FM エージェントによるアプリ探索とテストフロー生成。
//
// 4K トークン運用の原則(設計書 5.1):
// - 1 ステップ = 1 セッション(履歴は圧縮した旅程ログのみ持ち回る)
// - 画面は set-of-mark 圧縮テキストで渡す
// - 出力は @Generable による構造化(自由文を返させない)
//
// 3B モデルの弱点への対策(実測に基づく):
// - 数値参照(elementRef)の束縛ミスが頻発するため、要素指定は elementText
//   (label/id のテキストコピー)+コード側のあいまい解決にする
// - 無効な操作(入力欄への tap、非対話要素への tap、入力済み欄への再入力)は
//   コード側ガードレールで実行前に拒否し、旅程ログで正しい手を教える
// - 探索開始時に一度だけテスト計画を生成し、毎ステップの足場にする

import Foundation
import FoundationModels
import FTCore

@Generable
enum ExploreActionKind {
    case tap
    case typeText
    case swipe
    case assertVisible
    case done
    case giveUp
}

@Generable
struct NextAction {
    @Guide(description: "次に実行するアクション種別。入力欄に文字を入れるときは必ず typeText(tap ではない)")
    var kind: ExploreActionKind

    @Guide(description: "対象要素の指定。要素一覧にある「」内の label か id= の文字列を、そのまま1つコピーして書く(tap / typeText / assertVisible で必須)")
    var elementText: String?

    @Guide(description: "typeText で入力する文字列")
    var text: String?

    @Guide(description: "swipe の方向: up / down / left / right のいずれか")
    var direction: String?

    @Guide(description: "このアクションを選ぶ理由(日本語で簡潔に1文)")
    var rationale: String

    @Guide(description: "done のときのみ: 最終画面の状態を1文で説明")
    var screenDescription: String?
}

@Generable
struct TestPlan {
    @Guide(description: """
    テスト目標を達成するためのUI操作手順(3〜7個)。各手順は必ず次のいずれかの形式で書く:
    「◯◯」に「××」を入力する / 「◯◯」をタップする / 「◯◯」が表示されていることを確認する
    """)
    var steps: [String]
}

public final class ExplorerAgent {

    public enum Outcome {
        case completed(String?)
        case gaveUp(String)
        case stepLimitReached
    }

    public struct Result {
        public let flow: Flow
        public let outcome: Outcome
        public let stepsTaken: Int
    }

    static let instructions = """
    あなたは iOS アプリの UI テストを設計するテスト探索エージェントです。
    毎ターン、テスト目標・計画・行動履歴・現在の画面の要素一覧を受け取り、
    目標達成に向けた「次の1アクション」だけを決めます。
    ルール:
    - elementText には、現在の要素一覧にある「」内の label か id= の文字列を
      そのまま1つコピーして指定する(自分で言葉を作らない)
    - tap は Button・Cell・Switch など操作可能な要素にのみ行う
    - 入力欄への入力は typeText を直接使う(elementText と text を指定。事前の tap は不要)
    - ダイアログやシートを閉じるには、その中のボタン(「今はしない」「OK」など)を tap する
    - ログイン・送信などのボタンを tap する前に、必要な入力欄がすべて入力済みであること
      (「未入力」の表示が残っていないこと)を確認する
    - 「〜が表示されていることを確認する」という計画項目は assertVisible で実行する(tap しない)
    - 確認したい要素がすでに画面に見えているなら、tap せず assertVisible で検証する
    - 目標をすべて達成したら done(screenDescription に最終画面の説明)
    - 「画面変化なし」「拒否」と記録された操作は失敗している。同じ操作を繰り返さない
    - 進めなくなったら giveUp
    """

    let driver: AppDriver
    let goal: String
    let maxSteps: Int

    /// 進捗コールバック(step番号, 説明)
    public var onStep: ((Int, String) -> Void)?

    private var journey: [String] = []
    private var flowSteps: [FlowStep] = []
    private var plan: [String] = []

    public init(driver: AppDriver, goal: String, maxSteps: Int = 25) {
        self.driver = driver
        self.goal = goal
        self.maxSteps = maxSteps
    }

    public func explore(bundleID: String) async throws -> Result {
        // 探索開始時に一度だけテスト計画を生成し、毎ステップの足場にする
        plan = (try? await makePlan()) ?? []
        if !plan.isEmpty {
            onStep?(0, "計画: " + plan.joined(separator: " / "))
        }

        try await driver.launch(bundleID: bundleID)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        var lastRenderedHash = 0
        var sameScreenCount = 0
        var invalidTargetCount = 0
        var consecutiveNoProgress = 0
        var lastActionWasTap = false
        var lastActionSignature: String?
        // 「同じ画面で効果がなかった操作」の署名。再提案されたらコード側で拒否する
        var ineffectiveSignatures: Set<String> = []

        for step in 1...maxSteps {
            let snap = try await driver.snapshot()
            let rendered = SnapshotRenderer.render(snap)

            // 同一画面ループ検出(コード側の強制ガード)
            let hash = rendered.hashValue
            if hash == lastRenderedHash {
                sameScreenCount += 1
                // 直前の操作が無効だったことを旅程ログに明示し、
                // 効果のなかった tap はフローから巻き戻す(ゴミステップを残さない)
                if let last = journey.last, !last.hasSuffix("→ 画面変化なし"), lastActionWasTap {
                    journey[journey.count - 1] = last + " → 画面変化なし"
                    if flowSteps.last?.action == "tap" { flowSteps.removeLast() }
                    if let sig = lastActionSignature { ineffectiveSignatures.insert(sig) }
                }
            } else {
                sameScreenCount = 0
            }
            lastRenderedHash = hash
            if sameScreenCount >= 4 {
                // モデルが停滞しても、目標の確認要素が画面に揃っていればコード側で
                // 検証してフローを完成させる(ナビゲーションはモデル、検証はコード)
                if let salvaged = salvageGoalAssertions(in: snap, steps: step - 1, bundleID: bundleID) {
                    return salvaged
                }
                return finish(.gaveUp("画面が変化しなくなったため中断しました"), step - 1, bundleID)
            }

            let action: NextAction
            do {
                // 進捗なしが続いたら greedy をやめて温度サンプリングで轍から脱出する
                action = try await decide(rendered: rendered,
                                          screenUnchanged: sameScreenCount > 0,
                                          escapeRut: consecutiveNoProgress >= 2)
            } catch {
                // モデル応答の失敗で探索全体を落とさない。部分フローを保存して中断
                return finish(.gaveUp("モデル応答エラー: \(error.localizedDescription)"), step - 1, bundleID)
            }
            onStep?(step, describe(action))
            lastActionWasTap = false
            consecutiveNoProgress += 1  // 実行に成功した分岐でリセットする

            switch action.kind {
            case .done:
                if let sd = action.screenDescription, !sd.isEmpty {
                    flowSteps.append(FlowStep(assert: "screenMatches", expected: sd))
                }
                return finish(.completed(action.screenDescription), step, bundleID)

            case .giveUp:
                return finish(.gaveUp(action.rationale), step, bundleID)

            case .tap:
                guard let element = resolveElement(action.elementText, in: snap, forTap: true) else {
                    invalidTargetCount += 1
                    if invalidTargetCount >= 4 {
                        return finish(.gaveUp("要素指定の失敗が続いたため中断しました"), step, bundleID)
                    }
                    journey.append("\(step). tap「\(action.elementText ?? "")」は失敗(一致する要素なし)。要素一覧の label か id をそのまま使うこと")
                    continue
                }
                // 入力欄への tap は実行しない。正しい呼び方を旅程ログで教える
                if SnapshotRenderer.textInputTypes.contains(element.type) {
                    journey.append("\(step). \(describeElement(element)) への tap は不要。文字を入れるには typeText を使うこと")
                    continue
                }
                // タップ可能型のホワイトリスト。NavigationBar や StaticText への
                // 無意味なタップ連打をコード側で止める
                guard Self.tappableTypes.contains(element.type) else {
                    let assertables = snap.elements
                        .filter { $0.type == "StaticText" && !($0.label ?? "").isEmpty }
                        .prefix(4)
                        .map { "「\($0.label!)」" }
                        .joined(separator: " ")
                    journey.append("\(step). \(describeElement(element))(\(element.type))のタップは無効。ボタンやセルを選ぶか、表示の確認なら assertVisible を使うこと"
                                   + (assertables.isEmpty ? "" : "(この画面で確認できるテキスト: \(assertables))"))
                    continue
                }
                // 同じ画面で前回効果がなかった tap は実行前に拒否
                let signature = "\(hash)|tap|\(element.type)|\(element.label ?? "")|\(element.identifier ?? "")"
                if ineffectiveSignatures.contains(signature) {
                    journey.append("\(step). \(describeElement(element)) への tap は拒否(前回効果がなかった)。別の要素を選ぶこと")
                    continue
                }
                try await driver.tap(ref: element.ref)
                record(action: "tap", element: element, in: snap, note: action.rationale)
                journey.append("\(step). tap \(describeElement(element))")
                lastActionWasTap = true
                lastActionSignature = signature
                consecutiveNoProgress = 0

            case .typeText:
                guard let text = action.text, !text.isEmpty,
                      var element = resolveElement(action.elementText, in: snap, forInput: true) else {
                    invalidTargetCount += 1
                    if invalidTargetCount >= 4 {
                        return finish(.gaveUp("要素指定の失敗が続いたため中断しました"), step, bundleID)
                    }
                    journey.append("\(step). typeText「\(action.elementText ?? "")」は失敗(一致する入力欄なし、または text 未指定)")
                    continue
                }
                guard SnapshotRenderer.textInputTypes.contains(element.type) else {
                    journey.append("\(step). \(describeElement(element)) は入力欄ではないため typeText は失敗。入力欄を指定すること")
                    continue
                }
                // 入力済みの欄が指定され、未入力の欄が残っている場合の扱い:
                // ちょうど1つなら自動修正でそちらへ、複数あれば候補を提示して拒否
                var autoCorrected = false
                if let existing = element.value, !existing.isEmpty {
                    let empties = snap.elements.filter {
                        SnapshotRenderer.textInputTypes.contains($0.type) && $0.value == nil && $0.ref != element.ref
                    }
                    if empties.count == 1 {
                        element = empties[0]
                        autoCorrected = true
                    } else if !empties.isEmpty {
                        let candidates = empties.map { describeElement($0) }.joined(separator: ", ")
                        journey.append("\(step). \(describeElement(element)) は既に入力済み。未入力の欄(\(candidates))から選ぶこと")
                        continue
                    }
                }
                try await driver.type(ref: element.ref, text: text)
                record(action: "type", element: element, in: snap, text: text, note: action.rationale)
                journey.append("\(step). \(describeElement(element)) に「\(text)」を入力"
                               + (autoCorrected ? "(指定された欄は入力済みだったため自動修正)" : ""))
                consecutiveNoProgress = 0

            case .swipe:
                let direction = FTSwipeDirection(rawValue: action.direction ?? "") ?? .up
                try await driver.swipe(direction)
                flowSteps.append(FlowStep(action: "swipe", direction: direction.rawValue,
                                          note: String(action.rationale.prefix(120))))
                journey.append("\(step). swipe \(direction.rawValue)")
                consecutiveNoProgress = 0

            case .assertVisible:
                guard let element = resolveElement(action.elementText, in: snap) else {
                    let texts = snap.elements
                        .filter { $0.type == "StaticText" && !($0.label ?? "").isEmpty }
                        .prefix(4)
                        .map { "「\($0.label!)」" }
                        .joined(separator: " ")
                    journey.append("\(step). assertVisible「\(action.elementText ?? "")」は失敗(一致する要素なし)"
                                   + (texts.isEmpty ? "" : "。この画面にあるテキスト: \(texts)"))
                    continue
                }
                record(assert: "exists", element: element, in: snap, note: action.rationale)
                journey.append("\(step). \(describeElement(element)) の表示を検証(OK)")
                consecutiveNoProgress = 0
            }

            try await Task.sleep(nanoseconds: 800_000_000)
        }
        if let snap = try? await driver.snapshot(),
           let salvaged = salvageGoalAssertions(in: snap, steps: maxSteps, bundleID: bundleID) {
            return salvaged
        }
        return finish(.stepLimitReached, maxSteps, bundleID)
    }

    /// 目標文中の「」内の文字列を現在の画面で照合し、全て見つかれば
    /// assert ステップとして記録してフローを完成扱いにする。
    private func salvageGoalAssertions(in snap: SnapshotResponse, steps: Int, bundleID: String) -> Result? {
        let quoted = Self.quotedStrings(in: goal)
        guard !quoted.isEmpty else { return nil }

        var found: [ElementInfo] = []
        for text in quoted {
            guard let element = snap.elements.first(where: {
                ($0.label ?? "").contains(text) || ($0.identifier ?? "").contains(text)
            }) else {
                return nil  // 1つでも見つからなければサルベージしない(誤検証を避ける)
            }
            found.append(element)
        }
        // 既に同じ locator の assert が記録済みなら重複追加しない
        for element in found {
            let (primary, _) = FlowLocatorBuilder.chain(for: element, in: snap.elements)
            if !flowSteps.contains(where: { $0.assert == "exists" && $0.locator == primary }) {
                record(assert: "exists", element: element, in: snap,
                       note: "目標から自動抽出した確認(探索終了時にコード側で検証済み)")
            }
        }
        let names = found.map { "「\($0.label ?? $0.identifier ?? "")」" }.joined(separator: " ")
        return finish(.completed("目標の確認要素 \(names) の表示をコード側で検証"), steps, bundleID)
    }

    static func quotedStrings(in text: String) -> [String] {
        var results: [String] = []
        var current = ""
        var inQuote = false
        for ch in text {
            switch ch {
            case "「": inQuote = true; current = ""
            case "」": if inQuote, !current.isEmpty { results.append(current) }; inQuote = false
            default: if inQuote { current.append(ch) }
            }
        }
        return results
    }

    // MARK: - 要素解決(テキスト→要素のあいまいマッチ)

    /// elementText(label/id のコピー)をスコアリングで要素に解決する。
    /// 数値参照より 3B モデルが安定して扱えることが実測で分かっている。
    private func resolveElement(_ text: String?, in snap: SnapshotResponse,
                                forTap: Bool = false, forInput: Bool = false) -> ElementInfo? {
        guard var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        // モデルが「」や id= を含めてコピーしてくることがあるため剥がす
        raw = raw.replacingOccurrences(of: "「", with: "")
                 .replacingOccurrences(of: "」", with: "")
                 .replacingOccurrences(of: "id=", with: "")
                 .trimmingCharacters(in: .whitespacesAndNewlines)

        func score(_ e: ElementInfo) -> Int? {
            var s: Int?
            if e.identifier == raw { s = 100 }
            else if e.label == raw { s = 90 }
            else if e.placeholder == raw { s = 85 }
            else if let id = e.identifier, id.localizedCaseInsensitiveContains(raw) { s = 60 }
            else if let label = e.label, label.localizedCaseInsensitiveContains(raw) { s = 55 }
            else if let ph = e.placeholder, ph.localizedCaseInsensitiveContains(raw) { s = 50 }
            guard var value = s else { return nil }
            if forInput {
                if SnapshotRenderer.textInputTypes.contains(e.type) {
                    value += 30
                    if e.value == nil { value += 10 }  // 未入力の欄を優先
                } else {
                    value -= 50
                }
            }
            if forTap {
                if Self.tappableTypes.contains(e.type) { value += 30 }
                else if !SnapshotRenderer.textInputTypes.contains(e.type) { value -= 20 }
            }
            return value
        }

        let scored = snap.elements.compactMap { e in score(e).map { (e, $0) } }
        guard let best = scored.max(by: { $0.1 == $1.1 ? $0.0.ref > $1.0.ref : $0.1 < $1.1 })?.0 else {
            return nil
        }
        // tap 意図でテキスト要素に解決された場合、それを包含する最小のタップ可能
        // 要素へリダイレクトする(リスト行のテキストは非クリック子であることが多い)
        if forTap, !Self.tappableTypes.contains(best.type),
           !SnapshotRenderer.textInputTypes.contains(best.type) {
            let cx = best.frame.centerX, cy = best.frame.centerY
            let containers = snap.elements.filter {
                Self.tappableTypes.contains($0.type)
                    && cx >= $0.frame.x && cx <= $0.frame.x + $0.frame.width
                    && cy >= $0.frame.y && cy <= $0.frame.y + $0.frame.height
            }
            if let smallest = containers.min(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }) {
                return smallest
            }
        }
        return best
    }

    static let tappableTypes: Set<String> = [
        "Button", "Cell", "Switch", "Toggle", "Link", "SegmentedControl",
        "MenuItem", "Stepper", "PickerWheel", "DatePicker", "CheckBox", "Slider",
    ]

    // MARK: - FM 呼び出し(1ステップ1セッション)

    private func makePlan() async throws -> [String] {
        let session = LanguageModelSession(
            instructions: "あなたは iOS アプリの UI テスト計画者です。テスト目標を具体的な UI 操作手順に分解します。")
        let response = try await session.respond(
            to: "テスト目標: \(goal)\n\nこの目標を達成する操作手順を挙げてください。",
            generating: TestPlan.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 400))
        return response.content.steps
    }

    private func decide(rendered: String, screenUnchanged: Bool, escapeRut: Bool = false) async throws -> NextAction {
        do {
            // 通常は greedy(再現性重視)。進捗なしが続いたら温度サンプリングで
            // greedy の轍(毎回同じ誤答)から脱出する
            let options = escapeRut
                ? GenerationOptions(temperature: 0.9, maximumResponseTokens: 350)
                : GenerationOptions(sampling: .greedy, maximumResponseTokens: 350)
            return try await respond(
                prompt: makePrompt(rendered: rendered, screenUnchanged: screenUnchanged),
                options: options)
        } catch {
            // 縮退ループやコンテキスト超過に備え、要素一覧を切り詰めた上で
            // サンプリングを変えて再試行(greedy のままでは同じ失敗を繰り返す)
            let lines = rendered.split(separator: "\n")
            let truncated = lines.prefix(40).joined(separator: "\n")
                + (lines.count > 40 ? "\n(+\(lines.count - 40) 行省略)" : "")
            return try await respond(
                prompt: makePrompt(rendered: truncated, screenUnchanged: screenUnchanged),
                options: GenerationOptions(temperature: 0.7, maximumResponseTokens: 350))
        }
    }

    private func respond(prompt: String, options: GenerationOptions) async throws -> NextAction {
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(
            to: prompt,
            generating: NextAction.self,
            options: options)
        return response.content
    }

    private func makePrompt(rendered: String, screenUnchanged: Bool) -> String {
        let journeyText = journey.isEmpty
            ? "(まだ何もしていません)"
            : journey.suffix(12).joined(separator: "\n")
        var prompt = "テスト目標: \(goal)\n"
        if !plan.isEmpty {
            prompt += "\nテスト計画:\n"
            for (index, item) in plan.enumerated() {
                prompt += "\(index + 1). \(item)\n"
            }
        }
        prompt += "\nこれまでの行動:\n\(journeyText)\n"
        if screenUnchanged {
            prompt += "(注意: 直前の操作で画面が変化していません。別のアプローチを検討してください)\n"
        }
        prompt += "\n現在の画面の要素一覧:\n\(rendered)\n\n"
        prompt += "計画を上から順に進めてください。入力欄が「未入力」のままログイン・送信ボタンを押してはいけません。次の1アクションを決めてください。"
        return prompt
    }

    // MARK: - 記録

    /// 旅程ログ用の要素表記(型+ラベル/ID)
    private func describeElement(_ element: ElementInfo) -> String {
        var name = element.type
        if let label = element.label, !label.isEmpty {
            name += "「\(label)」"
        } else if let id = element.identifier, !id.isEmpty {
            name += "(id=\(id))"
        } else if let ph = element.placeholder, !ph.isEmpty {
            name += "(\(ph))"
        }
        return name
    }

    private func record(action: String? = nil, assert: String? = nil,
                        element: ElementInfo, in snap: SnapshotResponse,
                        text: String? = nil, note: String?) {
        let (primary, fallbacks) = FlowLocatorBuilder.chain(for: element, in: snap.elements)
        flowSteps.append(FlowStep(
            action: action,
            assert: assert,
            locator: primary,
            fallbacks: fallbacks.isEmpty ? nil : fallbacks,
            text: text,
            timeout: assert != nil ? 5 : nil,
            note: note.map { String($0.prefix(120)) }))
    }

    private func describe(_ action: NextAction) -> String {
        let target = action.elementText.map { "「\($0)」" } ?? ""
        // 縮退ループで rationale が暴走することがあるため表示は切り詰める
        let why = String(action.rationale.prefix(80))
        switch action.kind {
        case .tap: return "tap \(target) — \(why)"
        case .typeText: return "type \(target) \"\(action.text ?? "")\" — \(why)"
        case .swipe: return "swipe \(action.direction ?? "up") — \(why)"
        case .assertVisible: return "assert exists \(target) — \(why)"
        case .done: return "done — \(why)"
        case .giveUp: return "giveUp — \(why)"
        }
    }

    private func finish(_ outcome: Outcome, _ steps: Int, _ bundleID: String) -> Result {
        let dirty: Bool?
        if case .completed = outcome { dirty = nil } else { dirty = true }
        let flow = Flow(
            name: goal,
            app: bundleID,
            goal: goal,
            generatedBy: "ftester explore v0.1 (apple-fm-on-device)",
            dirty: dirty,
            steps: flowSteps)
        return Result(flow: flow, outcome: outcome, stepsTaken: steps)
    }
}
