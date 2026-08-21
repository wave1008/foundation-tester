// ステップに付く注記のうち、**run を跨いで数えたいもの**の定義。
//
// 表示文言(driverFallback → ステップ説明の括弧書き)と機械可読コードを1箇所から供給する。
// 文言をリテラルで散らして集計を文字列一致で作ると、**文言を書き換えた瞬間に集計が静かに 0 件になる**
// (検知として最悪の壊れ方 = 「問題が無い」と「測れていない」が区別できない)。
//
// 運搬経路: StepExecutor.noteCodesThisStep → StepOutcome.notes → FTRuntime.recordStep
//   → ScenarioEvent.notes → ScenarioRecordBuilder → TimelineStepRecord.notes(results/ に永続化)
// どちらの DTO でも Optional の後発追加なので旧レコードは decode できる = ProtocolVersion の +1 は不要。

import Foundation

/// ステップ 1 回に付く機械可読な注記。**失敗ではない**が run 横断で率を見たいものだけを置く
/// (毎回出る注記を足しても集計の役に立たない)。
public enum StepNote: String, Sendable, Codable, CaseIterable {
    /// 整定の収束判定がポーリング上限で打ち切られ、**画面が動いたまま先へ進んだ**。
    /// 赤になる前の先行指標: ここが増えている状態で構造的な高速化を入れると、
    /// フレーク率の上昇として遅れて現れる(docs/performance-tuning.md の採用ゲート)。
    /// 探索の終端で出る場合だけ文言が変わる(`StepExecutor.scrollSearchNote`)が**コードは同じ**
    case settleCapped = "settle-capped"

    /// 掴んだ値だけでアサートを満たし、デバイスを 1 度も見なかった(FTRuntime の高速経路)。
    /// このステップは durationMs=0 で記録されるため、**内訳の母数から抜ける**。
    /// 「速くなったのは実装のおかげか、この経路の当たり率が上がっただけか」を切り分けるために数える
    case heldValue = "held-value"

    /// `scrollFrame` が明示されているのに探索開始時点(または探索中)の snapshot で
    /// 1件も解決できず、**スワイプを1本も送らずに**探索を打ち切った。MCP(RefGuard 経由ではなく
    /// StepOutcome.notes 経由)がこのコードで fail-fast 専用の文へ分岐する。
    /// 実測(2026-08-08・Apple マップ): 申告した容器がツリーから消え、黙った全画面スワイプへ
    /// 退化してカードの「計画」ボタンを誤発火させた
    case scrollFrameMissing = "scroll-frame-missing"

    /// 探索が「内容が動かない」で打ち切られ、そのときの容器が**画面高の80%未満**だった
    /// = 半開きのボトムシートの中を探していた公算が高い(2026-08-09)。
    /// 文言側の同じ判定(`StepExecutor.scrollNotFoundMessage` のシート展開ヒント)を
    /// 機械可読にしたもので、**MCP はこのコードでシートを広げて1度だけ再試行する** ——
    /// 文字列一致で分岐すると、文言を書き換えた瞬間に静かに効かなくなる(このファイル冒頭の理由)
    case sheetCollapsed = "sheet-collapsed"

    /// occlusion-guard のスクショが凍結フレーム疑い(StaleFrameDetector.judge)で、撮り直しても
    /// なお木指紋と食い違わなかった。古い絵を根拠に FM の偽陽性反転を宣言しないための素通り
    /// (StepExecutor+Assert.swift の occlusionFlip)
    case staleScreenshot = "stale-screenshot"

    /// 探索のどこか1周で木が**要素上限で打ち切られていた**。実在する行が候補から
    /// 落ちていた可能性があるので、「見つからない」を不在の証拠にしてはいけない。
    /// **最終木では消えている情報**(ScrollSearchResult.maxTruncatedDuringSearch 参照)なので
    /// 注記として運ぶ。MCP はこのコードで上限引き上げの案内を足す
    case truncatedDuringSearch = "truncated-during-search"

    /// 委譲した WebView が**中身を1つも出さないまま待ちの上限に達した**木で判定した(2026-08-15)。
    /// 木からは「AX がまだ公開されていない」と「本当に空のページ」を区別できないので判定は変えないが、
    /// **黙るとこの木で成立した不在が後から見分けられない**(否定アサーションは空の木で必ず通る)。
    /// 上限は Simulator の実測 2.3s に対する余裕で、hybrid は実機でも動く =
    /// 尽きること自体が想定内(`WebViewDelegatingDriver.contentWaitMs`)。
    /// 率が上がっていたら上限か画面の作りを疑う
    case webViewNotRendered = "webview-not-rendered"

    /// 否定判定に使った木が**画面を代表していない疑い**があった(`FTCore.TreeCoverage`。
    /// webView の内側に大きな空白帯が残る / アドレス欄はあるのにページ本体が1要素も無い)。
    /// 打ち切り(`truncatedDuringSearch`)と失敗の型は同じだが、あちらはブリッジの申告に基づく
    /// 事実、こちらは**幾何からの疑い**なので判定は変えず注記だけにする ——
    /// 断定すると空のページに対する正当な `notExist` が書けなくなる。
    /// **率が上がったらブラウザの a11y 公開待ちを疑う**(木の構築中に撮ると chrome しか返らない)
    case treeUnderreported = "tree-underreported"

