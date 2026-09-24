// MCPServer+GesturesTools.swift
// ジェスチャ・画面遷移系ツール(swipe / rotate / navigate / double_tap / drag / pinch / gesture / long_press)。入口の振り分けは MCPServer+Dispatch.swift の dispatch

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    func ftSwipe(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let direction = FTSwipeDirection(rawValue: args["direction"] as? String ?? "") else {
            throw MCPError("direction must be one of up/down/left/right")
        }
        try Self.validateScrollFrameArg(args)
        let swipeDriver = try await driver(args)
        // **未指定は今までと1バイトも変えない**(全画面固定の既定経路)。
        // **例外はキーボード表示中**(2026-08-31): 直近の `ft_snapshot` の控えがキーボードを
        // 申告していれば、素の driver.swipe ではなく DSL の swipe と同じ StepExecutor の
        // "swipe" ステップへ回す(StepExecutor+Actions.swift 参照。座標の合成・fail-fast を
        // MCP に2つ目実装しない)。**控えは古びうる方向にだけ倒す** —— 消えていれば
        // ここを通らず素の swipe へ落ち、StepExecutor 自身の撮り直しがキーボード無しと
        // 判定するので path は結局 nil(黙って全画面固定に戻るだけで誤動作しない)
        guard args["scrollFrame"] != nil else {
            let cached = lastSnapshots[Self.engineKey(args)]
            let keyboardUp = cached?.keyboardFrame != nil || cached?.keyboardShown == true
            guard keyboardUp else {
                try await swipeDriver.swipe(direction)
                recordInteraction(action: "swipe", resolvedRef: nil, args: args,
                                  direction: direction.rawValue)
                // **「動いた」と断言しない**(back と同じ理由。2026-08-06)。スワイプは端に着いて
                // いれば1px も動かないし、スクロールできない画面では何も起きない
                return text("swipe \(direction.rawValue) sent."
                    + Self.changedHint(args, otherwise: " If anything moved, the old refs are stale"
                        + " — take a fresh ft_snapshot before using any ref")
                    + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
            }
            let step = FlowStep(action: "swipe", direction: direction.rawValue)
            let (isAndroid, uiFrameworkHint) = await resolveExecutorHints(swipeDriver, args: args)
            let executor = StepExecutor(driver: swipeDriver, releasesScrollTouch: !isAndroid, isAndroid: isAndroid,
                                        uiFramework: uiFrameworkHint)
            let outcome = await executor.execute(step)
            guard StepExecutor.isSuccess(outcome.status) else {
                let reason: String
                switch outcome.status {
                case .failed(let message), .skipped(let message), .inconclusive(let message):
                    reason = message
                case .passed, .passedViaFallback, .healed:
                    reason = "could not confirm the result"
                }
                throw MCPError(reason)
            }
            recordInteraction(action: "swipe", resolvedRef: nil, args: args,
                              direction: direction.rawValue)
            return text("swipe \(direction.rawValue) sent"
                + " (the soft keyboard was up — swiped in the area above it)."
                + Self.changedHint(args, otherwise: " If anything moved, the old refs are stale"
                    + " — take a fresh ft_snapshot before using any ref")
                + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
        }

        // **探索(ft_scroll_to)と同じ StepExecutor に委ねる**(DSL の
        // scrollDown/scrollUp/scrollLeft/scrollRight(scrollFrame:) と同じ FlowStep 形。
        // ScrollGeometry の呼び出し・マージン定数・容器解決・fail-fast は全部あちらに
        // 1本化されている — MCP に2つ目の実装を作らない。**実機で確認した実害**
        //: MCP から driver.swipe(_:intent:path:) を直に叩くと、in-app
        // ブリッジは領域指定つきスクロールを 501 で拒否する設計(Compose/Flutter。
        // InAppBridge/Sources/InAppBridge.swift:673-677「黙って別の領域を動かすより
        // 501 で XCUITest へ回す」)で、その 501→XCUITest フォールバックは
        // `StepExecutor.swipeWithFallback`(StepExecutor+Settle.swift:479
        // `DriverError.isEngineIncapable(error), let td = typeDriver`)にしか無いため、
        // in-app 単独のエンジンで ft_swipe が 501 のまま終わっていた
        let scrollFrameArg = try await resolveScrollFrameArg(args, driver: swipeDriver)
        let scrollFrameLabelNote = scrollFrameArg.note.isEmpty ? ""
            : "note: the scrollFrame ref was re-checked against the current tree\(scrollFrameArg.note).\n"
        let step = Self.swipeScrollFrameStep(direction: direction, scrollFrameArg: scrollFrameArg)
        let (isAndroid, uiFrameworkHint) = await resolveExecutorHints(swipeDriver, args: args)
        let executor = StepExecutor(driver: swipeDriver, releasesScrollTouch: !isAndroid, isAndroid: isAndroid,
                                    uiFramework: uiFrameworkHint)
        let outcome = await executor.execute(step)
        guard StepExecutor.isSuccess(outcome.status) else {
            let reason: String
            switch outcome.status {
            case .failed(let message), .skipped(let message), .inconclusive(let message):
                reason = message
            case .passed, .passedViaFallback, .healed:
                reason = "could not confirm the result"
            }
            // **容器なし/経路なしの文言は StepExecutor(FTCore)側の1本だけ**
            // (scrollFrameFailFastMessage)。MCP 側で二重に持たない
            throw MCPError(scrollFrameLabelNote + reason)
        }
        let containerName = scrollFrameArg.original.map(RefGuard.describe)
            ?? scrollFrameArg.locator?.summary ?? "the scrollFrame"
        // **下書きへは実行した step をそのまま渡す**: action "scroll" は
        // scrollDown/scrollUp/scrollLeft/scrollRight(scrollFrame:) として書き戻せる
        // (ScenarioCodeGen の "scroll" ケース)。**ref 形だけは書き戻せない** ——
        // rect は木の中の座標で、セレクタとして再現できないので正直に unresolved で残す
        // (セレクタの無い要素と同じ regime)
        if scrollFrameArg.locator != nil {
            recordAction(InteractionLog.Entry(
                step: step, unresolved: nil,
                summary: "swipe \(direction.rawValue) inside \(containerName)"), args: args)
        } else {
            recordAction(InteractionLog.Entry(
                step: nil,
                unresolved: "swipe \(direction.rawValue) inside \(containerName) — the container"
                    + " was given as a ref, which no selector reproduces; name it with a"
                    + " selector to get a scrollDown/scrollUp/scrollLeft/scrollRight line",
                summary: "swipe \(direction.rawValue) inside \(containerName)"
                    + " [no stable DSL reproduction]"), args: args)
        }
        let fallbackNote = outcome.driverFallback.map { " (\($0))" } ?? ""
        return text(scrollFrameLabelNote + "swipe \(direction.rawValue) sent inside \(containerName)."
            + fallbackNote
            + Self.changedHint(args, otherwise: " If anything moved, the old refs are stale"
                + " — take a fresh ft_snapshot before using any ref")
            + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
    }

    func ftRotate(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let raw = args["orientation"] as? String,
              let orientation = FTOrientation.parse(raw) else {
            throw MCPError("orientation must be \"portrait\" or \"landscape\"")
        }
        let rotateDriver = try await driver(args)
        let settled = try await rotateDriver.rotate(to: orientation)
        var rotateStep = FlowStep(action: "rotateTo")
        rotateStep.direction = settled.rawValue
        recordAction(InteractionLog.Entry(step: rotateStep, unresolved: nil,
                                          summary: "rotateTo .\(settled.rawValue)"), args: args)
        // **回転はツリーの座標系ごと変える**ので、覚えている木は必ず捨てる
        // (古い ref を残すと、次のタップが回転前の座標で撃たれる)
        //
        // **driver.rotate が返るのは「向きが一致した」時点で、レイアウトはまだ動いている
        // ことがある**(実機 iPhone 13 の witness: `RotationSettle.framesFitScreen` の doc)。
        // DSL の rotateTo()(StepExecutor+Actions.swift)と同じ規律で、木が2回続けて指紋一致
        // するまで撮り直す(BackEffect.treesAreIdentical = StaleFrameDetector.treeFingerprint の
        // 等号。2つ目の指紋実装を作らない)。
        // **予算は変化待ちの `changeSettleRereads`(3)×`settleWaitSeconds`(0.4s)=1.2秒を
        // 流用していたが、実機 iPhone では足りなかった**(レイアウトが収まる前に打ち切っていた)。
        // ブリッジ側 POST /rotate の整定ポーリングと同じ締め切り
        // (`FTCore.RotationSettle.deadlineSeconds`)まで、同じ間隔で回す。**cap
        // (`rotationSettleMaxRereads`)が無いと、一度も整定しないドライバでループが止まらない**
        var rotated = try await freshSnapshot(rotateDriver, args: args)
        var settledFrames = false
        let rotationSettlePollInterval = max(RotationSettle.pollIntervalSeconds, settleWaitSeconds)
        let rotationSettleMaxRereads = Int(rotationSettleDeadlineSeconds / rotationSettlePollInterval)
        for _ in 0..<rotationSettleMaxRereads {
            try await Task.sleep(
                nanoseconds: UInt64(max(0, rotationSettlePollInterval) * 1_000_000_000))
            let reread = try await freshSnapshot(rotateDriver, args: args)
            let fits = RotationSettle.framesFitScreen(reread)
            let unchanged = BackEffect.treesAreIdentical(before: rotated.elements,
                                                         after: reread.elements)
            rotated = reread
            if fits, unchanged { settledFrames = true; break }
        }
        recordSnapshot(rotated, rotateDriver is AndroidDriver ? "android" : "ios", args)
        // **portrait へ戻したときだけ auto-rotate を復元する**(Android は rotate(to:) の
        // 初回呼び出しで user_rotation / accelerometer_rotation を控える。landscape のままなら
        // 控えを保つ = 次に portrait へ戻すまで端末の設定はそのまま)。
        // **戻すのは元が auto-rotate だったときだけ**(`restoreAutoRotateIfItWasOn`)—— 元から
        // 横に固定されていた端末で `restoreOrientationIfNeeded` を呼ぶと、明示された portrait を
        // 横へ取り消しながら縦の木を返していた(Pixel 3a・§19 R1)。
        // driver は `drivers[key]` にキャッシュされ同じインスタンスを使い続けるので控えは生きる ——
        // 接続が切れて再生成されたときだけ戻せない(その場合は次に立ち上げた側の責任)。
        //
        // **Android だけに限る**(再現): `restoreOrientationIfNeeded` は
        // ドライバによって意味が違う。Android(AndroidDriver)は OS の auto-rotate 設定を
        // 戻すだけ(表示は portrait のまま動かない)だが、iOS(FTBridgeClient.BridgeClient。
        // in-app / XCUITest 共通)はこのセッションで最初に rotate(to:) を呼ぶ前の向きへ
        // **実際に回転し直す**実装で、明示的に `ft_rotate portrait` した直後に呼ぶと
        // その場で(rotate 前の向きが landscape なら)横へ戻ってしまう ——
        // 利用者が明示した向きを、この経路が黙って取り消していた
        var autoRotateCaveat = ""
        if settled == .portrait, let android = rotateDriver as? AndroidDriver {
            switch try await android.restoreAutoRotateIfItWasOn() {
            case .restored:
                autoRotateCaveat = " Auto-rotate was restored to the device's own setting."
            case .keptExplicitLock:
                autoRotateCaveat = " The device had its orientation locked before this session,"
                    + " so the lock now holds portrait (the earlier lock was not put back —"
                    + " it would have undone this rotation)."
            case .nothingToRestore:
                break
            }
        }
        // **未settleを「もう終わった」と嘘をつかない** —— waitForChange の
        // still-changing 注記と同じ立て付け(MCPServer+Snapshot.swift)
        let relayoutCaveat = settledFrames ? ""
            : " note: the tree did not settle within the check budget — it may still be"
                + " mid-relayout; take another ft_snapshot before relying on these frames."
        return text("Rotated to \(settled.rawValue). The frames below are in the new"
            + " coordinate system — refs taken before the rotation are gone."
            + relayoutCaveat + autoRotateCaveat + "\n\n"
            + (await snapshotBody(rotated, driver: rotateDriver, args: args)))
    }

    func ftNavigate(_ args: [String: Any]) async throws -> [[String: Any]] {
        // **3つを1ツールに束ねる**: back/home/appSwitcher を個別ツールにすると定義が3倍になり、
        // 似た選択肢が並んでエージェントの選択が揺れる(docs/shirates-parity.md の
        // 「別名族を置かない」と同じ判断)
        let target = args["target"] as? String ?? ""
        let navigation = try await driver(args)
        // **back が無効だったかは木の指紋で見る**(home/appSwitcher は対象外)。
        // 覚えている木が無ければチェック自体をしない(照合の起点が無いのに撃つのは
        // 余計な往復を増やすだけ)。指紋は記憶から読むだけなので往復は増えない
        let wantsSnapshotAfter = args["snapshotAfter"] as? Bool == true
        let beforeBackElements = target == "back"
            ? lastSnapshots[Self.engineKey(args)]?.elements : nil
        switch target {
        case "back": try await navigation.back()
        case "home": try await navigation.home()
        case "appSwitcher": try await navigation.openAppSwitcher()
        default: throw MCPError("target must be one of back/home/appSwitcher")
        }
        recordInteraction(action: target, resolvedRef: nil, args: args)
        // **背面へ送ったのはツール自身**という事実だけを覚える(照会に頼らない理由は
        // `backgroundedByNavigate` の doc)。back は画面内で戻るだけのことがあるので数えない
        if target == "home" || target == "appSwitcher" {
            backgroundedByNavigate.insert(Self.engineKey(args))
        }
        // **snapshotAfter を渡されたら木はそちらが撮る**。ここで撮り直すと同じ木を2回
        // 取りに行くだけになるので、**先に本文を組み立ててから**その結果で無効を判定する
        // (`snapshotAfterBody` は adoptSnapshot 経由で `lastSnapshots` を更新するので、
        // 撮った木は指紋で読み返せる)。無効の注記自体は snapshotAfter の有無で消さない ——
        // 木が付いていても「前と同一」は読み手には分からない
        var afterBody = ""
        var snapshotAfterSucceeded = false
        if wantsSnapshotAfter {
            let result = await snapshotAfterBodyWithStatus(args)
            afterBody = result.text
            snapshotAfterSucceeded = result.succeeded
        }
        var backIneffectiveNote = ""
        if let before = beforeBackElements {
            // 判定そのものは FTCore.BackEffect(DSL の back() と共有・2つ目の指紋実装を作らない)。
            // **1回の撮り直しでは判定しない**(ポーリング): アニメーション途中の木を
            // 「変わっていない」と誤読しないため。取得に失敗したら黙って諦める
            // (成功した観測が1つも無ければ「変わっていない」と断言する材料が無い =
            // BackEffect.shouldWarn は observations が空なら false を返す)
            var observations: [[ElementInfo]] = []
            if wantsSnapshotAfter {
                // **撮り直しに成功した回だけ判定する**: snapshotAfterBody が
                // 読みに失敗すると lastSnapshots は back 前の木のまま残り、succeeded を見ずに
                // 読むと指紋が自明に一致して「back は効かなかった」と誤読する(catch した回の
                // 謝罪文の横に、矛盾する偽の注記が並ぶ)
                if snapshotAfterSucceeded, let after = lastSnapshots[Self.engineKey(args)] {
                    observations = [after.elements]
                }
            } else {
                for _ in 0..<BackEffect.pollCount {
                    try? await Task.sleep(for: .seconds(BackEffect.pollIntervalSeconds))
                    guard let after = try? await freshSnapshot(navigation, args: args) else { continue }
                    observations.append(after.elements)
                    if !BackEffect.treesAreIdentical(before: before, after: after.elements) { break }
                }
            }
            if BackEffect.shouldWarn(before: before, afterObservations: observations) {
                backIneffectiveNote = ". note: " + BackEffect.note(advice: BackEffect.mcpAdvice)
            }
        }
        // **「画面が変わった」と断言しない**(2026-08-06 の探索で外した): iOS の back は
        // 端の swipe なので、自前ナビの画面(`#btn_back` を持つ SwiftUI 等)では
        // **何も起きない**。back でアプリ自体を出てしまうこともあり、どちらも
        // 「変わった」と言い切ると誤操作の起点になる
        return text("\(target) sent"
            + Self.changedHint(args, otherwise: ". Take a fresh ft_snapshot to see the result")
            + Self.backNoOpNote(target: target, engine: engines[Self.engineKey(args)])
            + backIneffectiveNote
            + Self.backgroundedAppNote(target: target, engine: engines[Self.engineKey(args)])
            + Self.backgroundingNavigationNote(target: target, engine: engines[Self.engineKey(args)])
            + waitForWithoutSnapshotAfterNote(args) + afterBody)
    }

    func ftDoubleTap(_ args: [String: Any]) async throws -> [[String: Any]] {
        // **座標へ畳んでから撃つ**: ref はブリッジごとに別名前空間で、501 で別ドライバへ
        // 回るときに取り直しが要る(AppDriver.doubleTap が ref を取らない理由と同じ)
        let doubleTapDriver = try await driver(args)
        let doubleTapPoint: (x: Double, y: Double)
        // **答えは渡された形で返す**: ref を渡したのに座標で返すと、tap/press
        // (`[17]` と返す)と食い違って読み手が取り違える(2026-08-07 の棚卸し)
        var doubleTapWhat: String
        var doubleTapNote = ""
        var doubleTapSelector = ""
        var doubleTapResolvedRef: Int?
        if let ref = try Self.intArgument(args, "ref") {
            let (element, labelNote) = try await verifiedElement(ref, driver: doubleTapDriver, args: args)
            doubleTapPoint = (element.frame.centerX, element.frame.centerY)
            doubleTapWhat = "[\(ref)]"
            doubleTapResolvedRef = element.ref
            // **ft_tap と同じ被覆にする**(ft_tap は verifiedRef 経由で遮蔽・残像・
            // 中身外し・キーボード被覆も見ている)。ここだけ見落とすと、同じ要素に対して
            // ツールごとに言うことが変わる(2026-08-08 のレビュー)。
            // keyboardFrame は verifiedElement が撮り直した木(lastSnapshots に反映済み)から
            // 作る(木の chrome で広げ、chrome 自身とその部分木は除外する)
            let doubleTapSnapshot = lastSnapshots[Self.engineKey(args)]
            let doubleTapKeyboard = KeyboardOcclusion.resolve(
                reported: doubleTapSnapshot?.keyboardFrame,
                in: doubleTapSnapshot?.elements ?? [])
            // ref 形は verifiedRef と同じく断る(keyboardRefusal の doc)
            if let refusal = Self.keyboardRefusal(element, keyboardOcclusion: doubleTapKeyboard) {
                throw MCPError(refusal)
            }
            doubleTapNote = RefGuard.preTapWarnings(
                element, keyboardOcclusion: doubleTapKeyboard,
                overlayWindows: OverlayWindowOcclusion.resolve(
                    reported: doubleTapSnapshot?.overlayWindowFrames))
                + RefGuard.overlapWarning(found: element, in: doubleTapSnapshot?
                    .elements ?? [], screen: doubleTapSnapshot?.screen
                    ?? FTRect(x: 0, y: 0, width: 0, height: 0),
                    isAndroid: doubleTapDriver is AndroidDriver) + labelNote
            doubleTapSelector = reproductionNote(resolvedRef: element.ref, args: args)
        } else if let x = try Self.doubleArgument(args, "x"), let y = try Self.doubleArgument(args, "y") {
            if let offscreen = Self.offscreenCoordinateError(
                x: x, y: y, screen: await coordinateScreen(doubleTapDriver, args: args),
                engine: engines[Self.engineKey(args)]) { throw offscreen }
            doubleTapPoint = (x, y)
            doubleTapWhat = "(\(x), \(y))"
            doubleTapNote = keyboardCoordinateWarning(x: x, y: y, args: args)
            doubleTapSelector = once("doubleTapCoordinateNote",
                                     full: Self.doubleTapCoordinateNote,
                                     short: Self.doubleTapCoordinateNoteShort)
        } else {
            throw MCPError("ref or x/y is required")
        }
        try await doubleTapDriver.doubleTap(x: doubleTapPoint.x, y: doubleTapPoint.y)
        recordInteraction(action: "doubleTap", resolvedRef: doubleTapResolvedRef, args: args,
                          coordinate: doubleTapResolvedRef == nil ? doubleTapPoint : nil)
        return text("double tap \(doubleTapWhat) done.\(doubleTapNote)\(doubleTapSelector)"
            + Self.changedHint(args)
            + iosEngineHint("Compose Multiplatform", frameworkKey: .compose, "double tap", args: args)
            + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
    }

    func ftDrag(_ args: [String: Any]) async throws -> [[String: Any]] {
        let dragDriver = try await driver(args)
        // **掴む側を ref で指せる**: 半開きのシートを広げる操作は
        // 「グラバーを上へ引く」だけなのに、座標しか受けないせいで
        // `#Card grabber` の frame を人が読んで手で計算する必要があった(実測)。
        // 終点は「そこまで運ぶ距離」なので dy/dx でも書ける
        var fromPoint: (x: Double, y: Double)?
        // **once() は実際に使う枝でだけ呼ぶ**: fromRef 側で上書きされる既定値として
        // 呼ぶと、座標形を一度も返していないのに「もう説明した」ことになってしまう
        var dragSelector = ""
        if let ref = try Self.intArgument(args, "fromRef") {
            // **撮り直した木の frame を使う**(verifiedElement)。覚えていた frame から
            // 座標を作ると、この修正が防ごうとしている「古い座標を撃つ」に自分で落ちる
            let (element, labelNote) = try await verifiedElement(ref, driver: dragDriver, args: args)
            fromPoint = (element.frame.centerX, element.frame.centerY)
            dragSelector = reproductionNote(resolvedRef: element.ref, args: args) + labelNote
        } else if let x = try Self.doubleArgument(args, "fromX"), let y = try Self.doubleArgument(args, "fromY") {
            // 宛先の無い呼び出しは木を読む前に断る(引数の検査はデバイスに触らない)
            guard args["toX"] != nil || args["toY"] != nil || args["dx"] != nil || args["dy"] != nil else {
                throw MCPError("the drag does not move: pass toX/toY, or dx/dy")
            }
            if let offscreen = Self.offscreenCoordinateError(
                x: x, y: y, screen: await coordinateScreen(dragDriver, args: args),
                engine: engines[Self.engineKey(args)]) { throw offscreen }
            fromPoint = (x, y)
            dragSelector = once("dragCoordinateNote",
                                full: Self.dragCoordinateNote,
                                short: Self.dragCoordinateNoteShort)
        }
        guard let from = fromPoint else {
            throw MCPError("fromRef or fromX/fromY is required")
        }
        // 終点は絶対座標か相対移動のどちらか(相対は「グラバーを 400 上へ」を素直に書ける)
        let toX = try Self.doubleArgument(args, "toX") ?? (from.x + (try Self.doubleArgument(args, "dx") ?? 0))
        let toY = try Self.doubleArgument(args, "toY") ?? (from.y + (try Self.doubleArgument(args, "dy") ?? 0))
        guard toX != from.x || toY != from.y else {
            throw MCPError("the drag does not move: pass toX/toY, or dx/dy")
        }
        let fromX = from.x
        let fromY = from.y
        try await dragDriver.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                  pressSeconds: 0.05,
                                  durationSeconds: try Self.doubleArgument(args, "durationSeconds") ?? 1.5)
        // DSL に drag の対応コマンドが無いので、下書きには TODO 行として残す
        // (座標タップと同じ扱い。黙って消すと探索の再現が途中から辻褄が合わなくなる)
        recordInteraction(action: "drag", resolvedRef: nil, args: args,
                          coordinate: (fromX, fromY))
        // **無検証であることを言う**(swipe / pinch は言っているのに drag / press だけ
        // 「done」で言い切っていた。同じ無検証なのに信頼度が違って見える)
        return text("drag (\(fromX), \(fromY)) → (\(toX), \(toY)) sent.\(dragSelector)"
            + (args["snapshotAfter"] as? Bool == true
               ? " Nothing about the result is checked — read the tree below to confirm"
                 + " it moved what you meant."
               : " Nothing about the result is checked — if it should have moved something,"
                 + " confirm with ft_snapshot/ft_screenshot")
            + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
    }

    func ftPinch(_ args: [String: Any]) async throws -> [[String: Any]] {
        let scale = try Self.doubleArgument(args, "scale") ?? 2.0
        guard scale > 0, scale != 1, scale.isFinite else {
            throw MCPError("scale must be positive and not 1 (>1 zooms in, <1 zooms out)")
        }
        // ref 指定時は frame と identifier の**両方**を渡す(対象の伝え方が経路で違う。
        // Android/in-app は frame の中心・XCUITest は identifier。FTCore/BridgeDTO の PinchRequest)
        let pinchDriver = try await driver(args)
        var frame: FTRect?
        var identifier: String?
        var whole = false
        var pinchSelector = ""
        var pinchResolvedRef: Int?
        var pinchCoordinate: (x: Double, y: Double)?
        if let ref = try Self.intArgument(args, "ref") {
            let (element, labelNote) = try await verifiedElement(ref, driver: pinchDriver, args: args)
            frame = element.frame
            identifier = element.identifier
            pinchResolvedRef = element.ref
            pinchSelector = reproductionNote(resolvedRef: element.ref, args: args) + labelNote
        } else if let x = try Self.doubleArgument(args, "x"), let y = try Self.doubleArgument(args, "y") {
            // **地図・キャンバスには ref が無い**(2026-08-09 実測): Apple マップの場所カードを
            // 半分出したまま ref 無しで撃つと、指が画面全体に開くのでシートが掴まれ、
            // **地図は 1px も動かずシートが全画面に展開した**。逃げ道が無かったので、
            // ft_tap / ft_long_press / ft_drag と同じく座標を受ける
            pinchCoordinate = (x, y)
            let pinchScreen = lastSnapshots[Self.engineKey(args)]?.screen
            var pinchRadius = try Self.doubleArgument(args, "radius")
            // Android は最小スケール距離(27 mm)に届く半径まで既定を広げる(pinchRadiusHonouringMinimumSpan の doc)
            if pinchRadius == nil, let android = pinchDriver as? AndroidDriver,
               let minimumSpan = android.minimumScalingSpanPx() {
                let defaultRadius = pinchScreen.map { min($0.width, $0.height) * Self.pinchRadiusScreenRatio }
                    ?? Self.pinchRadiusFallback
                let widened = Self.pinchRadiusHonouringMinimumSpan(defaultRadius: defaultRadius,
                                                                  minimumSpan: minimumSpan)
                if widened > defaultRadius {
                    pinchRadius = widened
                    pinchSelector += " (radius widened to \(Int(widened)) px so the fingers exceed"
                        + " Android's minimum scaling span of \(Int(minimumSpan)) px — pass radius"
                        + " to override)"
                }
            }
            // **どの経路も領域を受け取れる**(2026-09-22。XCUITest は非公開 API の座標ピンチ
            // `CoordinatePinch` で撃つ)。**使えない Xcode だけ**要素ピンチへ縮退し、
            // そのことはブリッジが注記で返す —— ここで先回りして「無視した」と言わない
            frame = Self.pinchArea(x: x, y: y, radius: pinchRadius, screen: pinchScreen)
        } else if !(pinchDriver is AndroidDriver),
                  let snapshot = lastSnapshots[Self.engineKey(args)] {
            // **直近の木から、両方の指が同じものに載る位置を選ぶ**(画面全体だと指が端に着き、
            // 手前のシートに1本を取られてパンになる。実測と理由は PinchRegion)。
            // **絞れなくても画面矩形は渡す** —— 領域があれば座標で撃てる = DSL / ライブと同じ扱い
            if let area = PinchRegion.area(elements: snapshot.elements, screen: snapshot.screen) {
                frame = area
                pinchSelector += " (no ref/x/y: pinched the middle of the screen,"
                    + " where both fingers stay on the same thing)"
            } else {
                frame = snapshot.screen
                whole = true
            }
        } else {
            whole = true
        }
        let pinchDuration = try Self.doubleArgument(args, "durationSeconds") ?? 0.5
        try await pinchDriver.pinch(frame: frame, identifier: identifier, scale: scale,
                                    durationSeconds: pinchDuration)
        // 記録は DSL の語彙(pinchOut/pinchIn)で。既定の 0.5s は落とす(codegen が省くため)
        recordInteraction(action: scale > 1 ? "pinchOut" : "pinchIn",
                          resolvedRef: pinchResolvedRef, args: args,
                          coordinate: pinchCoordinate,
                          duration: pinchDuration == 0.5 ? nil : pinchDuration,
                          maxGestureSeconds: try Self.doubleArgument(args, "maxGestureSeconds"), scale: scale)
        return text("pinch x\(scale) done.\(pinchSelector)"
            // **「小さくなる」とだけ言わない**(2026-08-06 実測): 指が対象の内側に収まる分だけ
            // 小さくなることもあれば、慣性で大きくもなる(scale 2.0 の要求で累積 3.9 倍)
            + " The actual zoom can differ from what you asked for in either direction"
            + " — verify with ft_snapshot/ft_screenshot."
            + (whole ? " The fingers spanned the whole screen, so anything on top of the area"
                + " you meant (a bottom sheet, a card) may have taken the gesture instead —"
                + " pass x/y to pinch a specific spot." : "")
            // **同じ逃げ道を2度書かない**(2026-08-08 に長文の苦情があった箇所)。
            // 領域が無視されたときの文は engine も remedy も言い切っているので、
            // 汎用の Flutter 助言はそこでは畳む
            + iosEngineHint("Flutter", frameworkKey: .flutter, "pinch", args: args)
            + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
    }

    func ftGesture(_ args: [String: Any]) async throws -> [[String: Any]] {
        // JSON の形だけの検査はドライバ取得より前に(ft_long_press と同じ理由 —
        // コールドスタートは分単位かかりうるので、引数だけで弾けるものは先に弾く)。
        // 秒数の妥当性・点の積み上げは resolve(下)へ委ねる(重複させない)
        let gestureFingers = try Self.gestureFingersArgument(args)
        let gestureDriver = try await driver(args)
        // 画面内かどうかの判定に screen が要る。既に撮った木があれば読みを増やさない
        // (coordinateScreen の doc)
        guard let gestureScreen = await coordinateScreen(gestureDriver, args: args) else {
            throw MCPError("could not read the screen size to check the gesture stays on it —"
                + " take a ft_snapshot first")
        }
        let gestureCap = try Self.doubleArgument(args, "maxGestureSeconds")
            ?? BridgeAPI.defaultMaxGestureSeconds
        // parse → resolve は一度だけ。unit rect(幅1・高さ1)を target にすると
        // TouchGesture.resolve の比率写像が恒等写像になり、絶対座標をそのまま検査に通せる
        let validatedGesture: GestureRequest
        switch TouchGesture.resolve(gestureFingers, in: FTRect(x: 0, y: 0, width: 1, height: 1),
                                    screen: gestureScreen, maxGestureSeconds: gestureCap) {
        case .failure(let rejection): throw MCPError(rejection.message)
        case .success(let ok): validatedGesture = ok
        }
        try await gestureDriver.gesture(validatedGesture)
        // **座標(絶対)→ 比率へ割り戻して記録する**(DSL の gesture は FTFinger の比率で書く。
        // FlowStep.gesture がその置き場)。対象は常に画面全体(ft_gesture にセレクタは無い)ので
        // locator は付けない
        var gestureDraftStep = FlowStep(action: "gesture")
        gestureDraftStep.gesture = Self.gestureFingersRatio(gestureFingers, screen: gestureScreen)
        gestureDraftStep.maxGestureSeconds = try Self.doubleArgument(args, "maxGestureSeconds")
        recordAction(InteractionLog.Entry(
            step: gestureDraftStep, unresolved: nil,
            summary: "gesture (\(validatedGesture.fingers.count) finger(s))"), args: args)
        let fingerWord = validatedGesture.fingers.count == 1 ? "finger" : "fingers"
        return text("gesture sent (\(validatedGesture.fingers.count) \(fingerWord),"
            + " \(FTSeconds.format((validatedGesture.totalSeconds * 100).rounded() / 100))s)."
            + " Nothing about the result is checked — if it should have moved something,"
            + " confirm with ft_snapshot/ft_screenshot."
            + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
    }

    func ftLongPress(_ args: [String: Any]) async throws -> [[String: Any]] {
        // 引数名は DSL の tap(holdSeconds:) と同語彙(2026-08-10 の語彙統一)。
        // 旧名は黙って既定値に落とさない(1.0s の長押しに化けて沈黙した誤りになる)。
        // **引数だけで弾ける検証はドライバ取得より前に**(コールドスタートは分単位かかりうる)
        guard args["duration"] == nil else {
            throw MCPError("duration was renamed to holdSeconds (same vocabulary as the"
                + " DSL's tap(holdSeconds:)) — pass holdSeconds instead")
        }
        let pressDriver = try await driver(args)
        let pressDuration = try Self.doubleArgument(args, "holdSeconds") ?? 1.0
        let pressCap = try Self.doubleArgument(args, "maxGestureSeconds")
        if let ref = try Self.intArgument(args, "ref") {
            let pressTarget = try await verifiedRef(ref, driver: pressDriver, args: args)
            // pressTarget.ref はセッション ref。ブリッジへ渡す直前にだけ native へ戻す
            try await pressDriver.press(ref: nativeRef(pressTarget.ref, args: args),
                                        duration: pressDuration)
            recordInteraction(action: "press", resolvedRef: pressTarget.ref, args: args,
                              duration: pressDuration,
                              maxGestureSeconds: pressCap)
            return text("press [\(ref)] done.\(pressTarget.note)"
                + reproductionNote(resolvedRef: pressTarget.ref, args: args)
                + Self.changedHint(args)
                + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
        }
        // **座標形は ft_tap と揃える**: ドライバは press(x:y:duration:) を要件として持つのに
        // MCP からは ref でしか呼べなかった。地図・キャンバスのように a11y 要素が無い点を
        // 長押しする操作(ピンを落とす・住所を出す)が一切書けない状態だった
        if let x = try Self.doubleArgument(args, "x"), let y = try Self.doubleArgument(args, "y") {
            if let offscreen = Self.offscreenCoordinateError(
                x: x, y: y, screen: await coordinateScreen(pressDriver, args: args),
                engine: engines[Self.engineKey(args)]) { throw offscreen }
            try await pressDriver.press(x: x, y: y, duration: pressDuration)
            recordInteraction(action: "press", resolvedRef: nil, args: args, coordinate: (x, y),
                              duration: pressDuration,
                              maxGestureSeconds: pressCap)
            return text("press (\(x), \(y)) done." + keyboardCoordinateWarning(x: x, y: y, args: args)
                + once("coordinateHoldReproductionNote",
                full: Self.coordinateHoldReproductionNote(
                    holdSeconds: pressDuration, maxGestureSeconds: pressCap),
                short: Self.coordinateHoldReproductionNoteShort(
                    holdSeconds: pressDuration, maxGestureSeconds: pressCap))
                + Self.changedHint(args)
                + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
        }
        throw MCPError("ref or x/y is required")
    }
}
