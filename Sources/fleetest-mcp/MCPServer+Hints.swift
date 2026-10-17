// MCPServer+Hints.swift
// 木に添える注記・ヒント(sheet・ghost・スクロール・類似ラベル・切り詰め・pinch・focus・座標等)。WebView・グリッドは MCPServer+WebViewHints.swift、曖昧ラベル・重複 id は MCPServer+LabelHints.swift。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import Synchronization
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    /// 半開きシートのグラバー。**名前で特定できるときだけ**返す(当てずっぽうのドラッグは
    /// 地図やリストを勝手に動かすので、確信が無いなら何もしないほうが良い)。
    /// UIKit/SwiftUI のシートは `Card grabber` のような id/ラベルを出す(実測: Apple マップ)。
    ///
    /// 下半分に居るものだけを対象にする —— 既に上まで開いているグラバーを更に引いても
    /// 広がらず、実装によっては閉じる
    static func sheetGrabber(in snapshot: SnapshotResponse) -> ElementInfo? {
        snapshot.elements.first { element in
            let name = ((element.identifier ?? "") + " " + (element.label ?? "")).lowercased()
            guard name.contains("grabber") else { return false }
            return element.frame.centerY > snapshot.screen.height * 0.3
        }
    }

    /// 救済(半開きシートを広げての再試行)がレイアウトを変えた可能性を伝える。
    /// **検出できるものは名指しする**: 救済前に横ページャ(`pageIndicator`)があり救済後に
    /// 消えていれば、`direction` がもうページ送りの意味を持たないことまで言う
    /// (実測: Apple マップの経路一覧が横ページャ→縦リストに化けた回。直前の
    /// ft_snapshot の「direction: right で届く」という案内と実際の結果が食い違っていた)。
    /// 消えていない/両方に無いときは汎用の一文のみ(それ以上の推測はしない=誤検知回避)
    static func sheetExpansionLayoutNote(before: SnapshotResponse, after: SnapshotResponse) -> String {
        let generic = " Expanding the sheet may have changed the layout."
        let hadPager = before.elements.contains { $0.type == "pageIndicator" }
        let stillHasPager = after.elements.contains { $0.type == "pageIndicator" }
        guard hadPager, !stillHasPager else { return generic }
        return generic + " The paged layout (pageIndicator) is gone — it looks like the sheet became"
            + " a single vertical list, so `direction` no longer selects which page to advance."
    }

    /// シート展開救済で scrollFrame 容器が実際に伸びたか。伸びていなければ再試行(逆走査
    /// 8本+通常8本)は最初から無駄なので撃たない(実測: Apple マップの乗換案内
    /// シートはグラバーを引いても伸びず、32.5秒かけて同じ失敗をなぞっていた)。
    /// **どちらかの高さを測れなかったら「伸びた」扱い** = 再試行する(判断できない
    /// ときに救済を奪わない)。+1 は同一高の描画ゆらぎ吸収
    static func sheetExpansionGrew(beforeHeight: Double?, expandedHeight: Double?) -> Bool {
        guard let beforeHeight, let expandedHeight else { return true }
        return expandedHeight > beforeHeight + 1
    }

    /// シートを広げただけで目標が画面に出たか。出ていれば**再スワイプはしない**
    /// (呼び手の doc 参照 —— この画面ではスワイプがシートの折りたたみに化けるので、
    /// 出した行を自分で引っ込めることになる)。
    ///
    /// **容器で絞らない**のが要点: 探索が `scrollFrame` の中を歩くのは「まだ見えていない行を
    /// 出すため」であって、`scrollTo` が約束しているのは**画面に出ていること**。展開で
    /// シートの見出しごと出てきた場合(実測: `*立川*` は展開後のシート見出し `立川駅` にも当たる)、
    /// 容器の外だからと無視して再スワイプに入るのは、約束を満たしているのに壊しに行く動き。
    ///
    /// 画面内判定は `TapTargetGeometry.offscreenAdvisory`(nil = 画面の中)に委ねる ——
    /// **ここに2つ目の「見えているか」の定義を置かない**。ただし退化 frame(幅か高さ 0)だけは
    /// 手前で落とす: offscreenAdvisory は画面の内側にある 0x0 を「画面内」と答えるので
    /// (外して実測)、これが無いと**描かれていない一致で救済を打ち切る**
    static func visibleAfterExpansion(step: FlowStep, in snapshot: SnapshotResponse) -> ElementInfo? {
        guard let locator = step.locator,
              let hit = LocatorResolver.match(locator, in: snapshot),
              hit.frame.width > 0, hit.frame.height > 0,
              TapTargetGeometry.offscreenAdvisory(for: hit, screen: snapshot.screen) == nil
        else { return nil }
        return hit
    }

    /// 前面のアプリ内アラートとそのボタン(無ければ nil)。`RefGuard.goneMessage` へ渡す
    static func frontInAppAlertWithButtons(_ snapshot: SnapshotResponse) -> (alert: ElementInfo, buttons: [String])? {
        AlertTreeScope.frontInAppAlert(in: snapshot).map { ($0, AlertTreeScope.buttonLabels(of: $0, in: snapshot)) }
    }

    /// `visibleAfterExpansion` が容器で絞らずに採った一致が、`scrollFrame` の容器の**外**だったときの注記(中・容器が分からないときは空)。
    /// 黙ると「容器の中の行に届いた」と読まれる(計測: `*立川*` がシートの見出しに当たり、リストの行には届いていなかった)
    static func matchOutsideScrollFrameNote(_ hit: ElementInfo, step: FlowStep,
                                            in snapshot: SnapshotResponse) -> String {
        guard let container = step.scrollFrameRect
                ?? step.scrollFrame.flatMap({ LocatorResolver.match($0, in: snapshot)?.frame }),
              !container.contains(hit.frame) else { return "" }
        return " The match [\(hit.ref)] \(RefGuard.describe(hit)) is OUTSIDE the scrollFrame container, so no row"
            + " inside the list was reached — if you wanted a row of the list, read the expanded list with ft_snapshot"
            + " (swiping it again can collapse the sheet)."
    }

    /// **救済が効かないと分かった画面で、手で開く手順を名指しする**(監査)。
    /// 救済が「もう一度やっても同じ」で終わったとき、読み手に残る手は
    /// **グラバーを全開まで引いてから素の ft_snapshot を撮る**(探索が届かなくても、
    /// 展開後の木には行が載る。実測でこれだけが通った)。文言だけの案内では毎回
    /// 座標ドラッグを組み立てさせることになるので、**ref と目標 y まで出す** ——
    /// `ft_drag` は fromRef を取れるので、これはシナリオにも書ける形になる。
    /// グラバーを名指しできない画面では黙る(当てずっぽうの座標は勧めない)
    static func sheetManualExpandHint(_ snapshot: SnapshotResponse) -> String {
        guard let grabber = sheetGrabber(in: snapshot) else { return "" }
        let toY = Int((snapshot.screen.height * expandedSheetTopRatio).rounded())
        return " To open the sheet by hand: ft_drag fromRef: \(grabber.ref) toY: \(toY)"
            + " (that is [\(grabber.ref)] \(RefGuard.describe(grabber))), then read the rows with a"
            + " plain ft_snapshot — a fully expanded sheet lists them even when the scroll search"
            + " cannot walk to them."
    }

    /// 救済(シート展開 + 再試行)が**この画面では効かない**と分かったことを覚える鍵。
    /// **木の指紋そのもの**にする: 同じ画面で ft_scroll_to を撃ち直すと、
    /// 実測で救済だけに 21.2 秒を再び払っていた —— 1回目の結末は「3回目も同じ」と
    /// 明言しているのに、機械側は次の呼び出しで何も覚えていなかった。
    /// **セレクタごとには割らない**: 効かない理由は画面の性質(リスト内のドラッグが外側シートの
    /// 折りたたみに化ける)であって、何を探しているかではない
    static func sheetRescueKey(_ snapshot: SnapshotResponse) -> String {
        "\(treeFingerprint(snapshot))"
    }

    /// 再試行後の scrollFrame 容器の姿(リスト端でのスワイプが外側シートの折りたたみ/閉鎖に
    /// 化ける画面の検出)。救済前に測れていた容器が再試行後の木から消えていたら `gone`
    /// (実測: Apple マップの乗換案内は再試行のスワイプでシートごと閉じ、
    /// 最終画面が地図だけになっていた)。縮んでいたら `shrunk`。救済前から測れていない
    /// 容器については黙る(嘘を足さない)
    enum SheetRetryContainerState { case silent, shrunk, gone }
    static func sheetRetryContainerState(beforeHeight: Double?, finalHeight: Double?)
        -> SheetRetryContainerState {
        guard let beforeHeight else { return .silent }
        guard let finalHeight else { return .gone }
        return finalHeight < beforeHeight - 1 ? .shrunk : .silent
    }

    /// 待ちの秒数の印字。`5.0s` ではなく `5s`(既定値の桁が増えるだけで情報が無い)。
    /// **`Int(_:)` へ直に渡さない**: waitSeconds の値域は下限だけなので 2^63 以上も届き、変換がトラップしてサーバごと落ちる
    static func secondsText(_ seconds: Double) -> String {
        guard seconds == seconds.rounded() else { return String(format: "%.1fs", seconds) }
        return Int(exactly: seconds).map { "\($0)s" } ?? String(format: "%.0fs", seconds)
    }

    /// 満額待って外れた回に、**払った場所で**上限の変え方を名指しする。
    /// `waitSeconds` は全ての待ち(ft_snapshot / 操作系の snapshotAfter)に元からあるが、
    /// 外れた回の文がどこにもそれを名指していなかったため、読み手には「5秒固定」と読まれ、
    /// **外れると分かっている待ちにも毎回満額**を払っていた。
    /// 逃げ道は払った場所で言う(`SnapshotTruncation.remedy` と同じ規律)
    /// waitFor が外れたときの見出し(ft_snapshot・snapshotAfter・ft_batch が共有)。**切り上げたなら、そう言う** ——
    /// 黙って「現れなかった」とだけ言うと、読み込みの遅い画面で誤った「無い」として読まれる
    /// `explain`: 逃げ道の説明(waitForChange・waitSeconds)を付けるか。**デバイスごとに初回だけ**(呼び手が
    /// `firstTime("waitMissExplained")` を渡す。同じ長文が1計測で3回出ていた)
    static func waitMissHeadline(_ waitFor: String, seconds: Double, quietStopAfter: Double?,
                                 explain: Bool = true) -> String {
        guard let stopped = quietStopAfter else {
            return "waitFor \"\(waitFor)\" did not appear within \(secondsText(seconds))"
                + (explain ? waitTimeoutRemedy : "")
        }
        return "waitFor \"\(waitFor)\" did not appear — the screen had not changed for"
            + " \(secondsText(waitForQuietCutoffSeconds)), so the wait stopped after \(secondsText(stopped))"
            + " instead of running to the \(secondsText(seconds)) cap"
            + (explain ? " (if it is still loading without changing the screen, wait with waitForChange: true)" : "")
    }

    /// **待ちが外れたとき、前面に新しく出たものを名指しする**(待ちは足さない = 外れた応答に事実を足すだけ)。
    /// 実測(Apple マップ): 操作の後に遅れて出た通知の全面シートと「安全に目的地に到達するために」に3回ぶつかり、
    /// 待ちが外れても木を読み直すまで気付かなかった(1回あたり待ち約4秒 + 思考約3秒)。
    /// waitFor が当たったときの1行。**何に当たったかを名指しする**(計測: `*円*` が畳まれた地図のピンの
    /// ラベルに当たり、エージェントは運賃が出たと読み違えた)。畳まれた群の中なら下の一覧に行が無いことも言う
    static func waitForAppearedNote(_ selector: String, in snapshot: SnapshotResponse,
                                    collapsingBulk: Bool) -> String {
        let matched = matchedElements(selector, in: snapshot)
        guard let first = matched.first else { return "waitFor \"\(selector)\" appeared.\n" }
        let folded = SnapshotRenderer.foldedGroups(snapshot, flagging: [:], collapsingBulk: collapsingBulk)
            .first(where: { $0.value.contains(first.ref) })?.key
        // **数えるのは画面に描かれた、他の一致に入れ子でない要素だけ**(セルとその中の文字は1つ。計測で「+23 more」と
        // 出たが画面の行は十数行だった)
        let drawn = matched.filter { element -> Bool in
            element.frame.width > 0 && element.frame.height > 0
                && TapTargetGeometry.offscreenAdvisory(for: element, screen: snapshot.screen) == nil
        }
        func encloses(_ outer: ElementInfo, _ inner: ElementInfo) -> Bool {
            let outerArea: Double = outer.frame.width * outer.frame.height
            let innerArea: Double = inner.frame.width * inner.frame.height
            // 同じ枠なら木の深いほうが内側(行と、その中で行いっぱいの文字)
            return outer.ref != inner.ref && outer.frame.contains(inner.frame)
                && (outerArea > innerArea || (outerArea == innerArea && outer.depth < inner.depth))
        }
        let outermost = drawn.filter { inner in !drawn.contains { encloses($0, inner) } }
        let more = outermost.filter { $0.ref != first.ref && !$0.frame.contains(first.frame) }.count
        let others = more > 0 ? " (+\(more) more)" : ""
        let where_ = folded.map { " — inside the folded group #\($0) (pass expandBulk to list it)" } ?? ""
        // **ラベルを必ず出す**(describe は #id を優先するが、畳まれる群は id を共有するので id では区別できない)
        let described = RefGuard.describe(first)
        var label = ""
        if let text = first.label, !described.contains("\"\(text)\"") { label = " \"\(text)\"" }
        return "waitFor \"\(selector)\" appeared: matched [\(first.ref)] \(described)\(label)\(others)\(where_).\n"
    }

    /// ①操作前に無かった alert → 名前とボタン ②操作前に無かったラベルの操作子だけが `appearedPromptMaxButtons` 個以下
    /// しか無い画面 → そのボタン(型の無い全面シートはこの形でしか見えない)。比べる木(操作前・前回の読み)が無ければ言わない
    static func appearedPromptNote(before: SnapshotResponse?, now: SnapshotResponse) -> String {
        guard let before else { return "" }
        let earlierAlerts = Set(before.elements.filter { ElementInfo.normalizedType($0.type) == "alert" }
            .map { $0.label ?? "" })
        func buttonLabels(_ elements: [ElementInfo]) -> [String] {
            elements.filter { BridgeSnapshotThinning.operableTypes.contains($0.type) }
                .compactMap { $0.label.map(SnapshotRenderer.displayText) }.filter { !$0.isEmpty }
        }
        // **木を伏せる側と同じ判定**(`AlertTreeScope.frontInAppAlert` = いちばん手前・描かれているもの)。別に数えると
        // 注記と木で別のアラートを指す
        if let alert = AlertTreeScope.frontInAppAlert(in: now), !earlierAlerts.contains(alert.label ?? "") {
            let buttons = AlertTreeScope.buttonLabels(of: alert, in: now)
            // `describe` が型名(alert)を含むので「an alert」を重ねない(計測で "an alert alert" と指摘)
            return " — \(RefGuard.describe(alert)) has come up since the previous read"
                + (buttons.isEmpty ? "" : " (buttons: " + buttons.map { "\"\($0)\"" }.joined(separator: " / ") + ")")
                + "; it may be what is in the way"
        }
        let buttons = buttonLabels(now.elements)
        let earlierButtons = buttonLabels(before.elements)
        let earlierLabels = Set(before.elements.compactMap { $0.label.map(SnapshotRenderer.displayText) })
        // **「全部が新しい」を求めない**(実測: 通知の販促シートの「閉じる」は前の画面にもあり、黙った)。
        // 押せる物が減って(= 画面が置き換わった)、そのうち1つでも前に無かったなら言う
        guard (1...appearedPromptMaxButtons).contains(buttons.count), earlierButtons.count > buttons.count,
              buttons.contains(where: { !earlierLabels.contains($0) }) else { return "" }
        return " — the screen now offers only " + buttons.map { "\"\($0)\"" }.joined(separator: " / ")
            + " (fewer than before, and not all of them were in the previous read): a prompt or sheet may have come up in front"
    }
    /// 「前面に出たもの」とみなす操作子の上限。**根拠**: 実測の全面シートは2個(通知を有効にする / 今はしない)、
    /// アプリ内 alert のボタンは1〜3個。普通の画面は操作子がこれより多い。**尽きたとき**: 注記が出ないだけ
    static let appearedPromptMaxButtons = 3

    static let waitTimeoutRemedy =
        " (waitSeconds: <seconds> sets this cap — a smaller one to find out sooner,"
        + " a larger one for a slow load)"

    /// シート展開救済が走った(または意図的に省いた)ことを表す、応答の先頭に立つ固定の語。
    /// **所要時間の内訳(`scrollTimingNote`)と同じ語**にしてあるので、1つの文字列で
    /// 「起きたか」と「いくらかかったか」の両方を拾える —— 散文からの判別が難しいとして
    /// 構造化フラグを求められたことがあるが、この応答は宛先が
    /// エージェントの本文1本なので、**別の機械可読チャネルを増やさず語を固定する**側で応える
    static let sheetRescueMarker = "note: sheet-expand rescue "

    /// この長さ未満(ms)の探索は、救済(シート展開)が無ければ内訳を出さない —— 短い探索まで
    /// 毎回「何本振ったか」を出すと、実際に遅い回(実測 9.8/12.8/15.6s)の内訳が
    /// 埋もれる。救済ありは長さに関わらず出す(遅さの主因を切り分けたい回だから)
    static let scrollTimingNoteThresholdMs = 2000

    /// ft_scroll_to の所要時間の内訳(成功・見つからない の両方の応答の先頭)。**純粋関数**にして計測点(ContinuousClock)と
    /// 切り離す。swipes が nil(runScrollSearch を経由しなかった)でも壊れない
    /// ft_scroll_to の応答の見出し。**1回もスワイプしていなければ「スクロールした」と言わない**(目的の要素が最初から
    /// 画面に居た形。実測: 「scrolled to」と返り、動いたと読まれた)。回数が分からない(nil)ときは従来の文
    static func scrollToHeadline(_ selectorText: String, swipes: Int?) -> String {
        swipes == 0 ? "\"\(selectorText)\" was already on screen (no scroll needed)"
            : "scrolled to \"\(selectorText)\""
    }

    /// `timing` は探索の段階ごとの積算(木の読み・ジェスチャ・待ち)。遅い探索の時間がどこへ行ったかを言う
    /// (実測: 目的の語が無い探索が 3 スワイプで 15.9 秒・6 スワイプで 38 秒かかり、内訳が読めなかった)
    /// `slowDrags` = スワイプに数えないフリング無しのドラッグ(逆走査・見切れ回復。1本 最大3秒)。分けて言わないと
    /// その時間がスワイプに帰属して読まれる(実測: 実機 Android の「2 swipe(s)」の探索が逆走査7本で 25 秒)。
    /// 既定値を置かない(新しい呼び手の渡し忘れをコンパイルで止める)
    static func scrollTimingNote(totalMs: Int, swipes: Int?, slowDrags: Int?, rescueMs: Int?,
                                 timing: StepTiming?) -> String {
        guard totalMs >= scrollTimingNoteThresholdMs || rescueMs != nil else { return "" }
        var parts: [String] = []
        if let swipes {
            let drags = slowDrags.map { $0 > 0 ? " + \($0) slow no-fling drag(s)" : "" } ?? ""
            parts.append("\(swipes) swipe(s)\(drags)")
        }
        if let timing {
            let phases = [("reading the tree", timing.snapshotMs), ("gestures", timing.actionMs), ("waiting", timing.waitMs)]
                .compactMap { name, ms in ms.flatMap { $0 > 0 ? "\(name) \(Self.elapsedText(milliseconds: Double($0)))" : nil } }
            if !phases.isEmpty { parts.append(phases.joined(separator: ", ")) }
        }
        if let rescueMs {
            parts.append("sheet-expand rescue +\(Self.elapsedText(milliseconds: Double(rescueMs)))")
        }
        let detail = parts.isEmpty ? "" : " (\(parts.joined(separator: "; ")))"
        return "note: search took \(Self.elapsedText(milliseconds: Double(totalMs)))\(detail).\n"
    }

    /// 「session のアプリが今も前面か」。判定できないドライバでは黙る(嘘を足さない)
    static func foregroundNote(_ sessionBundleID: String?, driver: AppDriver) async -> String {
        guard let bundleID = sessionBundleID else { return "" }
        if let front = (try? await driver.foregroundAppID()) ?? nil {
            return front == bundleID ? " / foreground: yes"
                : " / foreground: no (\(front) is in front — ft_launch to come back)"
        }
        guard let inFront = try? await driver.isAppForeground(bundleID: bundleID) else { return "" }
        return inFront ? " / foreground: yes"
            : " / foreground: no (another app or the home screen is in front — ft_launch to come back)"
    }

    /// FM が死んでいるなら status に出す。**生きているときは黙る** —— 毎回「FM: alive」と
    /// 言っても次の一手が変わらないのに、行だけが増える(注記は黙る側に倒す)。
    ///
    /// 台帳が古ければ実呼び出しで取り直すが、**誰かが FM を使っている間は撃たない**
    /// (FMLivenessProbe.refresh の門)ので、ft_status が FM の枠を奪って run を遅らせることはない。
    /// ここで出さないと、エージェントは「occlusion-guard が効いていない画面」を
    /// **健全な画面と同じ形で受け取る**(FM の失敗は screenLooksLike では素通り・occlusion-guard では OCR だけの判定になる)
    /// **台帳を読むだけ**(FM を呼ばない)。ft_status は接続の状態を手早く見る口で、FM の実呼び出し(1回 1〜5 秒・
    /// 死んだ ANE では戻らない)を抱えない —— 実測: この呼び出しで ft_status が2分以上止まり、FMCallSlots も握ったままだった。
    /// 台帳はモニター(`api host-metrics --fm-probe`)と run の実呼び出しが養う。古ければ「不明」= 何も言わない。
    /// 確かめたいときは ft_doctor(実呼び出しで確かめる)
    static func fmLivenessNote() async -> String {
        let reading = FMLiveness.current()
        guard let reason = reading.deadSummary(limit: 200) else { return "" }
        // text 経路を使うのはシナリオの下書き・命名だけ(run の中では使わない)
        let disabled = reading.deadPaths == ["vision"]
            ? "screenLooksLike is silently skipped and the occlusion-guard of runs judges from on-device OCR alone" + OCROnlyVisibility.fmFallbackCaveat
            : reading.deadPaths == ["text"]
                ? "FM-based scenario drafting and naming (draft-scenario / gen-scenario) are unavailable"
                : "screenLooksLike is silently skipped and the occlusion-guard of runs judges from on-device OCR alone" + OCROnlyVisibility.fmFallbackCaveat + ", and FM-based"
                    + " scenario drafting and naming (draft-scenario / gen-scenario) are unavailable"
        return "\n⚠️ FM is dead on this machine (\(reading.deadPaths.joined(separator: " + "))):"
            + " \(disabled). \(reason)"
    }

    /// 接続中の Android 全台の状態。**1台ずつ独立に見る**(1台落ちていても他を隠さない)
    static func androidFleetStatus(_ serials: [String]) async -> String {
        var lines = ["\(serials.count) Android devices are connected."
            + " Pass serial: (or profile:) to operate one — this listing is status-only."]
        for device in AndroidSerialResolver.describe(serials: serials) {
            let line: String
            // 一覧は読むだけ: 動いていないブリッジを起動しない(statusIfBridgeRunning の doc)
            if let driver = try? AndroidDriver(serial: device.serial),
               let status = await driver.statusIfBridgeRunning() {
                let session = status.sessionBundleID ?? "none"
                line = "ready: \(status.ready) / \(device.label) (\(status.osVersion))"
                    + " / session: \(session)"
            } else {
                line = "bridge not running / \(device.label) (adb responds; the bridge starts on the"
                    + " first operation against this serial)"
            }
            lines.append("  serial \(device.serial): \(line)")
        }
        return lines.joined(separator: "\n")
    }

    /// 探索が止まった画面で「実際に引けるもの」を列挙する。id とラベルが両方あれば
    /// 両方出す(id だけだと、同じ id を複数のラベルが共有する画面で見分けが付かない)。
    /// **多すぎると読めない**ので上限を切る(足りなければ ft_snapshot を撮ればよい)
    /// **飾りの葉を後回しにする**(監査)。実測(Apple マップ・経路詳細で探索が
    /// 止まった回)では、この一覧の 20 枠が地図ピン(`#VKPointFeature "セブン‐イレブン"` 等)で
    /// 埋まり、探していたリストの行が1つも出なかった —— 読み手にとって情報量ゼロの 20 語。
    /// **落とすのではなく順序を落とす**: 枠が余れば出す(地図の POI を探している
    /// 回もあるので、消してしまうと逆の実害が出る)。判定は bulk fold・曖昧ラベル注記と同じ
    /// `SnapshotRenderer.isDecorativeLeaf`(2つ目の「飾りか」を作らない)
    static func actionableFirst(_ elements: [ElementInfo],
                                in snapshot: SnapshotResponse) -> [ElementInfo] {
        var actionable: [ElementInfo] = []
        var decorative: [ElementInfo] = []
        for e in elements {
            if SnapshotRenderer.isDecorativeLeaf(e, in: snapshot.elements) {
                decorative.append(e)
            } else {
                actionable.append(e)
            }
        }
        return actionable + decorative
    }

    static func visibleLabelsHint(_ snapshot: SnapshotResponse) -> String {
        var seen = Set<String>()
        var shown: [String] = []
        for e in Self.actionableFirst(snapshot.elements, in: snapshot) {
            // **ゼロ幅文字を落としてから出す**: ここから写したラベルは**見た目が正しいのに
            // 完全一致しない**(実測。Google マップの発車案内で U+200B が21個
            // 漏れていた。木の描画側は除去済みで、ヒストだけ素通しだった)
            let cleaned = e.label.map(SnapshotRenderer.displayText)
            let id = (e.identifier?.isEmpty == false) ? "#\(e.identifier!)" : nil
            let label = (cleaned?.isEmpty == false) ? "\"\(cleaned!)\"" : nil
            let name = [id, label].compactMap { $0 }.joined(separator: " ")
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            shown.append(name)
            if shown.count >= 20 { break }
        }
        guard !shown.isEmpty else { return "Nothing selectable is on screen." }
        let more = snapshot.elements.count > shown.count ? " …" : ""
        return "On screen where the search stopped: \(shown.joined(separator: " "))\(more)."
    }

    /// スクロール容器の**完全に外**に報告されている要素(ghost)を先頭で名指しする。
    ///
    /// 一覧そのものからは見分けが付かない —— ghost はフルフレームで並ぶので、
    /// 「画面に見えている行」と同じ形で出る(Compose iOS は容器の外の行も木に残す)。
    /// `waitFor` も素の存在しか見ないので、ghost だけで条件が満たされることがある。
    /// **叩けば RefGuard が止める**が、そこまで行かずに気付けるほうが往復が減る
    static func ghostRefs(_ snapshot: SnapshotResponse) -> [Int] {
        snapshot.elements
            .filter {
                RefGuard.isUntappableGhost($0, in: snapshot.elements, screen: snapshot.screen)
                    // **申告されたスクロール容器の外**も同じ印に混ぜる。
                    // `isUntappableGhost` の入口は容器の*推測*なので、申告のある UIKit/SwiftUI の
                    // 木では1件も付かず、カードを送って上へ抜けた行が**可視の行と同じ形**で
                    // 並んでいた。利用者から見て原因(そこには描かれていない)も対処
                    // (ft_scroll_to で出してから撮り直す)も同じなので、印は割らない
                    || RefGuard.outsideDeclaredScroller($0, in: snapshot.elements,
                                                        screen: snapshot.screen) != nil
            }
            .map(\.ref)
    }

    /// 残像の行に付ける印。**先頭の注記だけでは足りない**(外部フィードバック):
    /// エージェントは一覧の行から ref をコピーするので、その行自体に出ていないと届かない。
    ///
    /// 積み重なり(`stackedRefs`)にも同じ印を付ける —— 利用者から見ると原因は同じ
    /// 「スクロールの残骸がそこに描かれていない」で、対処(`ft_scroll_to` で出してから撮り直す)
    /// も同じ。**印を2種類に割らない**(見分けても打ち手が変わらないものを増やさない)
    static let leftoverMark = "⚠️scroll-leftover"
    /// 単に画面の外に居るだけの行。**危険度が違うので印を割る**。
    /// 上の `ghostFlags` の設計方針は「打ち手が変わらないものは割らない」だが、ここは
    /// **打ち手ではなく危険度**が違う —— leftover は「撃つと別の物に当たる」(沈黙した誤操作)、
    /// offscreen は「今そこに無い」だけ。実測(Apple マップの経路詳細)では、シートを広げた後に
    /// `y=-59` の行まで「別の物に当たるかも」と警告され、本物の leftover と同じ重さで並んでいた
    static let offscreenMark = "⚠️offscreen"

    /// **実計算の回数**(観測用。production の分岐には使わない)。`SnapshotAnnotationCache` 側の
    /// カウンタと違い、**キャッシュを迂回した呼び出しも数える** —— あちらだけを数えると、
    /// 「cache を渡し忘れた呼び出しが1つある」形をテストが素通しする(実際に変異2件が生き延びた)。
    /// 読むテストは直前に 0 を入れて直後に読む: `swift test --parallel` はテストごとに
    /// プロセスを分け、直列実行なら順に走るので、どちらでも他のテストと混ざらない
    static var ghostFlagsComputations: Int {
        get { ghostFlagsComputationsStore.withLock { $0 } }
        set { ghostFlagsComputationsStore.withLock { $0 = newValue } }
    }
    private static let ghostFlagsComputationsStore = Mutex(0)

    static func ghostFlags(_ snapshot: SnapshotResponse) -> [Int: String] {
        ghostFlagsComputationsStore.withLock { $0 += 1 }
        let refs = Set(ghostRefs(snapshot)).union(RefGuard.stackedRefs(snapshot.elements))
        var flags: [Int: String] = [:]
        for element in snapshot.elements where refs.contains(element.ref) {
            // 画面外判定は DSL と共有(TapTargetGeometry)。2つ目の実装を作らない
            flags[element.ref] = TapTargetGeometry.offscreenAdvisory(
                for: element, screen: snapshot.screen) != nil ? offscreenMark : leftoverMark
        }
        return flags
    }

    /// offscreen 行がどちら側にはみ出しているか(ft_scroll_to の direction 選び用)。
    /// **はみ出し量が大きい軸を主方向にする** —— 斜めにはみ出す要素も1方向へ丸める
    /// (「7px 下 + 400px 右」のような行を両方の見出しへ重複させない)。
    /// `rawValue` はそのまま注記の見出し語、`scrollDirection` は ft_scroll_to の `direction:` の語彙
    /// (指の向きではなく「読み進める内容方向」— below な行は下方向へ読み進めると出てくる = down)
    enum OffscreenDirection: String, CaseIterable {
        case below, above
        case right = "to the right"
        case left = "to the left"

        var scrollDirection: String {
            switch self {
            case .below: return "down"
            case .above: return "up"
            case .right: return "right"
            case .left: return "left"
            }
        }
    }

    /// 実測(Apple マップの経路候補・横ページャ): 第2候補は x=401(画面幅402 の右隣ページ)に居て、
    /// 一度も表示していないのに旧文言「scrolled past」は不正確だった。
    /// 中心がどちらの縁をどれだけ超えているかを4方向とも計算し、いちばん超過が大きい方を返す
    static func offscreenDirection(of element: ElementInfo, screen: FTRect) -> OffscreenDirection {
        let cx = element.frame.centerX, cy = element.frame.centerY
        let overflows: [(OffscreenDirection, Double)] = [
            (.below, cy - (screen.y + screen.height)),
            (.above, screen.y - cy),
            (.right, cx - (screen.x + screen.width)),
            (.left, screen.x - cx),
        ]
        // 全方向が非正(=画面内)になることは呼び出し元の条件(offscreenMark 済み)上ないが、
        // 万一そろっても below を既定にして必ず1方向を返す
        return overflows.max { $0.1 < $1.1 }?.0 ?? .below
    }

    /// **collapsingBulk は render() と揃える**: 畳まれる ref をここでも個別に
    /// 列挙すると、地図 POI のような大量群で出力の半分がこの注記に化ける。
    /// どの ref が畳まれるかは `SnapshotRenderer.foldedGroups` — render 本体と同じ関数 — で決める
    /// 残像の行の対処文。**ft_scroll_to の応答では「先に ft_scroll_to で出せ」と言わない**(探索の結果に対して循環する = 計測で指摘)
    static func leftoverRemedy(afterScrollSearch: Bool) -> String {
        afterScrollSearch
            ? " They are rows the search scrolled past; if you need one, verify it with ft_screenshot before tapping"
            : " Bring them into view with ft_scroll_to first, or verify with ft_screenshot"
    }

    static func ghostNote(_ snapshot: SnapshotResponse, collapsingBulk: Bool = true,
                          afterScrollSearch: Bool = false,
                          cache: SnapshotAnnotationCache? = nil) -> String {
        let flagged = cache?.ghostFlags(snapshot) ?? ghostFlags(snapshot)
        let folded = cache?.foldedGroups(snapshot, flagging: flagged, collapsingBulk: collapsingBulk)
            ?? SnapshotRenderer.foldedGroups(snapshot, flagging: flagged,
                                             collapsingBulk: collapsingBulk)
        let leftovers = snapshot.elements.filter { flagged[$0.ref] == leftoverMark }
        let offscreens = snapshot.elements.filter { flagged[$0.ref] == offscreenMark }
        var note = ""
        if !leftovers.isEmpty {
            note += "note: the \(leftoverMark) rows below are not drawn where their frames say"
                + " (outside their scroll container, or clamped onto another row's frame),"
                + " so tapping them may hit something else:"
                + " \(listRefs(leftovers, folded: folded, in: snapshot.elements))."
                + leftoverRemedy(afterScrollSearch: afterScrollSearch) + "\n"
        }
        if !offscreens.isEmpty {
            let byDirection = Dictionary(grouping: offscreens) {
                Self.offscreenDirection(of: $0, screen: snapshot.screen)
            }
            var groups: [String] = []
            var directions: [String] = []
            for direction in OffscreenDirection.allCases {
                guard let elements = byDirection[direction], !elements.isEmpty else { continue }
                groups.append("\(direction.rawValue):"
                    + " \(listRefs(elements, folded: folded, in: snapshot.elements))")
                directions.append(direction.scrollDirection)
            }
            note += "note: the \(offscreenMark) rows below are off the screen, so they are listed"
                + " but not visible — \(groups.joined(separator: " / "))."
                + " Reach them with ft_scroll_to (direction: \(directions.joined(separator: " / ")))"
                + " before using them"
                + Self.pageIndicatorHint(byDirection: byDirection, snapshot: snapshot) + "\n"
        }
        return note
    }

    /// 横ページャ(`pageIndicator`)が居るときだけ、左右の offscreen 行への言い換えを添える
    /// (実測: Apple マップの経路候補・横ページャで、右隣ページの行が「消えた」ように見えた)。
    /// 縦方向(below/above)だけの offscreen では出さない —— 縦スクロールは既に案内済みで、
    /// pageIndicator の有無とは無関係
    private static func pageIndicatorHint(byDirection: [OffscreenDirection: [ElementInfo]],
                                          snapshot: SnapshotResponse) -> String {
        let horizontal = [OffscreenDirection.right, .left]
            .filter { byDirection[$0]?.isEmpty == false }
        guard !horizontal.isEmpty,
              let pager = snapshot.elements.first(where: { $0.type == "pageIndicator" })
        else { return "" }
        let quoted = (pager.value ?? pager.label).map { " \"\(SnapshotRenderer.displayText($0))\"" } ?? ""
        let dirs = horizontal.map(\.scrollDirection).joined(separator: "/")
        let rows = horizontal.flatMap { byDirection[$0] ?? [] }
        return " A horizontal pager\(quoted) is on screen — it renders one page at a time, so the"
            + " \(dirs) rows above are likely just on another page; ft_scroll_to"
            + " (direction: \(dirs)) should reach them."
            + Self.pagerScrollFrameHint(for: rows, in: snapshot)
    }

    /// **特定できたときだけ**足す一文。実測(Apple マップの経路候補・横ページャ): 上の案内どおり
    /// scrollFrame: 無しで撃つと 24.6 秒かけて1ページも動かず、既定の全画面スワイプに落ちて
    /// 地図そのものがパンされた。scrollFrame: に容器を渡すと 3.1 秒で届いた。
    /// 容器は offscreen 行の scrollable な祖先(`TapTargetGeometry.ancestors`)から採る ——
    /// 祖先が1つに決まらない/scrollable な祖先が無い木では黙る(嘘の助言を出さない)
    private static func pagerScrollFrameHint(for rows: [ElementInfo],
                                             in snapshot: SnapshotResponse) -> String {
        var scrollers = Set<Int>()
        for row in rows {
            if let scroller = TapTargetGeometry.ancestors(of: row, in: snapshot.elements)
                .first(where: { $0.scrollable == true }) {
                scrollers.insert(scroller.ref)
            }
        }
        guard scrollers.count == 1, let ref = scrollers.first,
              let container = snapshot.elements.first(where: { $0.ref == ref })
        else { return "" }
        // **id が画面で一意なら #id、でなければ ref**(uniqueScopeID と同じ数え方を使い回す)。
        // 実測: この容器とページャ自身が同じ id を名乗っており(×2)、#id では指せなかった
        let id = container.identifier.flatMap { $0.isEmpty ? nil : $0 }
        let pass = (id.map { Self.idCounts(in: snapshot)[$0] == 1 } ?? false)
            ? "scrollFrame: #\(id!)"
            : "scrollFrame: \(ref) (its ft_snapshot ref — #id here is not unique)"
        return " Pass \(pass) to ft_scroll_to — without it, the default full-screen swipe may pan"
            + " something else (like the map behind it) instead of the pager."
    }

    /// 同じ印の付いた行のうち**最外のものだけ**を残す(実アプリ監査)。
    /// 実測(Apple マップの経路詳細)では leftover 8 件のうち 7 件が先頭行の子孫で、
    /// **1つのはみ出しを 8 回読ませて**いた。子孫を撃つときは祖先も必ず同じ状態なので、
    /// 最外だけ名指しても安全上の情報は減らない(行そのものに付く ⚠️ 印は全行に出る)。
    /// 返り値の第2要素は落とした件数 —— **黙って消さない**(件数は注記に出す)
    static func outermost(_ elements: [ElementInfo],
                          in all: [ElementInfo]) -> (outer: [ElementInfo], dropped: Int) {
        let refs = Set(elements.map(\.ref))
        let outer = elements.filter { e in
            !TapTargetGeometry.ancestors(of: e, in: all).contains { refs.contains($0.ref) }
        }
        return (outer, elements.count - outer.count)
    }

    /// 注記に並べる ref の列挙。**8件で打ち切る**(全部出すと注記だけで木より長くなる)。
    /// **畳まれた ref は個別に出さず、件数だけ言う**(render 側で ×M の1行に既に畳まれているので、
    /// ここでも列挙すると二重に情報過多になる)
    private static func listRefs(_ elements: [ElementInfo], folded: [String: Set<Int>],
                                 in all: [ElementInfo]) -> String {
        let (outer, descendants) = outermost(elements, in: all)
        let visible = outer.filter { e in
            guard let id = e.identifier else { return true }
            return !(folded[id]?.contains(e.ref) ?? false)
        }
        var parts: [String] = []
        if !visible.isEmpty {
            let listed = visible.prefix(8).map { "[\($0.ref)] \(RefGuard.describe($0))" }
                .joined(separator: " ")
            parts.append(listed + (visible.count > 8 ? " (+\(visible.count - 8) more)" : ""))
        }
        if descendants > 0 {
            parts.append("(+\(descendants) descendant row(s) of these, same flag)")
        }
        var byID: [String: Int] = [:]
        var order: [String] = []
        // **畳みの集計も outer で数える**: descendants に数えた行をここでも数えると、
        // 同じ1行が「子孫」と「畳まれた」の両方に乗って合計が実際の件数を超える
        for e in outer {
            guard let id = e.identifier, let group = folded[id], group.contains(e.ref) else { continue }
            if byID[id] == nil { order.append(id) }
            byID[id, default: 0] += 1
        }
        parts.append(contentsOf: order.map {
            "(+\(byID[$0]!) folded into the ×\(folded[$0]!.count) id=\($0) line below)"
        })
        return parts.joined(separator: " ")
    }

    /// 木の中に**同じ連続領域が2回**現れる形の注記(
    /// jma.go.jp を横スクロールした後の iOS Safari で実測)。横スクロールで前後のコピーが
    /// 両方残ると、片方は既にスクロールで動いた実座標を持たないまま木に残る = 読み手が
    /// コピーした ref が古い側かもしれない。
    ///
    /// **判定は `FTCore.DuplicateRegion` が唯一の定義元**(閾値・y/x 制約・誤検知の witness・
    /// アルゴリズムの根拠はそちら。DSL のタップも同じ判定を `StepNote.staleDuplicateRegion`
    /// として運ぶ)。ここが持つのは文言だけ
    /// **2回目からは短縮する**(`abbreviated`)。同じ画面を読み直すたびに同じ長文と「ft_screenshot で確かめよ」が
    /// 出ていた(実測: Apple マップの乗車案内の横スクロールで毎回)。どの ref が対かは毎回言う(ref は読みごとに変わる)
    static func duplicateRegionNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false) -> String {
        guard let match = DuplicateRegion.find(in: snapshot.elements) else { return "" }
        if abbreviated {
            return "note: the same \(match.length) elements are listed twice ([\(match.firstRef)] and"
                + " [\(match.secondRef)]) — refs from one copy may be stale (see the earlier note).\n"
        }
        return "note: the tree appears to list the same \(match.length) elements twice — starting at"
            + " [\(match.firstRef)] and again at [\(match.secondRef)] (same type/label/value, same row,"
            + " shifted x). This happens when a scrollable region moved (e.g. a"
            + " horizontally-scrolled table) but the tree still reports the previous rows"
            + " alongside the new ones — refs from one copy may be stale. Check ft_screenshot to"
            + " see which copy is actually on screen.\n"
    }

    static func lineNote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : "note: \(trimmed)\n"
    }

    /// スクロールできる容器の実名の列挙だけ(理由の断定はしない。呼び出し側の文に添える)
    static func scrollAlternativesHint(_ snapshot: SnapshotResponse) -> String {
        let real = ScrollFrameCandidates.candidates(in: snapshot)
            .compactMap(\.selector).prefix(4).joined(separator: " ")
        return real.isEmpty
            ? " No element on this screen declares itself scrollable."
            : " Scrollable areas here: \(real)."
    }

    /// `isAndroid`: 「in-app エンジンだけが Compose/Flutter の申告を見られる」は iOS の話
    /// (in-app vs XCUITest エンジンの差)。Android にエンジンの選択肢は無いので、そのまま出すと
    /// 存在しない切り替え先を示唆する
    static func scrollAreaHint(_ snapshot: SnapshotResponse, args: [String: Any],
                               isAndroid: Bool) -> String {
        // **渡した scrollFrame が複数に当たっているなら、それを先に言う**。`matchDetailed` は
        // 添字が無ければ `matches[0]` を黙って採るので、同名の容器が並ぶ画面では
        // preorder 先頭(たいてい横カルーセル)を掴んだまま「見つからない」で終わる。
        // 実測(Google マップ Android): `#recycler_view` は1画面に4つあり、
        // 注記どおり渡すと高さ126pxのチップ行が選ばれて結果リストは1pxも動かなかった。
        // **ref 指定は曖昧さが無い**(id の重複・欠落を避けるための逃げ道そのものなので、
        // 「他にも当たる」という注記自体が成立しない)。resolveScrollFrameArg 側で
        // 解決済みなのでここでは何も言わない
        if args["scrollFrame"] is Int { return "" }
        // **StepExecutor 側の申告は当てにしない** —— あちらの `pendingScrollFrameNote` は
        // 探索ループの条件分岐の中でしか埋まらず、空振りのまま失敗する回では nil のままになる
        if let frame = args["scrollFrame"] as? String {
            let locator = FTSelector.parse(frame).primary
            let matches = LocatorResolver.candidates(locator, elements: snapshot.elements) ?? []
            // **1件も当たらないなら、その事実こそ言う**: 誤字や範囲外の添字でも
            // `scrollContainer` は nil を返し、**探索そのものを打ち切る(fail-fast)**
            // (全画面スワイプへ退化させるとカードのボタン等を誤発火させる実害があった。
            // ここは fail-fast の理由文に添える候補列挙)
            if matches.isEmpty {
                // 「search was not run」とはここでは言わない —— fail-fast の理由文
                // (StepExecutor.scrollNotFoundMessage)が既に言っており、このヒントは
                // 成功時の note にも合流するので、断定すると成功メッセージで嘘になる
                return " scrollFrame \"\(frame)\" matches nothing on this screen."
                    + Self.scrollAlternativesHint(snapshot)
            }
            guard locator.index == nil, matches.count >= 2 else { return "" }
            let listed = matches.prefix(4).enumerated().map { index, element -> String in
                let f = element.frame
                return "[\(index)] (\(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height)))"
            }.joined(separator: " ")
            return " scrollFrame \"\(frame)\" matches \(matches.count) elements and the first one"
                + " was used — add [n] to pick another: \(listed)."
        }
        // **スクロール容器が1つも申告されない木**では、案内が出せない理由ごと言う(
        // 監査)。XCUITest エンジンの木には Compose/Flutter のスクロール容器が出ない(MCP の iOS は常に XCUITest
        // なので、in-app を勧めない = エージェントが選べない手を示さない)。黙ると「scrollFrame を渡せ」という
        // ツール説明だけが残り、渡す候補が無いことに気づけない
        if !snapshot.elements.contains(where: { $0.scrollable == true }) {
            let engineCaveat = isAndroid ? "" : " (the XCUITest tree does not show Compose/Flutter"
                + " scroll containers)"
            return " No element in this tree declares itself scrollable\(engineCaveat), so the"
                + " search swiped the whole screen. If the target sits in a horizontal row, scroll"
                + " the row with ft_drag inside its bounds; a container that has a #id (testTag)"
                + " can still be passed as scrollFrame:."
        }
        guard let note = ScrollFrameCandidates.note(snapshot) else { return "" }
        return " " + note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 候補選定の規則(装飾葉の除外・スコア付け・編集距離)は `FTCore.SimilarLabels` が唯一の
    /// 定義元(DSL 側の `LocatorResolver.candidateHint` と共有する)。
    /// ここは MCP 応答の文言(`"note: similar labels on screen: …"`)の組み立てだけを持つ ——
    /// **この文言は既存の MCP テスト・NoteBudgetTests のバイト数ゲート対象で1文字も変えない**
    static func isSimilarText(_ a: String, _ b: String) -> Bool {
        SimilarLabels.isSimilarText(a, b)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        SimilarLabels.editDistance(a, b)
    }

    /// waitFor が空振りしたとき、画面に**近い**ラベル/id を最大3件挙げる。
    /// 実測: 経路ボタンを `waitFor "経路"` と推測したら実ラベルは「計画」で5秒空振りした。
    /// **断定しない**(「これのことでは」とは書かない) —— 似ているというだけで、
    /// 別物を待っていた可能性を否定できる材料は無い。
    /// 同じ target を label/id 両方の経路で見る(`SimilarLabels.candidates` の labelTarget/idTarget
    /// に同じ文字列を渡す) —— どちらの欄で書き間違えたかは読み手にも分からないため
    static func similarLabelsHint(_ selectorText: String, in snapshot: SnapshotResponse) -> String {
        let locator = FTSelector.parse(selectorText).primary
        guard let raw = locator.label ?? locator.id,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let target = FlowMatchMode.normalizeInvisibleCharacters(raw)
        let top = SimilarLabels.candidates(labelTarget: target, idTarget: target, in: snapshot)
        guard !top.isEmpty else { return "" }
        let display = top.map { $0.field == .label ? "\"\($0.matchedText)\"" : "#\($0.matchedText)" }
        // **部分一致が1つも無いなら「似ている」と言わない**: 短い語同士は編集距離で拾うが、2文字の語は互いに必ず距離2以下で
        // 何でも当たる(計測: `*経路*` に「共有」「計画」「追加」を挙げ、根拠が分からないと指摘された。正解の「計画」は残したい)
        guard top.contains(where: { $0.strength == .strong }) else {
            return " note: no label contains it; short labels on screen: \(display.joined(separator: ", "))."
        }
        return " note: similar labels on screen: \(display.joined(separator: ", "))."
    }

    /// セレクタの**記法**が原因で外れたときだけ出す助言。無条件に「\* で囲め」と言うと
    /// 誤った助言を2形返す(Google マップで実測): 既に `*寿司*` を渡した相手に
    /// 同じ `*寿司*` を勧める / `#no_such_id` に**ラベル部分一致**の `*no_such_id*` を勧める。
    /// 判定は DSL と同じ `LocatorResolver.partialMatchHint` に委ねる(3条件そろったときだけ返る)。
    /// 切り詰めラベルの取り違えはそれとは別の形なので独立に足す
    static func notationHint(_ selectorText: String, in snapshot: SnapshotResponse) -> String {
        var parts: [String] = []
        if let hint = SnapshotRenderer.truncatedSelectorHint(selectorText, in: snapshot) {
            parts.append(hint)
        }
        let locator = FTSelector.parse(selectorText).primary
        if let hint = LocatorResolver.partialMatchHint(for: locator, in: snapshot.elements) {
            parts.append(" The element is \(hint).")
        }
        if let hint = partialMatchFormHint(locator, in: snapshot.elements) {
            parts.append(hint)
        }
        // 「画面には出ているのに当たらない」の残りの形: **本文が複数ノードに割れている**。
        // 判定は DSL と同じ LocatorResolver.splitTextHint(素で当たるものがあれば黙る)
        if let hint = LocatorResolver.splitTextHint(for: locator, in: snapshot.elements) {
            parts.append(" \(hint.prefix(1).uppercased())\(hint.dropFirst()).")
        }
        parts.append(currencyNotationHint(locator.label ?? "", in: snapshot))
        return parts.joined()
    }

    /// 金額の表記が待った語と違うときの一言(`*円*` で待ったのに画面は `¥715`、またはその逆)。
    /// 実測(地図の運賃調べ・計測4回で計7回): waitFor `*円*` が外れ、画面は `¥715 IC料金` / `￥1020` だった。
    /// 同じ金額の書き方の違いだけを言う(何の金額かは言わない = 画面の意味は読み手が決める)
    /// "\u{5186}" = 円(CLI の文字列は英語だけ = CLIEnglishStringsScanTests。これは画面の文字と照合する記号の表で表示ではない)
    static let currencyMarks = ["\u{5186}", "¥", "￥"]

    static func currencyNotationHint(_ selectorLabel: String, in snapshot: SnapshotResponse) -> String {
        guard let asked = currencyMarks.first(where: { selectorLabel.contains($0) }) else { return "" }
        let others = currencyMarks.filter { $0 != asked }
        let examples = snapshot.elements.compactMap { $0.label.map(SnapshotRenderer.displayText) }
            .filter { label in others.contains { label.contains($0) } && label.contains(where: \.isNumber) }
        guard let first = examples.first else { return "" }
        let shown = Array(Set(examples)).sorted().prefix(2).map { "\"\($0.prefix(30))\"" }.joined(separator: ", ")
        let mark = others.first { first.contains($0) } ?? others[0]
        return " note: amounts on this screen are written with \"\(mark)\", not \"\(asked)\" (e.g. \(shown))"
            // **「この画面では」と限る**: 同じアプリでも画面ごとに表記が違う(計測: 運転の画面は「￥1350」、次の交通機関の画面は
            // 「720円」。「*￥* で待て」を次の画面にも持ち越して外した)
            + " — on this screen, wait for *\(mark)* instead; other screens of the same app may use \"\(asked)\"."
    }

    /// 逆向きの content direction(注記で「戻れ」と言うときの語彙)。
    /// `FTScrollDirection.swipe` と値は同じになるが**意味が違う**(あちらは指の向き)ので別に持つ
    static func reversedDirection(_ direction: FTScrollDirection) -> String {
        switch direction {
        case .down: return "up"
        case .up: return "down"
        case .right: return "left"
        case .left: return "right"
        }
    }

    /// 探索が空振りしたときの記法ヒント。**最終木で出なければ探索を始めた木で見る**。
    ///
    /// `notationHint` は渡された1枚の木しか見ないので、部分一致の相手が探索のスワイプで
    /// 画面外へ流れると**ヒントごと黙る** —— 読み手は「`*X*` と書け」を受け取れないまま同じ式で
    /// 撃ち直す。さらに、開始時の木からしか出せなかったということは**その要素はもう後ろにある**
    /// ので、勧めた `*X*` をそのまま同じ向きで撃っても届かない(実害: apple.com で `Shop` が
    /// 8スワイプ空振り → 勧められた `*Shop*` も同じ結果)。
    /// **両方の木から出せた回は「探索前から分かっていた」と帰属させる**(下の分岐の理由)。
    /// `backDirection` は探索方向の逆(呼び手が渡す)
    static func scrollNotationHint(_ selectorText: String, after: SnapshotResponse,
                                   beforeScroll: SnapshotResponse?,
                                   backDirection: String) -> String {
        let fromFinal = notationHint(selectorText, in: after)
        let fromStart = beforeScroll.map { notationHint(selectorText, in: $0) } ?? ""
        if !fromFinal.isEmpty {
            // **待たされた理由を帰属させる**(追加フィードバック): 開始画面から
            // 同じ答えが出せた回は、スワイプの秒数を丸ごと捨てている。**時間は縮まない**
            // (MCP は1応答なので「これから探します」を先に届ける口が無い)が、
            // 黙っていると「完全一致は即成功・部分一致だけは 24 秒かけて失敗」という
            // 非対称が原因不明のまま残り、同じ書き方を繰り返すことになる
            return fromStart.isEmpty ? fromFinal
                : fromFinal + " This was already true on the screen where the search started,"
                    + " so the swipes could not have helped — when a plain label is not on the"
                    + " current screen, check it for a partial match before scrolling."
        }
        guard !fromStart.isEmpty else { return "" }
        return fromStart + " That was on the screen where this search STARTED — the search has"
            + " since scrolled past it, so re-running with direction: \(backDirection) (or going"
            + " back to that screen first) is what actually reaches it."
    }

    /// **記法の形違い**による部分一致の空振り。実測: `*武蔵野線`(endsWith)を渡して
    /// 7スクロール空振りした(正解は `*武蔵野線*`)。LocatorResolver.partialMatchHint は
    /// 「素の完全一致指定が部分一致なら在る」しか見ないので、**既に endsWith/startsWith を
    /// 指定した相手が別の部分一致形でなら当たる**ケースはここで別に見る。
    /// **既に contains 形(`*x*`)を渡している相手には出ない**(mode が endsWith/startsWith
    /// でなければ何もしないので、誤って同じ助言を繰り返すことはない)
    static func partialMatchFormHint(_ locator: FlowLocator, in elements: [ElementInfo]) -> String? {
        if let label = locator.label, !label.isEmpty, let mode = locator.labelMatch,
           mode == .endsWith || mode == .startsWith,
           !elements.contains(where: { mode.matches($0.label, label) }),
           elements.contains(where: { FlowMatchMode.contains.matches($0.label, label) }) {
            return partialMatchFormText(mode: mode,
                                        typed: mode == .endsWith ? "*\(label)" : "\(label)*",
                                        suggestion: "*\(label)*")
        }
        if let id = locator.id, !id.isEmpty, let mode = locator.idMatch,
           mode == .endsWith || mode == .startsWith,
           !elements.contains(where: { mode.matches($0.identifier, id) }),
           elements.contains(where: { FlowMatchMode.contains.matches($0.identifier, id) }) {
            return partialMatchFormText(mode: mode,
                                        typed: mode == .endsWith ? "#*\(id)" : "#\(id)*",
                                        suggestion: "#*\(id)*")
        }
        return nil
    }

    private static func partialMatchFormText(mode: FlowMatchMode, typed: String,
                                              suggestion: String) -> String {
        let article = mode == .endsWith ? "an ends-with" : "a starts-with"
        let verb = mode == .endsWith ? "ends with" : "starts with"
        return " \"\(typed)\" is \(article) match and nothing \(verb) that text —"
            + " \"\(suggestion)\" (contains) would match here."
    }

    /// スナップショットが上限で打ち切られていたときの注記(欠陥①a)。**打ち切りは配列そのものからの
    /// 脱落**であって描画の省略ではないので、waitFor/scrollTo は打ち切られた要素を一生探し続ける。
    /// 実測: 画面に描画されている `#nav_button` を waitFor が「did not appear」、scrollTo が
    /// 「element not found」としか言わず、存在しない要素を探し続けることになっていた。
    ///
    /// **残っている手の判定は `FTCore.SnapshotTruncation.remedy`(DSL と共有)**。文言だけは
    /// 呼び手ごとに持つ —— MCP は `ft_snapshot maxElements:` と書き、DSL は
    /// `.webView >> ...` / `scrollFrame:` と書く。
    /// **逃げ道まで書く**: 「落ちた中に居るかもしれない」で止めると、読み手は同じ探索を
    /// 撃ち直す(ブラウザ監査で 45.3s + 56.1s を空費した)
    static func truncationHint(_ snapshot: SnapshotResponse) -> String {
        guard let remedy = SnapshotTruncation.remedy(for: snapshot) else { return "" }
        let escape = truncationEscape(remedy, for: .hint)
        // **`elements.count` を印字しない**(SnapshotTruncation.budgetedCount のレビュー参照):
        // bulk 群は予算の外で送られるので、生の件数は escape が勧める上限より大きく見える。
        // 予算ぶんの件数を出し、bulk が居るときだけ内訳を添える(DSL 側 truncationHint と同型)
        let budgeted = SnapshotTruncation.budgetedCount(snapshot)
        let bulk = SnapshotTruncation.bulkExemptPresentCount(snapshot)
        let bulkClause = bulk > 0 ? " (plus \(bulk) bulk-exempt elements outside the budget)" : ""
        return " (the tree was truncated at \(budgeted) elements\(bulkClause);"
            + " \(snapshot.truncatedCount) more were omitted — the element you are looking for"
            + " may be among them; scrolling will not bring them back, \(escape))"
    }

    /// `truncationHint`/`truncationNote` の2呼び手が使う逃げ道文言。
    /// **文言は呼び手ごとに意図して別々のまま並置している**(docs/design.md の規律:
    /// 「判定は共有・文言は呼び手ごと」)—— ここへ同居させているのは統一するためではなく、
    /// 次に文言を調整するとき両方が編集者の目に入るようにするため。**片方だけ直すな**
    private enum TruncationEscapeStyle {
        case hint
        case note
    }

    private static func truncationEscape(_ remedy: SnapshotTruncation.Remedy,
                                         for style: TruncationEscapeStyle) -> String {
        switch (style, remedy) {
        case (.hint, .raiseLimit(let limit)):
            return "read again with ft_snapshot maxElements: \(limit)"
        case (.hint, .narrowTheScreen):
            return "raising the limit will not help (already at the"
                + " \(BridgeAPI.maxSnapshotElementsCeiling)-element ceiling) — narrow the screen"
                + " (close a sheet, scroll a big list away)"
        case (.note, .raiseLimit(let limit)):
            return "Read again with ft_snapshot maxElements: \(limit) to get them, or narrow"
                + " the screen (close a sheet, scroll a big list away)."
        case (.note, .narrowTheScreen):
            return "Raising the limit will not help (already at the"
                + " \(BridgeAPI.maxSnapshotElementsCeiling)-element ceiling) — narrow the screen"
                + " (close a sheet, scroll a big list away)."
        }
    }

    /// waitFor タイムアウト文の共通末尾(監査)。waitFor はレンダリング済みの木しか
    /// 見ないので、探した相手がスクロール圏外にいると満額(既定5秒〜)を空費する
    /// (実測: 週間予報表が初期表示の下にあり、25秒2回=52秒を空費した。正解は ft_scroll_to)。
    /// **ft_snapshot(MCPServer+ScreenTools.swift)と snapshotAfter(MCPServer+Snapshot.swift)の
    /// 両方が呼ぶ唯一の定義元**(片方だけ変わる事故を防ぐ)。スクロール容器が1つも申告されて
    /// いない画面ではスクロールが答えになり得ないので黙る
    static func waitForScrollHint(in snapshot: SnapshotResponse, explain: Bool = true) -> String {
        guard !ScrollFrameCandidates.candidates(in: snapshot).isEmpty else { return "" }
        guard explain else { return " — if the target is further down, use ft_scroll_to." }
        return " — waitFor only looks at what is currently rendered: if the target is further down,"
            + " use ft_scroll_to (it searches by scrolling)."
    }

    /// 1回の応答組み立て(snapshotBody / scrollTo)に**閉じた**計算の使い回し。
    /// **寿命は呼び出し元のローカル変数だけ**——インスタンスをまたいで保持すると、木が変わった後の
    /// 応答が古い ghost/graded を返す事故になるので、MCPServer の instance state
    /// (refGenerations 等)には絶対に置かない。呼び出し元は snapshot を撮り直すたびに
    /// 新しいインスタンスを作ること(このクラス自身は「同じ snapshot 値に対して同じ答えを返す」
    /// こと以上は保証しない)。
    ///
    /// 実測(実アプリ 203 要素画面): 素の呼び出しは同じ木に対して ghostFlags を
    /// 3回・foldedGroups を2回払い、ambiguousLabelsNote と duplicateIDsNote は別々の
    /// SelectorNaming を作るので、両方の群に出る要素の graded が二重に走ることがあった。
    final class SnapshotAnnotationCache {
        private var ghostFlagsResult: [Int: String]?
        /// collapsingBulk の値で結果が変わる(duplicateIDsNote は常に true で引く一方、
        /// ghostNote/render は expandBulk 引数由来の値)ので bool をキーにする
        private var foldedGroupsResults: [Bool: [String: Set<Int>]] = [:]
        private var namingInstance: SelectorNaming?

        /// テストが「1応答で1回だけ計算したか」を確かめるための実計算回数(キャッシュヒットは
        /// 数えない)。production の分岐には使わない——観測用のカウンタを増やすだけ
        private(set) var ghostFlagsComputeCount = 0
        private(set) var foldedGroupsComputeCount = 0
        /// `SelectorNaming.gradedComputeCount` への転送(naming が未生成なら 0)
        var gradedComputeCount: Int { namingInstance?.gradedComputeCount ?? 0 }

        func ghostFlags(_ snapshot: SnapshotResponse) -> [Int: String] {
            if let ghostFlagsResult { return ghostFlagsResult }
            ghostFlagsComputeCount += 1
            let result = MCPServer.ghostFlags(snapshot)
            ghostFlagsResult = result
            return result
        }

        /// **テスト専用の注入口**。呼び出し回数のカウンタは「cache を経由した呼び出し」しか
        /// 数えられないので、ある呼び手が cache 引数を丸ごと渡し忘れて生の関数を直呼びしても、
        /// 別の呼び手が後から同じ cache を正しく使えばカウンタは辻褄が合ってしまう
        /// (mutation-check で実際に2件すり抜けた)。**値の出所**を追う ——
        /// ここで明らかに間違った値を仕込み、応答にその値が現れるかで「本当にこのインスタンスを
        /// 読んだか」を確かめる。production コードはこのメソッドを呼ばない
        func primeGhostFlagsForTesting(_ value: [Int: String]) {
            ghostFlagsResult = value
        }

        func foldedGroups(_ snapshot: SnapshotResponse, flagging: [Int: String],
                          collapsingBulk: Bool) -> [String: Set<Int>] {
            if let cached = foldedGroupsResults[collapsingBulk] { return cached }
            foldedGroupsComputeCount += 1
            let result = SnapshotRenderer.foldedGroups(snapshot, flagging: flagging,
                                                       collapsingBulk: collapsingBulk)
            foldedGroupsResults[collapsingBulk] = result
            return result
        }

        /// `ambiguousLabelsNote` と `duplicateIDsNote` が**同じ**インスタンス(=同じ graded メモ)
        /// を共有するための入口。**snapshot はここに渡した1つに固定する**呼び出し規約
        /// (SelectorNaming.graded と同じ規約 — 別の木を渡すと ref が衝突する)
        func selectorNaming(_ snapshot: SnapshotResponse) -> SelectorNaming {
            if let namingInstance { return namingInstance }
            let created = SelectorNaming(snapshot)
            namingInstance = created
            return created
        }
    }

    // SelectorNaming / Durability の実体は FTCore.SelectorNaming / FTCore.Durability
    // (FTCore に置く理由: StepExecutor の自己修復書き戻しも同じ判定を要るため)。
    // ここは呼び出し元・テストの綴りを変えないための typealias + 転送だけ
    // (RefGuard.swift が TapTargetGeometry/OcclusionGeometry へ転送しているのと同じ形)
    typealias SelectorNaming = FTCore.SelectorNaming
    typealias Durability = FTCore.Durability

    static func picksExactly(_ element: ElementInfo, with selector: String,
                             in snapshot: SnapshotResponse) -> Bool {
        SelectorNaming.picksExactly(element, with: selector, in: snapshot)
    }

    static func picksOnlyOne(_ element: ElementInfo, with selector: String,
                             in snapshot: SnapshotResponse) -> Bool {
        SelectorNaming.picksOnlyOne(element, with: selector, in: snapshot)
    }

    static func idCounts(in snapshot: SnapshotResponse) -> [String: Int] {
        SelectorNaming.idCounts(in: snapshot)
    }

    static func uniqueScopeID(for element: ElementInfo, in snapshot: SnapshotResponse,
                              idCounts precomputed: [String: Int]? = nil) -> String? {
        SelectorNaming.uniqueScopeID(for: element, in: snapshot, idCounts: precomputed)
    }

    static func scopedSelector(for element: ElementInfo, in snapshot: SnapshotResponse,
                               idCounts precomputed: [String: Int]? = nil) -> String? {
        SelectorNaming.scopedSelector(for: element, in: snapshot, idCounts: precomputed)
    }

    static func scopedSelector(scope: ElementInfo, for element: ElementInfo,
                               in snapshot: SnapshotResponse) -> String? {
        SelectorNaming.scopedSelector(scope: scope, for: element, in: snapshot)
    }

    /// 木が空(要素0)であること自体を言う。**一覧が空なのと「画面に何も無い」のは別**で、
    /// 実測(Android Chrome の初回起動ダイアログを閉じた直後)では
    /// `screen: 1080x2424` の1行だけが返り、**遷移中である**という手掛かりがどこにも無かった。
    /// 木だけで判る事実なので目録に載る(NoteCatalog)。**次の一手まで書く** ——
    /// ここで読み手が撃つべきは撮り直しではなく `waitFor` 付きの1回
    static func emptyTreeNote(_ snapshot: SnapshotResponse) -> String {
        guard snapshot.elements.isEmpty else { return "" }
        return "note: the element list is empty — the app published no accessibility element at"
            + " all. That is almost always a screen mid-transition (or one that has not finished"
            + " loading), not an empty screen: read it again with ft_snapshot waitFor set to"
            + " something the destination has, and check ft_screenshot if it stays empty.\n"
    }

    /// **打ち切りは先頭でも言う**。`(+91 elements truncated)` は render の末尾に
    /// 1行出るだけで、120 行の一覧のいちばん下にあった —— 実測(Apple マップの経路プランナー)で
    /// **候補 211 件中 91 件が木から落ちて**いたのに、いちばん重い事実がいちばん読まれない位置に
    /// あった。打ち切りは描画の省略ではなく配列からの脱落なので、`waitFor` も `scrollTo` も
    /// 落ちた要素を一生探し続ける。
    ///
    /// **何が落ちたかはブリッジしか知らない**ので、申告があるときだけ内訳を添える
    /// (`SnapshotResponse.truncatedTiers`。無い = 旧ブリッジなら件数だけ)
    static func truncationNote(_ snapshot: SnapshotResponse) -> String {
        guard snapshot.truncatedCount > 0 else { return "" }
        let breakdown = snapshot.truncatedTiers.map { tiers -> String in
            let parts = SnapshotResponse.truncatedTierOrder.compactMap { tier -> String? in
                guard let count = tiers[tier.key], count > 0 else { return nil }
                return "\(count) \(tier.label)"
            }
            return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        } ?? ""
        // **逃げ道を必ず添える**(ブラウザ監査): 「画面を狭くする」という助言だけでは
        // web ページでは実行できない(シートも大きなリストも無い ——
        // 1ドキュメントぶんの要素が最初から全部載っている)。実測では tenki.jp の2週間天気で
        // **落ちた 179 件が全部 labelled = 表の本文**で、`ft_scroll_to` が2回で 101 秒を捨てた。
        // 順序は「上限を上げる」が先: 落ちた行がまさに読みたい物である確率が高い
        // 逃げ道の判定は `FTCore.SnapshotTruncation.remedy`(DSL と共有)。**天井まで来ていたら
        // 「上限を上げろ」と言わない** —— 言われたとおり上げても同じ木が返るのが最悪。
        // `remedy` が nil を返すのは `truncatedCount == 0` のときだけで、それは上のガードで
        // 既に排除済み。ここでは到達しない = 渡すのは Remedy の2ケースだけでよい
        guard let remedy = SnapshotTruncation.remedy(for: snapshot) else { return "" }
        let escape = truncationEscape(remedy, for: .note)
        return "note: \(snapshot.truncatedCount) element(s) were dropped by the snapshot limit"
            + "\(breakdown) — they are gone from the tree, not just hidden, so waitFor/ft_scroll_to"
            + " will never find them. \(escape)\(capHogNote(snapshot))\n"
    }

    /// 上限の外で bulk を送ったときの注記(61)。
    ///
    /// **「一覧が上限を超えているのは異常ではない」と言うためにある**: 読み手は
    /// `maxSnapshotElements` を知らないので、120 を超える一覧を見て木が壊れていると読む余地がある。
    /// 同時に「畳まれた群は枠を食っていない」= 打ち切りの原因ではないことも伝わる。
    /// **申告が無いブリッジ(旧版・Android)では黙る** —— 嘘の安心を出さない
    static func bulkExemptNote(_ snapshot: SnapshotResponse, abbreviated: Bool = false) -> String {
        guard let count = snapshot.bulkExemptCount, count > 0 else { return "" }
        // **「無害」と読ませない**: 元の文言は要素上限を守っていることしか言わず、
        // これらの行がコンテキストを消費している事実が伝わらなかった。
        // **満額は初回だけ**(監査。`abbreviated` は他の注記と同じ F-6 の仕組み):
        // 実体は木の1行に畳まれているのに、注記のほうが長いという逆転が毎回の応答で起きていた。
        // 伝えたい2点(枠を食っていない/出力は食う)は一度読めば足りる
        // **2回目以降は何も言わない**: 木の畳み行(`×N … collapsed`)が同じ事実を毎回言っており、短縮形は重複だった(計測で指摘)
        guard !abbreviated else { return "" }
        return "note: \(count) element(s) of large same-id group(s) are listed outside the"
            + " element limit — they did not crowd other elements out of the tree, but they do"
            + " add to this output; the rendering folds them (expandBulk lists them in full).\n"
    }

    /// 打ち切ったときだけ添える「枠を食っている当人」。
    ///
    /// **間引きの方針では直せないから、代わりに名指しする**: 同一 id の地図 POI が
    /// 上限の過半を占めることは実際にある(実測: Apple マップの経路プランナーで 77/120)が、
    /// 「大きな同一 id 群を先に捨てる」は**リストの行にも同じだけ当たる**ので採れない
    /// (BridgeSnapshotThinning.bulkGroupMinimum の却下理由)。読み手にできる手は
    /// 「その群が出ない画面にする」= 地図を畳む・シートを閉じるなので、**どれが原因かだけ**言う
    static func capHogNote(_ snapshot: SnapshotResponse) -> String {
        var counts: [String: Int] = [:]
        for e in snapshot.elements {
            guard let id = e.identifier, !id.isEmpty else { continue }
            counts[id, default: 0] += 1
        }
        guard let (id, count) = counts.max(by: { $0.value < $1.value }),
              count >= SnapshotRenderer.bulkGroupMinimum else { return "" }
        let share = count * 100 / max(1, snapshot.elements.count)
        return " #\(id) alone accounts for \(count) of the \(snapshot.elements.count) kept"
            + " element(s) (\(share)%) — collapsing whatever draws it (a map, a long list)"
            + " frees the most room."
    }

    /// キーボード下に隠れた操作対象。木からは判定できない(キーボードはスナップショットの対象外)
    /// ので、ブリッジ申告の `keyboardFrame` でだけ言える(判定は RefGuard.keyboardWarning と共有)。
    /// 実測(iOS): キーボード下の候補行 ref タップが警告なしで顔文字キーに当たった。
    /// **見出しに出す座標は広げた実効矩形のまま**(申告のまま出すと判定と表示が食い違い、
    /// 読み手が検算できない)。**列挙は chrome 自身とその部分木を除く**(地球儀キー・変換候補
    /// バー等は覆っている側であり、覆われているとは言えない)。
    /// **Android adjustResize では覆われた要素が木から消える**(実測・Pixel 4a:
    /// パスワード欄フォーカスで窓 2340→1267px・送信/クリアが木から脱落)ため、
    /// `covered.isEmpty` を「下に何も無い」と読むと誤った安心になる ——
    /// `windowResizedAboveKeyboard` で分岐する
    static func keyboardCoverageNote(_ snapshot: SnapshotResponse) -> String {
        let occlusion = KeyboardOcclusion.resolve(reported: snapshot.keyboardFrame, in: snapshot.elements, screen: snapshot.screen)
        guard let kb = occlusion.frame else { return "" }
        let header = "the soft keyboard covers"
            + " (\(Int(kb.x)),\(Int(kb.y)) \(Int(kb.width))x\(Int(kb.height)))"
        // **入力欄も数える**(キーボードの下に隠れる代表が入力欄。interactiveTypes はタップの受け手だけで入力欄を含まない)
        let covered = snapshot.elements.filter {
            (RefGuard.interactiveTypes.contains($0.type) || TypeReadback.isTextInput($0)) && occlusion.covers($0)
        }
        guard !covered.isEmpty else {
            if occlusion.windowResizedAboveKeyboard {
                return "note: \(header); the window has shrunk to fit above it, so whatever sat"
                    + " below the keyboard is gone from this tree rather than listed beneath it —"
                    + " close the keyboard (ft_navigate back on Android) or scroll inside the"
                    + " container to reach it\n"
            }
            return "note: \(header); nothing tappable is beneath it\n"
        }
        let listed = covered.prefix(8).map { "[\($0.ref)] \(RefGuard.describe($0))" }
            .joined(separator: " ")
        let more = covered.count > 8 ? " (+\(covered.count - 8) more)" : ""
        return "note: \(header). \(covered.count) listed element(s) are beneath it and a tap would"
            + " hit the keyboard instead: \(listed)\(more)\n"
    }

    /// ラベル付きだが極端に細い要素(掴めないほど狭い可能性)。
    /// 判定は RefGuard.isClippedSliver = DSL(TapTargetGeometry)と共有。
    /// 判定は要素自身の細さだけ(縁で切れたかは見ない)。
    /// **列挙は操作可能型(operableTypes)に限る**: 文言が「タップに失敗するかも」
    /// なので、タップ対象にならない image/staticText に出すと空振りの注意になる(実測:
    /// 画面下端で 84x9 に切れた「IC 運賃」アイコン)。判定自体は共有のまま型を問わない
    static func sliverNote(_ snapshot: SnapshotResponse) -> String {
        let slivers = snapshot.elements.filter {
            RefGuard.isClippedSliver($0, screen: snapshot.screen)
                && BridgeSnapshotThinning.operableTypes.contains($0.type)
        }
        guard !slivers.isEmpty else { return "" }
        let listed = slivers.prefix(8).map { "[\($0.ref)] \(RefGuard.describe($0))" }
            .joined(separator: " ")
        let more = slivers.count > 8 ? " (+\(slivers.count - 8) more)" : ""
        return "note: \(slivers.count) element(s) are extremely thin with a label"
            + " (≤10 wide/tall, or ≤14 wide/tall and flush against the screen edge)"
            + " — the strip may be too thin to tap, whether clipped at an edge"
            + " or just narrow by design: \(listed)\(more)\n"
    }

    /// 座標ピンチの既定の半径 = 画面の短辺のこの割合。**画面相対**なのは、座標系が
    /// iOS=pt(短辺 402)/ Android=px(短辺 1080)で桁が違うため —— 固定値にすると
    /// 片方で指が開かず、もう片方で画面をはみ出す
    static let pinchRadiusScreenRatio = 0.22
    static let pinchRadiusFallback: Double = 100

    /// **Android の座標ピンチの既定半径は、指の最大間隔が最小スケール距離を超えるように広げる**
    /// (§19 M5: 既定 238 px = 間隔 428 px は 440 dpi の 27 mm = 468 px を下回り、一切ズームしない)。
    /// ブリッジは領域の短辺 × 0.9 を最大間隔にする(AndroidRunner BridgeRouter.handlePinch)ので、
    /// 間隔が `minimumSpan × headroom` に届く半径 = `minimumSpan × headroom / (2 × 0.9)`。
    /// headroom は「超えた分だけがスケールとして数えられる」ための余裕(1.25 = 25%)。
    /// 明示の `radius` には触らない(呼び手の指定を黙って変えない)
    static let pinchSpanHeadroom = 1.25
    static let bridgePinchSpanRatio = 0.9
    static func pinchRadiusHonouringMinimumSpan(defaultRadius: Double, minimumSpan: Double?) -> Double {
        guard let minimumSpan, minimumSpan > 0 else { return defaultRadius }
        return max(defaultRadius, (minimumSpan * pinchSpanHeadroom / (2 * bridgePinchSpanRatio)).rounded(.up))
    }

    /// (x,y) を中心にした正方形の対象領域。**画面が分かるなら内側へ収める** ——
    /// 画面外へはみ出した指はタッチとして届かず、要求より小さいズームになる。
    /// 収め方は**中心を動かさず半径を縮める**(中心を寄せるとズームの支点が変わり、
    /// 「この地点を拡大したい」という指定そのものが崩れる)。縁ぎわの指定では
    /// 指の開きが小さくなるぶん倍率が出にくい
    static func pinchArea(x: Double, y: Double, radius: Double?, screen: FTRect?) -> FTRect {
        var r = radius ?? screen.map { min($0.width, $0.height) * pinchRadiusScreenRatio }
            ?? pinchRadiusFallback
        if let screen, screen.width > 0, screen.height > 0 {
            let room = [x - screen.x, screen.x + screen.width - x,
                        y - screen.y, screen.y + screen.height - y].min() ?? r
            r = max(1, min(r, room))
        }
        return FTRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
    }

    /// DSL の pressEnter(StepExecutor+Actions.swift)と値を共有 — FTCore.FocusWait が唯一の定義元
    static let focusWaitSeconds = FocusWait.waitSeconds
    static let focusPollSeconds = FocusWait.pollSeconds

    /// **座標が画面外なら撃たずに拒否する**(実測)。in-app ブリッジは
    /// 「その点を含む最小の frame」を撃つだけで、点そのものが画面の中かは見ない
    /// (`InAppBridge.swift` の tap/press ハンドラ)。木は画面外にも要素を持つことがある
    /// (折り返しの下・別タブの隠れた行 等)ので、画面外の座標はその**実在する**見えない要素を
    /// 実際に押してしまう(実測: (201, 900) で画面外の `#nav_diagnostics` が押されて遷移した)。
    ///
    /// **screen が分からないときは撃つ**(旧ブリッジ等で screen が 0 の形)—— 「分からない」を
    /// 「外れている」と読むと、画面を知らないだけの正常な呼び出しまで拒否することになる。
    /// ただし**「まだ ft_snapshot を撮っていない」は分からないうちに入れない**: 呼び手は
    /// `coordinateScreen` で直近の木の screen を採り、無ければ1枚読んでから判定する
    /// (snapshot 前の `tap (5000, -20)` が done になっていた = §19 M4)。
    ///
    /// **縁は外**(`<`): 幅 1080 の画面で x=1080 は画素の外(0…1079)。iOS の pt も同じ。
    /// 含み側にすると `(1080, 2220)` が done になる(§19 M4・担当)
    /// MCP の iOS は常に XCUITest なので、in-app の当たり判定を理由に挙げない(木は画面外にも要素を持つ
    /// ことがある、という事実は engine を問わず有効)
    static func offscreenCoordinateError(x: Double, y: Double, screen: FTRect?,
                                         engine: String?) -> MCPError? {
        // **判定は TapTargetGeometry.isPointOnScreen の1箇所**(ライブ操作の座標コマンドと共有。
        // LiveControlExitParityTests.sharedJudgements が両側の配線を固定する。screen が nil/幅高さ0
        // のときは isPointOnScreen が true を返すので、そのまま nil で抜ける)
        guard let screen, !TapTargetGeometry.isPointOnScreen(x: x, y: y, screen: screen) else {
            return nil
        }
        let reason = "The tree can include elements that are off-screen, so"
        return MCPError("(\(x), \(y)) is outside the screen (\(FTSeconds.format(screen.width))"
            + "x\(FTSeconds.format(screen.height)), origin \(FTSeconds.format(screen.x)),"
            + "\(FTSeconds.format(screen.y))) — refusing to fire. \(reason) an offscreen"
            + " coordinate can land on a real, offscreen element (e.g. a tab below the fold,"
            + " or a row still in the tree from a previous screen). Take a fresh ft_snapshot"
            + " and pass an in-bounds coordinate, or use a ref instead.")
    }

    /// **座標がソフトキーボードの中にある**ときの警告(ft_tap / ft_double_tap / ft_long_press の座標形)。
    /// ref 形は RefGuard.keyboardWarning が言うのに、座標形は無警告で done と返し、実機 Pixel 3a では
    /// 欄にスペースが入った(§19 担当報告の再現)。**拒否はしない**(キーそのものを押す意図があり得る)。
    /// 判定は直近の木の申告(`KeyboardOcclusion` = ref 形・DSL と同じ型)。木が無ければ黙る
    func keyboardCoordinateWarning(x: Double, y: Double, args: [String: Any]) -> String {
        guard let snapshot = lastSnapshots[Self.engineKey(args)] else { return "" }
        let occlusion = KeyboardOcclusion.resolve(reported: snapshot.keyboardFrame, in: snapshot.elements, screen: snapshot.screen)
        guard let frame = occlusion.frame,
              x >= frame.x, x < frame.x + frame.width, y >= frame.y, y < frame.y + frame.height
        else { return "" }
        return " (warning: (\(FTSeconds.format(x)), \(FTSeconds.format(y))) is inside the soft keyboard"
            + " (\(FTSeconds.format(frame.x)),\(FTSeconds.format(frame.y)) \(FTSeconds.format(frame.width))x"
            + "\(FTSeconds.format(frame.height))) — this presses a key, not the app behind it. Dismiss the"
            + " keyboard first (pressEnter, or ft_navigate back on Android) unless a key was meant)"
    }

    /// **座標で撃つ操作の前に、このセッションが起動したアプリが前面かを確かめる**警告。ref の操作は
    /// 撮り直した木で「前面が別アプリ」と断る(verifiedRef)が、座標の操作は木を読まないので、`back` で
    /// アプリを抜けた後のタップ・スワイプがランチャーや他のアプリへ黙って届いた(実機 Pixel で実測 →
    /// maintainer-notes §60)。**断らない**(ホーム画面を座標で触る意図があり得る)。
    /// 撃つ**前**に読む(その操作自身がアプリを離れた回に警告しない)。
    /// **判定材料が無いときは黙る**: ft_launch していない・ドライバが前面のアプリ名を答えない。
    /// **iOS には問い合わせない**(`foregroundAppID` は通信せず nil)—— XCUITest のランナーは前面に無い
    /// アプリへのジェスチャを自分で断り、in-app は前面から外れると撃てないので、届くのは Android だけ。
    /// 権限ダイアログ(`systemDialogPackages`)は座標で押すのが正規の操作なので黙る
    static func frontAppWarning(launched: String, front: String?) -> String {
        guard let front, front != launched, !systemDialogPackages.contains(front) else { return "" }
        return " (warning: \(front) was in front, not \(launched) (the app this session launched)"
            + " — this acted on \(front). ft_launch \(launched) to come back, or ft_snapshot to see"
            + " what is on screen)"
    }

    func coordinateFrontAppWarning(_ driver: AppDriver, args: [String: Any]) async -> String {
        guard let launched = launchedBundleIDs[Self.engineKey(args)] else { return "" }
        return Self.frontAppWarning(launched: launched, front: (try? await driver.foregroundAppID()) ?? nil)
    }

    /// 座標の操作が画面の範囲を知るための screen。直近の木があればそれ(追加の読みは払わない)、
    /// 無ければ控え(`knownScreens`)、それも無ければ**1枚生読みして控える**(セッション最初の
    /// 座標操作だけ。読めなければ nil = 撃つ側)。**生読み = 世代を作らない**(knownScreens の doc)。
    /// 回転は ft_rotate が木を記録するので lastSnapshots 側が勝つ
    func coordinateScreen(_ driver: AppDriver, args: [String: Any]) async -> FTRect? {
        let key = Self.engineKey(args)
        if let screen = lastSnapshots[key]?.screen { return screen }
        if let screen = knownScreens[key] { return screen }
        guard let screen = (try? await driver.snapshot(bypassingCache: driver.supportsCacheBypass))?.screen
        else { return nil }
        knownScreens[key] = screen
        return screen
    }
}
