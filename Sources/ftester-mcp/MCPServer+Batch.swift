// MCPServer+Batch.swift
// ft_batch(DSL 行のパースと逐次実行)。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    // MARK: - ft_batch

    /// ステップ数の上限。理由は爆風半径と出力量(実行前に弾く。CLAUDE.md)
    static let batchStepLimit = 20

    /// ft_batch が実行を許すカテゴリ(操作系・スクロール系だけ。ユーザー決定)。
    /// **DSLCommandIndex から導出する** —— 索引にカテゴリが増減しても、この集合を手で
    /// 追随させる必要はない(名前の一覧をここへハードコードしない)
    private static let batchAllowedCategories: Set<String> = ["operation", "scroll"]

    /// app カテゴリ(ライフサイクル・破壊的)を弾いたときの具体的な代替。
    /// 「なぜ弾いたか + 代わりに何を呼ぶか」(CLAUDE.md の例: launchApp → ft_launch)
    private static let batchAppCommandAlternatives: [String: String] = [
        "launchApp": "call ft_launch first, then batch the operations that follow it",
        "openURL": "call ft_open_url instead",
        "restartApp": "call ft_terminate then ft_launch instead — there is no restart tool",
        "terminateApp": "call ft_terminate instead",
        "installApp": "call ft_install instead",
        "removeApp": "not available over MCP (there is no uninstall tool)",
        "clearAppData": "call ft_clear_app_data instead",
        "home": "call ft_navigate target: home instead",
        "back": "call ft_navigate target: back instead",
        "appSwitcher": "call ft_navigate target: appSwitcher instead",
        "tapAppIcon": "not available over MCP — ft_navigate target: home, then ft_snapshot + ft_tap",
        "screenshot": "call ft_screenshot instead",
    ]

    /// 1手ぶんの実行計画への変換。コマンド名 → FlowStep の組み立て。**ここに無い名前は、
    /// カテゴリは operation/scroll でも1ステップとして表現できないもの**
    /// (`batchUnsupportedGuidance` が理由を返す)。
    ///
    /// `keys` は「このクロージャが実際に読む raw[...] キー」の**手での宣言**(signature からの
    /// 自動導出ではない — signature には出てこないのに読むキーもある。例: `type`/`clearInput`/
    /// `doubleTap`/`pinchOut`/`pinchIn`/`swipeBy` の `timeout`)。`BatchLineParser`(ft_batch の
    /// 行パーサ)がラベルの許否をここと突き合わせ、未対応ラベルを黙って捨てずに拒否する
    /// (`BatchKeyTypeCoverageTests` が「signature から導出できるか keys に載っているか」を
    /// 全ビルダに対して確認する)。順序は「サポートしている引数」のメッセージにそのまま出る
    struct BatchStepBuilder {
        let keys: [String]
        let build: ([String: Any]) throws -> (step: FlowStep, summary: String)
    }

    static let batchStepBuilders: [String: BatchStepBuilder] = [
        "tap": BatchStepBuilder(keys: ["selector", "holdSeconds", "timeout", "x", "y"]) { raw in
            let hold = raw["holdSeconds"] as? Double ?? FlowStep.defaultTapHoldSeconds
            let duration = hold == FlowStep.defaultTapHoldSeconds ? nil : hold
            // **座標タップは受ける**。DSL の `tap(x:y:)` があり `ScenarioCodeGen` が 1:1 で
            // 書き出せるので、「通ったバッチはシナリオ行になる」契約は保たれる。
            // **セレクタと併記されたら拒否する**(黙ってどちらかを選ぶと、読み手は自分が何を
            // 撃ったのか分からない)
            if let x = raw["x"] as? Double, let y = raw["y"] as? Double {
                guard raw["selector"] == nil else {
                    throw MCPError("tap takes either a selector or x/y, not both —"
                        + " drop one (a selector survives a layout change, coordinates do not)")
                }
                let step = FlowStep(action: "tap", duration: duration, x: x, y: y)
                return (step, "tap (\(FTSeconds.format(x)), \(FTSeconds.format(y)))")
            }
            if raw["x"] != nil || raw["y"] != nil {
                throw MCPError("tap needs both x and y for a coordinate tap")
            }
            let selector = try requiredBatchSelector(raw, command: "tap")
            let step = FlowStep(action: "tap", locator: selector.primary,
                                fallbacks: batchFallbacks(selector),
                                timeout: raw["timeout"] as? Double,
                                duration: duration)
            return (step, "tap \"\(selector.text)\"")
        },
        "select": BatchStepBuilder(keys: ["selector", "timeout"]) { raw in
            let selector = try requiredBatchSelector(raw, command: "select")
            let step = FlowStep(action: "select", locator: selector.primary,
                                fallbacks: batchFallbacks(selector), timeout: raw["timeout"] as? Double)
            return (step, "select \"\(selector.text)\"")
        },
        "type": BatchStepBuilder(keys: ["selector", "text", "timeout"]) { raw in
            guard let text = raw["text"] as? String, !text.isEmpty else {
                throw MCPError("type requires text")
            }
            let selector = optionalBatchSelector(raw)
            let step = FlowStep(action: "type", locator: selector?.primary,
                                fallbacks: selector.flatMap(batchFallbacks), text: text,
                                timeout: raw["timeout"] as? Double)
            let target = selector.map { " \"\($0.text)\"" } ?? ""
            return (step, "type\(target) \"\(text)\"")
        },
        "pressEnter": BatchStepBuilder(keys: []) { _ in (FlowStep(action: "pressEnter"), "pressEnter") },
        "rotateTo": BatchStepBuilder(keys: ["orientation"]) { raw in
            guard let text = raw["orientation"] as? String,
                  let orientation = FTOrientation.parse(text) else {
                throw MCPError("rotateTo takes .portrait or .landscape")
            }
            var step = FlowStep(action: "rotateTo")
            step.direction = orientation.rawValue
            return (step, "rotateTo .\(orientation.rawValue)")
        },
        "hideKeyboard": BatchStepBuilder(keys: []) { _ in
            (FlowStep(action: "hideKeyboard"), "hideKeyboard")
        },
        "clearInput": BatchStepBuilder(keys: ["selector", "timeout"]) { raw in
            let selector = optionalBatchSelector(raw)
            let step = FlowStep(action: "clearInput", locator: selector?.primary,
                                fallbacks: selector.flatMap(batchFallbacks),
                                timeout: raw["timeout"] as? Double)
            return (step, selector.map { "clearInput \"\($0.text)\"" } ?? "clearInput")
        },
        "swipe": BatchStepBuilder(keys: ["direction"]) { raw in
            guard let text = raw["direction"] as? String, let direction = FTSwipeDirection(rawValue: text)
            else {
                throw MCPError("swipe requires direction (one of up/down/left/right — finger direction)")
            }
            return (FlowStep(action: "swipe", direction: direction.rawValue), "swipe \(direction.rawValue)")
        },
        "doubleTap": BatchStepBuilder(keys: ["selector", "timeout"]) { raw in
            let selector = optionalBatchSelector(raw)
            let step = FlowStep(action: "doubleTap", locator: selector?.primary,
                                fallbacks: selector.flatMap(batchFallbacks),
                                timeout: raw["timeout"] as? Double)
            return (step, selector.map { "doubleTap \"\($0.text)\"" } ?? "doubleTap")
        },
        "pinchOut": BatchStepBuilder(keys: ["selector", "scale", "durationSeconds", "timeout"]) {
            batchPinchStep("pinchOut", defaultScale: FlowStep.defaultPinchOutScale, raw: $0)
        },
        "pinchIn": BatchStepBuilder(keys: ["selector", "scale", "durationSeconds", "timeout"]) {
            batchPinchStep("pinchIn", defaultScale: FlowStep.defaultPinchInScale, raw: $0)
        },
        "swipeBy": BatchStepBuilder(
            keys: ["selector", "dxRatio", "dyRatio", "durationSeconds", "timeout"]
        ) { raw in
            guard let dxRatio = raw["dxRatio"] as? Double, let dyRatio = raw["dyRatio"] as? Double else {
                throw MCPError("swipeBy requires dxRatio and dyRatio")
            }
            let selector = optionalBatchSelector(raw)
            let duration = raw["durationSeconds"] as? Double ?? FlowStep.defaultSwipeDurationSeconds
            let step = FlowStep(action: "swipeBy", locator: selector?.primary,
                                fallbacks: selector.flatMap(batchFallbacks),
                                timeout: raw["timeout"] as? Double,
                                duration: duration == FlowStep.defaultSwipeDurationSeconds ? nil : duration,
                                dxRatio: dxRatio, dyRatio: dyRatio)
            let target = selector.map { " \"\($0.text)\"" } ?? ""
            return (step, "swipeBy\(target) (\(dxRatio), \(dyRatio))")
        },
        "swipeElementToElement": BatchStepBuilder(
            keys: ["selector", "to", "durationSeconds"]
        ) { raw in
            let from = try requiredBatchSelector(raw, command: "swipeElementToElement")
            guard let toText = raw["to"] as? String, !toText.isEmpty else {
                throw MCPError("swipeElementToElement requires to (the end selector)")
            }
            let to = FTSelector.parse(toText)
            let duration = raw["durationSeconds"] as? Double ?? FlowStep.defaultSwipeDurationSeconds
            let step = FlowStep(action: "swipeElementToElement", locator: from.primary,
                                fallbacks: batchFallbacks(from), endLocator: to.primary,
                                duration: duration == FlowStep.defaultSwipeDurationSeconds ? nil : duration)
            return (step, "swipeElementToElement \"\(from.text)\" → \"\(to.text)\"")
        },
        "scrollTo": BatchStepBuilder(
            keys: ["selector", "direction", "maxSwipes", "scrollFrame"]
        ) { raw in
            let selector = try requiredBatchSelector(raw, command: "scrollTo")
            guard let direction = FTScrollDirection(rawValue: raw["direction"] as? String ?? "down") else {
                throw MCPError("direction must be one of down/up/right/left (content direction)")
            }
            let step = FlowStep(action: "scrollTo", locator: selector.primary,
                                fallbacks: batchFallbacks(selector), direction: direction.swipe.rawValue,
                                maxSwipes: raw["maxSwipes"] as? Int ?? FlowStep.defaultMaxSwipes,
                                scrollFrame: batchScrollFrame(raw))
            return (step, "scrollTo \"\(selector.text)\"")
        },
        "scrollDown": BatchStepBuilder(keys: ["repeat", "scrollFrame"]) {
            batchScrollStep(.down, raw: $0)
        },
        "scrollUp": BatchStepBuilder(keys: ["repeat", "scrollFrame"]) {
            batchScrollStep(.up, raw: $0)
        },
        "scrollRight": BatchStepBuilder(keys: ["repeat", "scrollFrame"]) {
            batchScrollStep(.right, raw: $0)
        },
        "scrollLeft": BatchStepBuilder(keys: ["repeat", "scrollFrame"]) {
            batchScrollStep(.left, raw: $0)
        },
        "scrollToBottom": BatchStepBuilder(keys: ["maxSwipes", "scrollFrame"]) {
            batchScrollEdgeStep(.down, name: "scrollToBottom", raw: $0)
        },
        "scrollToTop": BatchStepBuilder(keys: ["maxSwipes", "scrollFrame"]) {
            batchScrollEdgeStep(.up, name: "scrollToTop", raw: $0)
        },
        "scrollToRightEdge": BatchStepBuilder(keys: ["maxSwipes", "scrollFrame"]) {
            batchScrollEdgeStep(.right, name: "scrollToRightEdge", raw: $0)
        },
        "scrollToLeftEdge": BatchStepBuilder(keys: ["maxSwipes", "scrollFrame"]) {
            batchScrollEdgeStep(.left, name: "scrollToLeftEdge", raw: $0)
        },
    ]

    private static func requiredBatchSelector(_ raw: [String: Any], command: String) throws -> FTSelector {
        guard let text = raw["selector"] as? String, !text.isEmpty else {
            throw MCPError("\(command) requires selector (same syntax as the DSL: #id, a label, .type, a||b)")
        }
        return FTSelector.parse(text)
    }

    private static func optionalBatchSelector(_ raw: [String: Any]) -> FTSelector? {
        guard let text = raw["selector"] as? String, !text.isEmpty else { return nil }
        return FTSelector.parse(text)
    }

    private static func batchFallbacks(_ selector: FTSelector) -> [FlowLocator]? {
        selector.fallbacks.isEmpty ? nil : selector.fallbacks
    }

    private static func batchScrollFrame(_ raw: [String: Any]) -> FlowLocator? {
        guard let text = raw["scrollFrame"] as? String, !text.isEmpty else { return nil }
        return FTSelector.parse(text).primary
    }

    private static func batchPinchStep(_ action: String, defaultScale: Double, raw: [String: Any])
        -> (step: FlowStep, summary: String) {
        let selector = optionalBatchSelector(raw)
        let scale = raw["scale"] as? Double ?? defaultScale
        let duration = raw["durationSeconds"] as? Double ?? FlowStep.defaultPinchDurationSeconds
        let step = FlowStep(action: action, locator: selector?.primary,
                            fallbacks: selector.flatMap(batchFallbacks),
                            timeout: raw["timeout"] as? Double,
                            duration: duration == FlowStep.defaultPinchDurationSeconds ? nil : duration,
                            scale: scale)
        let target = selector.map { " \"\($0.text)\"" } ?? ""
        return (step, "\(action)\(target) x\(scale)")
    }

    private static func batchScrollStep(_ direction: FTScrollDirection, raw: [String: Any])
        -> (step: FlowStep, summary: String) {
        let times = raw["repeat"] as? Int ?? 1
        let step = FlowStep(action: "scroll", direction: direction.swipe.rawValue,
                            maxSwipes: max(1, times), scrollFrame: batchScrollFrame(raw))
        let name = "scroll\(direction.rawValue.capitalized)"
        return (step, times > 1 ? "\(name) ×\(times)" : name)
    }

    private static func batchScrollEdgeStep(_ direction: FTScrollDirection, name: String,
                                            raw: [String: Any]) -> (step: FlowStep, summary: String) {
        let step = FlowStep(action: "scrollToEdge", direction: direction.swipe.rawValue,
                            maxSwipes: raw["maxSwipes"] as? Int ?? FlowStep.defaultMaxEdgeSwipes,
                            scrollFrame: batchScrollFrame(raw))
        return (step, name)
    }

    /// category が operation/scroll 以外の DSL コマンドを弾いたときの一般案内(app 以外)。
    /// カテゴリ名は列挙せずメッセージだけ変える —— 索引にカテゴリが増えても分岐を足さずに済む
    /// よう、既知カテゴリだけ具体化し、それ以外は ft_dsl_commands へ誘導する
    private static func batchCategoryGuidance(_ category: String) -> String {
        switch category {
        case "existence", "id", "text", "value", "this":
            return "It is an assertion — run ft_snapshot after the batch and check it yourself, or"
                + " write the assertion when you save the scenario."
        case "control":
            return "It is DSL control flow (loop/conditional), which only makes sense inside a"
                + " written scenario."
        case "structure":
            return "It is a structural DSL keyword (scene/action/expectation/…), not a runnable step."
        case "flick":
            return "flick gestures are out of scope for ft_batch — write it into the scenario, or"
                + " use ft_drag for a similar swipe."
        default:
            return "See ft_dsl_commands category: \(category)."
        }
    }

    /// operation/scroll カテゴリの中で、まだ1ステップに翻訳できていない名前の案内
    /// (block を包むコマンド・座標直指定・値アクセサ)
    private static func batchUnsupportedGuidance(_ command: String) -> String {
        if command == "lastElement" {
            return "lastElement reads the element the previous select/exist grabbed — it runs nothing."
        }
        if command == "swipePointToPoint" {
            return "swipePointToPoint drives raw coordinates outside selector resolution — call"
                + " ft_drag instead."
        }
        if command.hasPrefix("existWith") {
            return "it is an assertion (exist) — ft_batch only runs operations."
        }
        if command.hasPrefix("selectWith") {
            return "select does not touch the device and cannot be chained to an assertion inside a"
                + " batch — use a scrollTo/scrollDown step, then ft_snapshot."
        }
        if command.hasPrefix("tapWith") {
            return "it is a scroll+tap alias — put a scrollTo (or scrollDown/Up/Right/Left) step"
                + " before a plain tap step instead."
        }
        if command.hasPrefix("with") {
            return "it wraps a block of other commands — ft_batch steps are flat; give the wrapped"
                + " commands as their own steps instead."
        }
        return "call ft_dsl_commands name: \(command) to see what it does."
    }

    /// 1手ぶんの計画。**1手目に限り ref を持てる**(`pendingRef` が非 nil)。ref をセレクタへ
    /// 解決するには生きたスナップショットが要る(RefGuard の再照合 + SelectorNaming の一意性検査)
    /// ので、その解決だけは実行ループの直前(driver 取得後)まで持ち越す —— `step`/`summary` は
    /// その間ダミー(実行はされない。`resolvePendingRef` が上書きしてから使う)
    struct BatchPlannedStep {
        var step: FlowStep
        var summary: String
        var pendingRef: PendingBatchRef?
    }

    /// 1手目の ref を解決するのに要る材料。`raw` は selector 抜き(解決後にそこへ差し込んで
    /// 同じ builder へ通す —— セレクタが書ける手なら builder の組み立てロジックを2つ持たない)
    struct PendingBatchRef {
        let ref: Int
        let raw: [String: Any]
        let builder: BatchStepBuilder
    }

    /// 1手(DSL の呼び出し1行)の検証(**デバイスに触らない**。実行前に全行へ通す)。
    /// 構文は `BatchLineParser`(純粋関数)、引数の妥当性は `BatchStepResolver` に委ね、ここは
    /// 「コマンド名は実在するか」「カテゴリは operation/scroll か」「1ステップへ翻訳できるか」の
    /// 3段だけを見る(既存の拒否経路。名前・カテゴリのメッセージは変えない)。
    ///
    /// **ref はステップ0(1手目)でだけ、セレクタを取るコマンドでだけ書ける**
    /// (`BatchStepResolver.resolve` が stepIndex とセレクタの有無で判定する)。通った場合、
    /// `raw["ref"]` に整数が入り、`builder.build` はまだ呼ばない(セレクタが無いので呼べない)
    /// —— `pendingRef` に包んで返し、解決は `batch(_:)` 側(driver 取得後)に委ねる
    private static func planBatchStep(_ line: String, stepIndex: Int) throws -> BatchPlannedStep {
        let parsed: BatchParsedLine
        do {
            parsed = try BatchLineParser.parse(line)
        } catch let error as BatchLineSyntaxError {
            var message = error.baseMessage
            if let name = error.commandName,
               let info = DSLCommandIndex.all.first(where: { $0.name == name }) {
                // シグネチャは正形(括弧+カンマ)で書かれている —— そのまま写すと今度は
                // 括弧の拒否を踏むので、バッチでの書き方を毎回添える
                message += " Signature: \(info.signature) — in ft_batch, write it without"
                    + " parentheses/commas (single-quoted, space-separated)."
            }
            message += " See ft_dsl_commands."
            throw MCPError(message)
        }
        let command = parsed.name
        guard let info = DSLCommandIndex.all.first(where: { $0.name == command }) else {
            throw MCPError("\"\(command)\" is not a DSL command — call ft_dsl_commands to see the"
                + " valid names (a name not in that index does not exist)")
        }
        guard batchAllowedCategories.contains(info.category) else {
            if info.category == "app", let alternative = batchAppCommandAlternatives[command] {
                throw MCPError("\"\(command)\" changes the app's lifecycle or its data, which ft_batch"
                    + " does not run (one approval should not be able to reach data-wiping commands)"
                    + " — \(alternative)")
            }
            throw MCPError("\"\(command)\" is a \(info.category) DSL command — ft_batch only runs"
                + " operation/scroll commands. " + batchCategoryGuidance(info.category))
        }
        guard let builder = batchStepBuilders[command] else {
            throw MCPError("\"\(command)\" is recognized (category: \(info.category)) but ft_batch"
                + " has no single-step translation for it — \(batchUnsupportedGuidance(command))")
        }
        let raw: [String: Any]
        do {
            raw = try BatchStepResolver.resolve(command: command, signature: info.signature,
                                                args: parsed.args, declaredKeys: builder.keys,
                                                stepIndex: stepIndex)
        } catch let error as BatchStepResolver.ResolveError {
            throw MCPError(error.message)
        }
        if let ref = raw["ref"] as? Int {
            var withoutRef = raw
            withoutRef["ref"] = nil
            return BatchPlannedStep(step: FlowStep(action: command), summary: "\(command) ref \(ref)",
                                    pendingRef: PendingBatchRef(ref: ref, raw: withoutRef, builder: builder))
        }
        let (step, summary) = try builder.build(raw)
        return BatchPlannedStep(step: step, summary: summary, pendingRef: nil)
    }

    /// 1手目の ref をセレクタへ解決する。**ft_tap と同じ経路を通す**(2つ目の実装を作らない):
    /// `verifiedRef` が RefGuard で再照合する(gone は throw・ghost/moved は警告付きで進む —
    /// ft_tap の扱いと食い違わせない)。掴めた要素からステップを組む純粋な部分は
    /// `buildResolvedRefStep` に切り出してある(デバイスへ触れないのでテストしやすい)
    private func resolvePendingBatchRef(_ pending: PendingBatchRef, driver: AppDriver,
                                        args: [String: Any]) async throws
        -> (step: FlowStep, summary: String, note: String) {
        let (resolvedRef, refNote) = try await verifiedRef(pending.ref, driver: driver, args: args)
        guard let snapshot = lastSnapshots[Self.engineKey(args)],
              let element = snapshot.elements.first(where: { $0.ref == resolvedRef }) else {
            // verifiedRef が撮り直した木に無いことは実際には起きない(見つからなければ .gone で
            // 既に throw している)が、将来ここが緩んでも黙って落ちないよう明示する
            throw MCPError("ref [\(pending.ref)] could not be re-read after resolving —"
                + " take a fresh ft_snapshot and try again")
        }
        return try Self.buildResolvedRefStep(pending, element: element, snapshot: snapshot,
                                             refNote: refNote)
    }

    /// **純粋な部分**: 掴めた要素(`element`)から、ft_batch がそのまま実行できるステップを組む。
    /// `SelectorNaming.graded` が「そのまま書けるセレクタ」を作る(ft_tap の推奨セレクタと同じ
    /// 実装)。**graded が nil(セレクタが作れない)のときだけここで拒否する** —— RefGuard は
    /// 「叩けるか」しか見ないので、「シナリオへ書けるセレクタがあるか」は別の関門
    static func buildResolvedRefStep(_ pending: PendingBatchRef, element: ElementInfo,
                                     snapshot: SnapshotResponse, refNote: String) throws
        -> (step: FlowStep, summary: String, note: String) {
        guard let graded = Self.SelectorNaming(snapshot).graded(for: element, in: snapshot) else {
            throw MCPError("[\(pending.ref)] \(RefGuard.describe(element)) has no selector that"
                + " picks it out uniquely on this screen, so ft_batch cannot target it (a batch"
                + " step must be reproducible as a selector). Call ft_tap ref: \(pending.ref)"
                + " instead, then run the rest as a separate ft_batch.")
        }
        var raw = pending.raw
        raw["selector"] = graded.selector
        let (step, summary) = try pending.builder.build(raw)
        let caution = graded.durability == .indexed ? graded.durability.caution : ""
        let note = " (ref \(pending.ref) resolved to this selector\(caution))" + refNote
        return (step, summary, note)
    }

    /// steps の文字列を手に分割する(`;` と改行が区切り。引用符の中は区切らない ——
    /// 規則は `BatchLineParser.splitSteps`)。前後の空白は `BatchLineParser.normalize` と同じ規則で
    /// 落とし、空行は無視する。**上限は分割後の手数で数える**(CLAUDE.md)
    static let batchStepsUsage = "steps is required — DSL lines in one string, e.g."
        + " \"tap '#id'; swipe .up\""

    static func flattenBatchLines(_ raw: String) -> [String] {
        BatchLineParser.splitSteps(raw)
            .map(BatchLineParser.normalize)
            .filter { !$0.isEmpty }
    }

    /// run up to `batchStepLimit` operation/scroll DSL steps in one approval, stopping at the
    /// first failure. Execution is delegated to `StepExecutor` (same driver/hint resolution as
    /// `scrollTo` — `resolveExecutorHints`); the final tree goes through the shared render path
    /// (`snapshotBody`) so it carries the same MCP-only notes (ghost/occlusion/offscreen) that
    /// ft_snapshot does. Per-step output is folded to one line each — only the last screen gets a tree
    func batch(_ args: [String: Any]) async throws -> [[String: Any]] {
        // steps は文字列1本だけ(2026-08-10 ユーザー決定・表記は1つ。配列形は廃止)。
        // MCP の arguments はオブジェクト必須なのでキー自体は消せず、これが最小の形
        guard let joined = args["steps"] as? String else {
            if args["steps"] is [Any] {
                throw MCPError("steps is one string, not an array — separate steps with ';':"
                    + " \"tap '#id'; swipe .up\"")
            }
            throw MCPError(Self.batchStepsUsage)
        }
        let dslLines = Self.flattenBatchLines(joined)
        guard !dslLines.isEmpty else {
            throw MCPError(Self.batchStepsUsage)
        }
        guard dslLines.count <= Self.batchStepLimit else {
            throw MCPError("steps has \(dslLines.count) entries — ft_batch allows at most"
                + " \(Self.batchStepLimit) per call (blast radius and output size)")
        }
        // **全手を実行前に検証する**: 途中の手が弾かれると分かっているのに、それより前の手を
        // デバイスへ通すと、失敗前提の状態変化だけを残すことになる
        var plans: [BatchPlannedStep] = []
        for (index, line) in dslLines.enumerated() {
            do {
                plans.append(try Self.planBatchStep(line, stepIndex: index))
            } catch {
                var message = "step \(index + 1): \(error.localizedDescription)"
                // 閉じ忘れの引用符は後続の手をこの手に呑み込む(splitSteps は引用符の中の `;` で
                // 区切らないため)。呑み込んだ行を黙って見せると、書いた覚えのない step 1 を
                // 延々と直すことになる —— 実際の誤りは引用符のほう
                if line.contains(";") || line.contains("\n") {
                    message += " (this step contains a ';' or a newline — if you did not write"
                        + " them in one step, an unbalanced quote merged the following steps"
                        + " into this one; escape apostrophes as \\' inside '…', or use \"…\")"
                }
                throw MCPError(message)
            }
        }

        let batchDriver = try await driver(args)
        // **手が動く前の起点**(settle-lite の beforeAction と同じ役目)。ループ中は recordSnapshot
        // を呼ばない(呼ぶのは失敗時の throw 直前と成功時の末尾だけ)ので、ここで捕まえておけば
        // 上書きより先に取れる
        let beforeBatch = lastSnapshots[Self.engineKey(args)]
        let (isAndroid, uiFrameworkHint) = await resolveExecutorHints(batchDriver, args: args)
        let executor = StepExecutor(driver: batchDriver, releasesScrollTouch: !isAndroid,
                                    uiFramework: uiFrameworkHint)
        let clock = ContinuousClock()

        // **1手目の ref はここで初めて解決する**(driver が要る: RefGuard の再照合と
        // SelectorNaming の一意性検査)。それでも実行ループの前 —— 「全手を実行前に検証する」を
        // 崩さない。パーサが ref を1手目にしか通さないので、plans[1...] は pendingRef を持たない
        var refResolutionNote: String?
        if let pending = plans[0].pendingRef {
            let resolved = try await resolvePendingBatchRef(pending, driver: batchDriver, args: args)
            plans[0].step = resolved.step
            plans[0].summary = resolved.summary
            plans[0].pendingRef = nil
            refResolutionNote = resolved.note
        }

        var lines: [String] = []
        for (index, plan) in plans.enumerated() {
            let start = clock.now
            let outcome = await executor.execute(plan.step)
            let ms = Int((clock.now - start) / .milliseconds(1))
            // **実行した手はそのまま記録する**(利用者が書いた式のまま — 解決後の要素ではない。
            // scrollTo の記録と同じ理由)。ただし ref だった1手目は上で既にセレクタへ差し替え済み
            // なので、記録されるのも解決後のセレクタを持つ step(ref は下書きに書けない)。
            // 失敗した手も記録する: draft には失敗が残っていたほうが「何を試して止まったか」が
            // 追える(InteractionLog は成否を持たず落とさない)
            interactions.record(InteractionLog.Entry(step: plan.step, unresolved: nil,
                                                     summary: plan.summary))
            let refNote = index == 0 ? (refResolutionNote ?? "") : ""
            guard StepExecutor.isSuccess(outcome.status) else {
                let reason: String
                switch outcome.status {
                case .failed(let message), .skipped(let message), .inconclusive(let message):
                    reason = message
                case .passed, .passedViaFallback, .healed:
                    reason = "could not confirm the result"
                }
                lines.append("\(index + 1). \(plan.summary) — FAILED (\(ms)ms): \(reason)" + refNote)
                // **止まった位置と、そこで見えている画面を一緒に返す**(scrollTo の failure と
                // 同じ形: throw で isError にする — 呼び手が要求した手が最後まで実行されなかった
                // という点で、要素へ届かなかった scrollTo と同種の失敗)
                let stopped = try await freshSnapshot(batchDriver, args: args)
                recordSnapshot(stopped, batchDriver is AndroidDriver ? "android" : "ios", args)
                throw MCPError(lines.joined(separator: "\n")
                    + "\n\nStopped at step \(index + 1) of \(plans.count) — later steps were not run.\n\n"
                    + (await snapshotBody(stopped, driver: batchDriver, args: args)))
            }
            var okLine = "\(index + 1). \(plan.summary) — ok (\(ms)ms)"
            if case .passedViaFallback(let locator) = outcome.status {
                okLine += " (matched via the fallback \(locator.summary))"
            }
            if let fallback = outcome.driverFallback { okLine += " (\(fallback))" }
            okLine += refNote
            lines.append(okLine)
        }
        let (unchangedNote, final) = try await Self.batchUnchangedNote(
            beforeBatch: beforeBatch, final: try await freshSnapshot(batchDriver, args: args),
            stepCount: plans.count, engine: engines[Self.engineKey(args)]) {
            // settle-lite と同じ待ち(snapshotAfterBodyWithStatus 参照。新しい定数は置かない)
            try await Task.sleep(nanoseconds: UInt64(max(0, self.settleWaitSeconds) * 1_000_000_000))
            return try await self.freshSnapshot(batchDriver, args: args)
        }
        recordSnapshot(final, batchDriver is AndroidDriver ? "android" : "ios", args)
        return text(lines.joined(separator: "\n") + "\n\nAll \(plans.count) step(s) passed.\n\n"
            + unchangedNote + (await snapshotBody(final, driver: batchDriver, args: args)))
    }

    /// バッチ開始前の木(`beforeBatch`)と、全手が通った後の木(`final`)が見分けが付かないときの
    /// 注記。**同一性判定は `MCPServer.looksUnchanged` を再利用する**(2つ目を書かない)。
    /// 形は snapshotAfterBodyWithStatus の settle-lite 分岐と同じ: 1回だけ短く待って撮り直し、
    /// それでも同一なら「どの手も画面を変えなかったかもしれない」と言うだけで断定しない
    /// (縁で止まっているだけの正当なケースがあるため)。撮り直したら、以後の表示・記録は
    /// **撮り直したほうの木**を使う(snapshotAfterBodyWithStatus と同じ)。
    /// `beforeBatch` が nil(起点を知らない)なら比較対象が無いので何もしない。
    /// **木がほぼ空の画面には `unrepresentedScreenCaveat` を添える**(2026-08-13 監査。
    /// MCPServer+Snapshot.swift 参照) —— 空の木は必ず「変化なし」に一致するため
    /// `engine` は iOS のシステムダイアログの案内を出すかの判定にだけ使う
    /// (`systemDialogHint` 参照。既定 nil = engine 不明として出す側)
    static func batchUnchangedNote(beforeBatch: SnapshotResponse?, final: SnapshotResponse,
                                   stepCount: Int, engine: String? = nil,
                                   reread: () async throws -> SnapshotResponse) async rethrows
        -> (note: String, snapshot: SnapshotResponse) {
        guard let beforeBatch, Self.looksUnchanged(beforeBatch, final) else { return ("", final) }
        let rereadSnapshot = try await reread()
        if Self.looksUnchanged(final, rereadSnapshot) {
            return ("note: every one of the \(stepCount) step(s) reported success, but the tree is"
                + " still identical to the one before the batch started, even after a short"
                + " re-read wait — none of the steps may have actually changed the screen. It can"
                + " also be legitimate: the screen was already at the target state, or the steps"
                + " went somewhere and came back."
                + Self.unrepresentedScreenCaveat(rereadSnapshot)
                + Self.systemDialogHint(engine: engine) + "\n", rereadSnapshot)
        }
        return ("note: the tree looked unchanged right after the last step, so it was re-read once"
            + " after a short wait — the tree below is the re-read, not the tree right after the"
            + " last step.\n", rereadSnapshot)
    }

    /// シートを広げたときにグラバーを運ぶ先(画面高に対する比)。**上端そのものにはしない** ——
    /// ステータスバーへ届かせても得は無く、行き過ぎたドラッグはシートを閉じる実装がある
    static let expandedSheetTopRatio = 0.12
}