    /// 掴んだ要素が**同じ領域の2つ目のコピー**の中に居た(`FTCore.DuplicateRegion`。
    /// 横スクロールした容器の前後のコピーが両方 木に残る形)。片方は画面に描かれていないので、
    /// 撃っても何も起きないか、いま そこに描かれている別の要素へ当たる。
    /// **どちらのコピーが生きているかは木から決められない**(座標は両方それらしい)ので
    /// 操作は止めず注記だけにする —— MCP の `duplicateRegionNote` と同じ判定。
    /// **率が上がったら横スクロール直後の整定を疑う**
    case staleDuplicateRegion = "stale-duplicate-region"

    /// back() の前後で木の指紋が同一 = システム back がこの画面に効かなかった(自前ナビの画面が
    /// システムの戻るを無視するアプリでよくある)。判定は FTCore.BackEffect が唯一の定義元
    /// (MCP の ft_navigate と共有)。before/after とも back() 1回につき1枚ずつ素直に読む
    /// (使い回しキャッシュを持たない理由は BackEffect.swift 参照)
    case backIneffective = "back-ineffective"

    /// 自己修復が代わりの要素を見つけたのに、**この画面でそれを一意に指せる書き方が無い**
    /// (`SelectorNaming.graded` が nil)。操作はその要素で続けるが、修正提案もヒールキャッシュも
    /// 作らない —— 書けないセレクタを利用者の .swift へ書き戻さないため
    /// (`ftester api apply-heal` が直接書き込む経路がある)。
    /// **率が上がったら id/ラベルの一意性を疑う**: この状態が続く限り毎回 FM を呼び直す
    case healUnwritable = "heal-unwritable"

    /// このステップの途中で**宣言済みの割り込み**(`irregularHandler`)を実際に閉じた。
    /// 失敗の読み解きに要る事実 —— 割り込みは直前に送った操作を吸うことがあるので、
    /// 「閉じたステップが落ちた」と「もともと落ちるステップだった」を読み手が分けられる。
    /// **文言は動的**(閉じたセレクタと回数を含む)ため `note(_:into:)` は通さず、
    /// StepExecutor.dismissInterruption がコードだけ立てる(text は集計表示用の既定文)
    case interruptionDismissed = "interruption-dismissed"

    /// `tap(入力欄)` → `type("文字列")` の並びで、**タップが焦点を立てられていなかった**ので
    /// ツールが入力欄を名指しして入れ直した(`InputFocusRescue`)。
    /// **率を見たい注記**: 増えているなら、その画面の入力欄は容器と中身に分かれていて
    /// `#id` が容器を指している(セレクタを取る `type` へ寄せる判断材料になる)
    case typeFocusRecovered = "type-focus-recovered"

    /// OS のシステム UI(権限アラート等)がアプリを覆っていたので、**消えるまで待ってから**
    /// 操作した(`SystemUIGate`)。**率を見たい注記**: 増えているなら、そのシナリオは
    /// 権限を事前付与するか `iosAlertHandler` を登録するべき画面を通っている
    case waitedForSystemUI = "waited-for-system-ui"

    /// `tap` の対象が**まだ無効**だったので、操作可能になるまで待ってから撃った。
    /// **率を見たい注記**: 増えている画面は「出た直後はまだ触れない」ので、
    /// 到達待ちの書き方(`waitForDisplay` の対象)を見直す材料になる
    case waitedForEnabled = "waited-for-enabled"

    /// 人間向けの文言(FTRuntime がステップ説明へ括弧書きで付ける)
    public var text: String {
        switch self {
        case .settleCapped: return "the screen did not settle (poll limit)"
        case .heldValue: return "from the grabbed value"
        case .scrollFrameMissing: return "the scrollFrame did not resolve, so the search stopped early"
        case .sheetCollapsed: return "the list stopped moving inside a partially open sheet"
        case .staleScreenshot: return "the occlusion-guard screenshot looked stale, so the check was skipped"
        case .truncatedDuringSearch:
            return "the tree hit the element limit during the search, so the target may have been dropped from it"
        case .webViewNotRendered:
            return "the delegated WebView had published no content when this was judged, so an absence here is not evidence"
        case .staleDuplicateRegion:
            return "the tree listed this element's row twice (a horizontally-scrolled region left"
                + " both copies behind), so this may have hit the copy that is no longer drawn"
        case .treeUnderreported:
            return "the tree did not appear to cover the whole screen when this was judged, so an"
                + " absence here is not evidence"
        case .backIneffective: return BackEffect.note(advice: BackEffect.dslAdvice)
        case .interruptionDismissed: return "dismissed a declared interruption during this step"
        case .waitedForEnabled:
            return "the target was still disabled, so the tap waited for it to become enabled"
        case .waitedForSystemUI:
            return "system UI was covering the app, so this waited for it to go away before acting"
        case .typeFocusRecovered:
            return "the preceding tap did not put a field in focus, so the text went to the"
                + " field it resolved to"
        case .healUnwritable:
            return "self-heal found a stand-in element but no selector picks it out uniquely on this"
                + " screen, so the fix was not written back — give the element a stable id"
        }
    }
}
