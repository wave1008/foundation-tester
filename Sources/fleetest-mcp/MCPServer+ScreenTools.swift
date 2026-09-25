// MCPServer+ScreenTools.swift
// 画面の観測と要素への入力系ツール(snapshot / tap / type / clear_input / screenshot / capture_element)。入口の振り分けは MCPServer+Dispatch.swift の dispatch

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    func ftSnapshot(_ args: [String: Any]) async throws -> [[String: Any]] {
        // **明示分だけ・丸ごと置き換え**(snapshotAfterBody が読む記憶)。省略したキーは
        // ここで記憶から消える — 次の snapshotAfter は「今の申告」だけを見て継承の可否を決める
        var explicitFilters: [String: Bool] = [:]
        if let v = args["interactiveOnly"] as? Bool { explicitFilters["interactiveOnly"] = v }
        if let v = args["expandBulk"] as? Bool { explicitFilters["expandBulk"] = v }
        rememberedSnapshotFilters[Self.engineKey(args)] = explicitFilters
        let snapshotDriver = try await driver(args)
        var snapshot: SnapshotResponse
        do {
            snapshot = try await freshSnapshot(snapshotDriver, args: args)
        } catch {
            // ホーム画面/システム UI を読もうとして詰まった形なら、読む方法まで返す
            let hint = Self.springboardHint(error, engine: engines[Self.engineKey(args)])
            guard !hint.isEmpty else { throw error }
            throw MCPError(error.localizedDescription + hint)
        }
        var waitNote = ""
        // **待つのはホスト側の仕事**: エージェントに snapshot を撃ち直させると、待った
        // 回数だけ画面一覧が文脈に積まれる(1回あたり数千トークン)
        if let waitFor = args["waitFor"] as? String {
            let seconds = try Self.doubleArgument(args, "waitSeconds") ?? Self.defaultWaitSeconds
            let waited = try await Self.waitFor(waitFor, driver: snapshotDriver,
                                                first: snapshot, seconds: seconds,
                                                elementLimit: try pollElementLimit(args))
            // **撃ち直しが起きたときだけ adoptSnapshot を通す**: 撃ち直しが無ければ
            // `waited.snapshot` は `snapshot`(既にセッション ref)そのものなので、
            // native 前提の adoptSnapshot に通すと同じ木を「別世代」と誤認する
            // (base 込みの ref を native ref と取り違えて比較するため)
            snapshot = waited.refetched ? adoptSnapshot(waited.snapshot, args: args) : waited.snapshot
            if !waited.found {
                waitNote = "waitFor \"\(waitFor)\" did not appear within"
                    + " \(Self.secondsText(seconds))\(Self.waitTimeoutRemedy)"
                    + " — this is the screen as it is now\(Self.truncationHint(snapshot))"
                    + (waited.partialSeenAfter.map { seenAfter in
                        // **完全一致でなく部分一致が先に出た形を名指しする**: 満額待った理由
                        // (早期打ち切りはしない)まで書かないと、待った時間が無駄に見える
                        " — a partial match was already on screen \(Int(seenAfter.rounded()))s"
                            + " into the wait:\(waited.partialHint) The exact form never"
                            + " appeared, so the wait ran to the deadline"
                    // **記法の助言はここにも要る**: 切り詰めラベルをそのまま渡した waitFor は
                    // 外れるのに、返す木には**同じ文字列が印字されている**ので照合のバグに見える
                    // (実測)。scrollTo だけに出していて届いていなかった
                    } ?? (Self.notationHint(waitFor, in: snapshot)
                          // **部分一致が出ていたときは出さない**: そちらのほうが具体的な
                          // ヒントなので、的の外れた推測を並べて紛らわせない
                          + Self.similarLabelsHint(waitFor, in: snapshot)))
                    + Self.waitForScrollHint(in: snapshot) + "\n"
            }
        }
        // **プラットフォームはドライバの実体から採る**(profile 指定時は args["platform"] が
        // 空でもプロファイル側で解決済みなので、args を見ると取り違える)
        recordSnapshot(snapshot, snapshotDriver is AndroidDriver ? "android" : "ios", args)
        return text(withPendingWarnings(
            await snapshotBody(snapshot, driver: snapshotDriver, args: args,
                               extraNote: waitNote),
            args: args))
    }

    func ftTap(_ args: [String: Any]) async throws -> [[String: Any]] {
        let d = try await driver(args)
        if let ref = try Self.intArgument(args, "ref") {
            let target = try await verifiedRef(ref, driver: d, args: args)
            // **target.ref はセッション ref**。ブリッジは native の番号しか知らないので、
            // 撃つ直前にだけ nativeRef で戻す(応答・記録には引き続きセッション ref を使う)
            try await d.tap(ref: nativeRef(target.ref, args: args))
            recordInteraction(action: "tap", resolvedRef: target.ref, args: args)
            // 次の ref なし ft_type の救済材料(verifiedRef が撮り直した木から引く)
            lastTapTargets[Self.engineKey(args)] = lastSnapshots[Self.engineKey(args)]?
                .elements.first { $0.ref == target.ref }
            return text("tap [\(ref)] done.\(target.note)"
                // ブリッジの /tap が返す note(例:
                // 「activate 不発 → 合成タッチ」— BridgeClient.tap(ref:) の lastActionNote)を
                // 捨てない。DSL は同じ note を StepExecutor+Actions.swift の driverFallback へ
                // 載せるので、MCP だけがこれを黙って捨てて撃った実体を見せていなかった
                + Self.driverFallbackNote(d)
                + reproductionNote(resolvedRef: target.ref, args: args)
                + Self.changedHint(args) + waitForWithoutSnapshotAfterNote(args)
                + (await snapshotAfterBody(args)))
        }
        if let x = try Self.doubleArgument(args, "x"), let y = try Self.doubleArgument(args, "y") {
            if let offscreen = Self.offscreenCoordinateError(
                x: x, y: y, screen: await coordinateScreen(d, args: args),
                engine: engines[Self.engineKey(args)]) { throw offscreen }
            try await d.tap(x: x, y: y)
            recordInteraction(action: "tap", resolvedRef: nil, args: args, coordinate: (x, y))
            lastTapTargets[Self.engineKey(args)] = nil
            return text("tap (\(x), \(y)) done" + keyboardCoordinateWarning(x: x, y: y, args: args)
                + once("coordinateReproductionNote",
                full: Self.coordinateReproductionNote,
                short: Self.coordinateReproductionNoteShort)
                + waitForWithoutSnapshotAfterNote(args)
                + (await snapshotAfterBody(args)))
        }
        throw MCPError("ref or x/y is required")
    }

    func ftType(_ args: [String: Any]) async throws -> [[String: Any]] {
        // **Enter は別ツールにしない**が、**入力を伴わない pressEnter も要る**:
        // iOS はソフトキーボードを閉じる手段が pressEnter しかない(hideKeyboard は Android 専用。
        // docs/commands.md)。そのため text は「pressEnter だけを撃つとき」は省略できる
        let wantsEnter = args["pressEnter"] as? Bool == true
        let content = args["text"] as? String
        let wantsReplace = args["replace"] as? Bool == true
        guard content != nil || wantsEnter else {
            throw MCPError("text is required (or pass pressEnter: true to fire Enter only)")
        }
        let typeDriver = try await driver(args)
        var targetRef = try Self.intArgument(args, "ref")
        var note = ""
        // **type は追記**(docs/commands.md)。既に入っている欄へ撃つと連結された文字列になり、
        // 戻り値が `Typed: "東京タワー"` だけだと気づけない —— 検索欄なら検索自体は成立するので
        // **沈黙した誤りになる**(Google マップで `レストラン東京タワー` を実測)。
        // 撃つ前の値は verifiedRef が撮り直した木から引く(追加の snapshot を払わない)
        var priorValue: String?
        var priorElement: ElementInfo?
        if let ref = targetRef {
            let verified = try await verifiedRef(ref, driver: typeDriver, args: args)
            targetRef = verified.ref
            note = verified.note
            priorElement = lastSnapshots[Self.engineKey(args)]?
                .elements.first { $0.ref == verified.ref }
            // **「入っている値」の判定は DSL と同じ**。素の `value` を見ていたので、
            // `placeholder` と同値の空欄(iOS 全般 / Android の CMP)でも MCP だけが
            // 追記警告を出していた —— StepExecutor は normalizedValue で黙る側
            priorValue = priorElement.map(TypeReadback.normalizedValue)
            // **入力欄でないものへ打とうとしていないか**。判定は DSL と共有
            // (TapTargetGeometry.nonInputTypeTargetNote。実測と理由はそちらの doc)。
            // MCP は StepExecutor を経由しない別経路なので、ここにも配線が要る。
            //
            // 容器(内側に入力欄がちょうど1つ)は警告して
            // 撃つ(nonInputTypeTargetNote が non-nil)。**そうでない非入力欄(入力欄が0個・
            // 2個以上)は撃つ前に拒否する** —— 警告のまま撃つと、送信ボタンを押してしまった
            // 後で読み返しが失敗し(「検索窓が本物の入力欄へ焦点を渡す形かも」という誤誘導)、
            // in-app エンジンでは焦点のある**別の**欄へ入って黙って成功扱いになる。
            // 対象そのものが分かっているのだから、ここで一度に断る
            if let priorElement, let elements = lastSnapshots[Self.engineKey(args)]?.elements {
                if let warn = TapTargetGeometry.nonInputTypeTargetNote(priorElement, in: elements) {
                    note = note.isEmpty ? " (warning: \(warn))"
                        : note + " (warning: \(warn))"
                } else if !TypeReadback.isTextInput(priorElement) {
                    throw MCPError(Self.notATextFieldRefusal(priorElement, ref: verified.ref))
                }
            }
        }
        // **replace は文字が空でも clear する**: {replace:true, text:""} や
        // {replace:true, pressEnter:true} は「クリアだけ」「クリア+Enter」を成立させるための
        // 書き方で、スキーマも "Clear the field before typing" と約束している。下の入力分岐
        // (文字が非空のときだけ通る)の内側に置くと、空文字はそこへ一度も入らず黙って
        // 何もしない(スキーマの約束を破る)
        if wantsReplace {
            try await typeDriver.clearInput(ref: targetRef.map { nativeRef($0, args: args) })
        }
        // **replace + snapshotAfter(Enter を伴わない形)は同じ木を2回読まない**:
        // この組み合わせでは検証が読みたい瞬間(clear/type 直後)と snapshotAfter が読みたい
        // 瞬間が同じなので、snapshotAfterBodyWithStatus を先に1回だけ実行し、成功していれば
        // その木(lastSnapshots)を検証にも使う。失敗時だけ生読みへフォールバックする。
        // **pressEnter を伴う形は対象外**: Enter の前後で状態が変わるので、検証は Enter 前に
        // 読む必要があり(下の呼び出し位置のまま)、最終的に返す木は Enter 後でなければならない
        // —— そもそも2回読む理由がある(この最適化を適用すると Enter 前の古い木を返す)
        // 追記(replace なし)も読み返して確かめるので、同じ merge の対象にする。
        // これが無いと `snapshotAfter: true` の呼び方で**同じ木を2回読む**
        let verifiesAppend = !wantsReplace && !(priorValue ?? "").isEmpty
            && !(content ?? "").isEmpty
        let mergesSnapshotAfterIntoVerification =
            (wantsReplace || verifiesAppend) && !wantsEnter
            && args["snapshotAfter"] as? Bool == true
        var precomputedAfterBody: String?
        func verificationSnapshot() async -> SnapshotResponse? {
            guard mergesSnapshotAfterIntoVerification else {
                return try? await typeDriver.snapshot(bypassingCache: typeDriver.supportsCacheBypass)
            }
            let result = await snapshotAfterBodyWithStatus(args)
            precomputedAfterBody = result.text
            guard result.succeeded else {
                return try? await typeDriver.snapshot(bypassingCache: typeDriver.supportsCacheBypass)
            }
            return lastSnapshots[Self.engineKey(args)]
        }
        if let content, !content.isEmpty {
            // **`ft_tap(容器)` → ref なし `ft_type` を成立させる**(DSL の `retypeTargetIfUnfocused` と
            // 同じ規律・判定は `InputFocusRescue` を共有)。Android は容器を叩いても前の欄の焦点を
            // 外さないので、ref なし type は**前の欄へ入って「Typed」とだけ返していた**
            // (Pixel 3a・§19 F13 の MCP 版)。払うのは tap の直後の1枚だけ。
            // **生読み**(adoptSnapshot を通さない)= 返る ref は native なのでそのまま撃てる。
            // 入れ先が一意に決まらなければ焦点の欄へ送るが、**焦点が叩いた欄の外に
            // あることは警告に出す**(typedIntoNote の「どこへ入ったか」と対で読める)
            var rescuedNativeRef: Int?
            if targetRef == nil, !content.contains("\n"),
               let tapped = lastTapTargets[Self.engineKey(args)],
               let fresh = try? await typeDriver.snapshot(bypassingCache: typeDriver.supportsCacheBypass),
               InputFocusRescue.focusIsElsewhere(from: tapped, in: fresh.elements) {
                let focusedName = fresh.elements.first { $0.focused == true }.map(RefGuard.describe)
                if let field = InputFocusRescue.fieldToType(after: tapped, in: fresh.elements) {
                    rescuedNativeRef = field.ref
                    note += " (tapping \(RefGuard.describe(tapped)) left input focus"
                        + (focusedName.map { " on \($0)" } ?? " nowhere")
                        + ", so the text was sent to the input field inside it,"
                        + " \(RefGuard.describe(field)))"
                } else {
                    note += " (warning: tapping \(RefGuard.describe(tapped)) left input focus"
                        + (focusedName.map { " on \($0)" } ?? " nowhere")
                        + ", and no single input field inside the tapped element could be chosen"
                        + " — the text went to whichever field has focus; pass the field's ref)"
                }
            }
            // targetRef はセッション ref。ブリッジへ渡す直前にだけ native へ戻す
            let resolvedTypeRef = rescuedNativeRef ?? targetRef.map { nativeRef($0, args: args) }
            do {
                try await typeDriver.type(ref: resolvedTypeRef, text: content)
                // XCUITest ランナーが打ち直した事実(OKResponse.note)を返答に載せる
                note += Self.driverFallbackNote(typeDriver)
            } catch {
                // **ref なしで撃った失敗だけ**、前面の SpringBoard アラートを名指しする
                // 一発物の照会を添える(SystemUIGate の申告は木に載らないので、素の失敗は
                // 「焦点が無い」としか言えず、原因がアラートだと気づけないまま撃ち直しがちになる)。
                // target が無い形なので systemAlertGate(要素前提)ではなく frontSystemAlert を使う
                if resolvedTypeRef == nil, let alert = await Self.frontSystemAlert(driver: typeDriver) {
                    throw MCPError(error.localizedDescription + " — \(alert) is in front of the"
                        + " app, which likely explains the missing focus. Handle it first with"
                        + " `ft_launch bundleId: com.apple.springboard`, tap its button by ref,"
                        + " then `ft_launch` your app again.")
                }
                throw error
            }
            // **ref を渡したときだけ読み返しで検証される**。iOS の XCUITest ランナーは
            // ref から対象を引けたときだけ TypeReadback の resend/deleteExcess を回し、
            // 引けない(= ref なし)ときは無検証の `typeText` へ落ちて OK を返す。
            // Android は焦点ノードを読み返すので ref なしでも検証される。
            // **replace のときはここでは読み返さない** —— 下の replaceVerificationNote が
            // 同じ理由(生読み・settle-lite 基準を壊さない)で改めて読むので、二重に払わない
            if targetRef == nil, !wantsReplace {
                // **注意書きで済ませず、ここで確かめる**: iOS の XCUITest ランナーは ref から
                // 対象を引けたときだけ TypeReadback を回すので、ref なしは無検証で OK が返る。
                // 木は `focused` を持っているのだから、撮り直して**どこへ入ったか**を名指しできる。
                // **Android も払う**(焦点ノードの読み返しだけでは「焦点のある欄に入った」しか
                // 言えず、**それが別の欄だった**ことを言えない = F13)。
                // **生読み(adoptSnapshot を通さない)**: この読みは入力という操作の**後**に
                // 撮っているので、freshSnapshot 経由だと lastSnapshots[key] を上書きし、
                // 続く snapshotAfterBody の settle-lite 基準(操作前の木のつもり)が
                // 操作後の木になってしまい「変化なし」と誤報する
                let rawAfterType = try? await typeDriver.snapshot(
                    bypassingCache: typeDriver.supportsCacheBypass)
                note += await Self.typedIntoNote(driver: typeDriver, expected: content,
                                                 snapshot: rawAfterType)
            }
            if wantsReplace {
                // **無条件の「replaced」を断言しない**: clearInput → type の後、
                // 読み返しなしで無条件に付けていた。in-app iOS の UIKit 経路は検証なしで YES を
                // 返すので、clear が効いていなくても(旧値の後ろに新しい文字が連結されても)
                // 「replaced」と嘘をつく。読み返して期待どおり/マスクで検証不能/旧値残存/
                // 読めないの4形に分ける(replaceVerificationNote)
                note += Self.replaceVerificationNote(
                    target: priorElement, expected: content, fresh: await verificationSnapshot())
            } else if let prior = priorValue, !prior.isEmpty {
                // **予告ではなく観測**(appendVerificationNote の doc に witness)
                note += Self.appendVerificationNote(target: priorElement, typed: content,
                                                    prior: prior,
                                                    fresh: await verificationSnapshot())
            }
        } else {
            // **clear-only({replace:true, text:"" or 省略})も無条件に「cleared」と断言しない**
            //: 読み返して期待どおり(空)/マスク/残存の3形に分ける
            // (replaceVerificationNote は expected 空でこの3形を返す)
            if wantsReplace {
                note += Self.replaceVerificationNote(
                    target: priorElement, expected: "", fresh: await verificationSnapshot())
            }
            if let ref = targetRef {
                // 入力せず Enter だけ撃つときも、対象が指定されていればフォーカスを立ててから。
                // **タップの直後に撃たない**(下の awaitFocus): 直前に別の欄へ入力していると
                // フォーカスの移動が間に合わず、Enter が**前の欄**へ飛んで黙って何も起きない
                // (Android で観測。ime カウンタが増えなかった)
                try await typeDriver.tap(ref: nativeRef(ref, args: args))
                note += await awaitFocus(ref: ref, driver: typeDriver, args: args)
            }
        }
        // 入力欄も**セレクタで再現できないと書けない**(E)。ref を渡さない
        // (フォーカス任せの)呼び方では対象が確定しないので黙る
        let typedSelector = targetRef.map { reproductionNote(resolvedRef: $0, args: args) } ?? ""
        if let content, !content.isEmpty {
            recordInteraction(action: "type", resolvedRef: targetRef, args: args, text: content,
                              replace: wantsReplace)
        }
        if wantsEnter { recordInteraction(action: "pressEnter", resolvedRef: nil, args: args) }
        guard wantsEnter else {
            let afterBody: String
            if let precomputedAfterBody {
                afterBody = precomputedAfterBody
            } else {
                afterBody = await snapshotAfterBody(args)
            }
            return text("Typed: \"\(content ?? "")\"\(note)\(typedSelector)"
                + waitForWithoutSnapshotAfterNote(args)
                + afterBody)
        }
        try await typeDriver.pressEnter()
        return text((content.map { "Typed: \"\($0)\" and pressed Enter" } ?? "Pressed Enter")
            + note + typedSelector + waitForWithoutSnapshotAfterNote(args)
            + (await snapshotAfterBody(args)))
    }

    func ftClearInput(_ args: [String: Any]) async throws -> [[String: Any]] {
        // ref 省略 = フォーカス中の欄(DSL の clearInput() と同じ)
        let clearDriver = try await driver(args)
        var clearRef = try Self.intArgument(args, "ref")
        var clearNote = ""
        var clearTarget: ElementInfo?
        if let ref = clearRef {
            let verified = try await verifiedRef(ref, driver: clearDriver, args: args)
            clearRef = verified.ref
            clearNote = verified.note
            clearTarget = lastSnapshots[Self.engineKey(args)]?
                .elements.first { $0.ref == verified.ref }
            // ft_type と同じ門(そちらの doc 参照)。容器(内側に入力欄がちょうど1つ)は
            // 警告のうえで撃つが、それ以外の非入力欄は撃つ前に拒否する
            if let clearTarget, let elements = lastSnapshots[Self.engineKey(args)]?.elements {
                if let warn = TapTargetGeometry.nonInputTypeTargetNote(clearTarget, in: elements) {
                    clearNote += " (warning: \(warn))"
                } else if !TypeReadback.isTextInput(clearTarget) {
                    throw MCPError(Self.notATextFieldRefusal(clearTarget, ref: verified.ref))
                }
            }
        }
        // clearRef はセッション ref。ブリッジへ渡す直前にだけ native へ戻す
        do {
            try await clearDriver.clearInput(ref: clearRef.map { nativeRef($0, args: args) })
        } catch {
            // ref 指定の失敗はランナーが既にタップを撃った後(焦点待ちの 422 等)——
            // 記録せずに投げると、次の ft_type/ft_snapshot が「このセッションの誰も
            // 変えていないのに木が変わった」と外部要因のせいにする(M5b実測)
            if clearRef != nil { recordInteraction(action: "clearInput", resolvedRef: clearRef, args: args) }
            throw error
        }
        recordInteraction(action: "clearInput", resolvedRef: clearRef, args: args)
        // **無条件の「cleared」を断言しない**(ft_type replace / 追記と同じ型の掃討)——
        // in-app iOS の UIKit 経路は clearInput の成否を検証なしで YES を返すので、値が残っていても
        // 「消した」と言ってしまう。呼び手はこの後 ft_type を撃つので、**残っていると黙って連結される**。
        // 判定は replace の clear-only 検証と同じ関数(空を期待して読み返す)
        // 文言は「clear」——このツールは一度も replace を頼んでいない
        // **snapshotAfter の1枚を読み返しにも使う**(ft_type の replace と同じ = 同じ瞬間の木を2回読まない)。
        // snapshotAfter の読みが失敗したときだけ生読みへ落ちる
        var afterBody = ""
        var verification: SnapshotResponse?
        if args["snapshotAfter"] as? Bool == true {
            let result = await snapshotAfterBodyWithStatus(args)
            afterBody = result.text
            if result.succeeded { verification = lastSnapshots[Self.engineKey(args)] }
        }
        if verification == nil {
            verification = try? await clearDriver.snapshot(bypassingCache: clearDriver.supportsCacheBypass)
        }
        let clearedVerdict = Self.replaceVerificationNote(
            target: clearTarget, expected: "", fresh: verification, requestedAs: "clear")
        return text("clearInput sent\(clearNote)\(clearedVerdict)"
            + (clearRef.map { reproductionNote(resolvedRef: $0, args: args) } ?? "")
            + waitForWithoutSnapshotAfterNote(args) + afterBody)
    }

    func ftScreenshot(_ args: [String: Any]) async throws -> [[String: Any]] {
        let screenshotDriver = try await driver(args)
        // 鮮度判定は StaleFrameDetector.judge(FTCore。DSL の occlusion-guard と共有・
        // 契約はそちらのコメント参照)。撮影前の snapshot は取らない
        // (往復は screenshot 1回 + snapshot 1回の計2回)。
        // **限界**: 木の変化が画素に出ない変化(a11y のみ)は誤検知になり得るが、指紋は
        // type/id/label/frame なので実害は薄い
        let png = try await screenshotDriver.screenshot()
        var staleNote: [[String: Any]] = []
        // 木の取得に失敗したら判定せず、記録も汚さない(前回の記録を残す)
        if let after = try? await freshSnapshot(screenshotDriver, args: args) {
            let key = Self.engineKey(args)
            let (record, isStale) = StaleFrameDetector.judge(
                png: png, elements: after.elements, previous: lastScreenshots[key])
            if isStale {
                staleNote = [["type": "text", "text":
                    "note: the element tree has changed since the previous ft_screenshot, but"
                    + " this image is byte-identical to that previous one — the frame is likely"
                    + " STALE (a frozen display can keep serving an old frame). Do not read"
                    + " results off this image; trust ft_snapshot, and re-take the screenshot"
                    + " after interacting with the screen."]]
            }
            lastScreenshots[key] = record
        }
        guard (args["fullSize"] as? Bool) != true else {
            return staleNote
                + [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]
        }
        // 縮小できないとき(壊れた PNG・ImageIO 失敗)は絵を返さないより原寸のほうがまし
        guard let scaled = ImageDownscale.jpeg(
            png: png,
            maxWidth: try Self.intArgument(args, "maxWidth") ?? Self.screenshotMaxWidth,
            quality: try Self.doubleArgument(args, "quality") ?? Self.screenshotQuality) else {
            return staleNote
                + [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]
        }
        return staleNote + [["type": "image", "data": scaled.data.base64EncodedString(),
                              "mimeType": "image/jpeg"]]
    }

    func ftCaptureElement(_ args: [String: Any]) async throws -> [[String: Any]] {
        // 中核(ラベル検査・保存と重複時の巻き戻し・点検)は VisionSample を CLI と共有する
        let classifier = try Self.requiredStringArgument(args, "classifier")
        let label = try Self.requiredStringArgument(args, "label")
        if let issue = VisionSample.labelIssue(classifier: classifier, label: label) { throw MCPError(issue) }
        let project = try ScenarioHost.project(named: args["project"] as? String)
        let d = try await driver(args)
        let element: ElementInfo
        let screen: FTRect
        var refNote = ""
        if let ref = try Self.intArgument(args, "ref") {
            let target = try await verifiedRef(ref, driver: d, args: args)
            guard let snapshot = lastSnapshots[Self.engineKey(args)],
                  let found = snapshot.elements.first(where: { $0.ref == target.ref }) else {
                throw MCPError("[\(ref)] is not on the current screen. Take a fresh ft_snapshot")
            }
            element = found
            screen = snapshot.screen
            refNote = target.note
        } else if let selector = args["selector"] as? String {
            let snapshot = try await freshSnapshot(d, args: args)
            let parsed = FTSelector.parse(selector)
            let step = FlowStep(assert: "exists", locator: parsed.primary,
                                fallbacks: parsed.fallbacks.isEmpty ? nil : parsed.fallbacks)
            guard let (found, _) = StepExecutor.resolve(step: step, in: snapshot, strictForAssert: true) else {
                throw MCPError("no element matches \(selector) on the current screen")
            }
            element = found
            screen = snapshot.screen
        } else {
            throw MCPError("ref or selector is required")
        }
        let png = try await d.screenshot()
        guard let image = VisionClassifier.crop(png: png, frame: element.frame, screen: screen) else {
            throw MCPError("could not crop the element from the screenshot (is it inside the screen?)")
        }
        let captureName = try Self.stringArgument(args, "name")
        let file: URL
        do {
            file = try VisionSample.save(image, projectRoot: project.rootURL, classifier: classifier,
                                         label: label, name: captureName)
        } catch {
            throw MCPError(ErrorText.user(error))
        }
        let report = await VisionSample.report(projectRoot: project.rootURL, classifier: classifier)
        return text("saved \(image.width)x\(image.height) px of \(RefGuard.describe(element)) to \(file.path)."
            + refNote + "\n" + report.lines.joined(separator: "\n"))
    }
}
