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
    /// = 半開きのボトムシートの中を探していた公算が高い。
    /// 文言側の同じ判定(`StepExecutor.scrollNotFoundMessage` のシート展開ヒント)を
    /// 機械可読にしたもので、**MCP はこのコードでシートを広げて1度だけ再試行する** ——
    /// 文字列一致で分岐すると、文言を書き換えた瞬間に静かに効かなくなる(このファイル冒頭の理由)
    case sheetCollapsed = "sheet-collapsed"

    /// occlusion-guard のスクショが凍結フレーム疑い(StaleFrameDetector.judge)で、撮り直しても
    /// なお木指紋と食い違わなかった。古い絵を根拠に FM の誤った緑反転を宣言しないための素通り
    /// (StepExecutor+Assert.swift の occlusionFlip)
    case staleScreenshot = "stale-screenshot"

    /// 探索のどこか1周で木が**要素上限で打ち切られていた**。実在する行が候補から
    /// 落ちていた可能性があるので、「見つからない」を不在の証拠にしてはいけない。
    /// **最終木では消えている情報**(ScrollSearchResult.maxTruncatedDuringSearch 参照)なので
    /// 注記として運ぶ。MCP はこのコードで上限引き上げの案内を足す
    case truncatedDuringSearch = "truncated-during-search"

    /// 委譲した WebView が**中身を1つも出さないまま待ちの上限に達した**木で判定した。
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
    /// **WebView の中身を読めなかった木で判定した**。読めなかった理由はブリッジの申告
    /// (snapshot の note)にあり、`webview-not-rendered` が「委譲したが空だった」なのに対し
    /// こちらは「DOM を読む前に諦めた」。どちらも**不在の証拠にならない木**である点は同じ
    case webViewUnread = "webview-unread"
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
    /// (`fleetest api apply-heal` が直接書き込む経路がある)。
    /// **率が上がったら id/ラベルの一意性を疑う**: この状態が続く限り毎回 FM を呼び直す
    case healUnwritable = "heal-unwritable"

    /// 自己修復が提案を返したのに、confidence が `high` に届かず**採用しなかった**
    /// (採用基準は `StepExecutor+Actions.swift` の healLocator 分岐のものを1バイトも変えない ——
    /// ここは観測できる形にするためだけの注記)。**黙ると「FM が探して見つからなかった」と
    /// 「FM は答えを持っていたが使わなかった」が失敗文言の上で見分けられなくなる**
    /// (2026-09-02 実測: medium の提案が正解の #id を出していたのに `cannot resolve the locator`
    /// としか出ず、triage を読まない限り気付けなかった)。
    /// **率が上がったら閾値を疑うのではなく提案の質(木の情報量・instructions)を疑う**
    case healProposalRejected = "heal-proposal-rejected"

    /// 自己修復は FM を呼べたのに、**その生テキストが木のどの要素にも一致しなかった**
    /// (`resolveByText` が nil)。`healProposalRejected` とは別の経路 —— あちらは「答えはあったが
    /// confidence 不足で採用しなかった」、こちらは「答えを要素へそもそも引き戻せなかった」。
    /// **黙ると原因が推測でしか語れない**(2026-09-02 実測: heal calls=1/failures=0 なのに
    /// `cannot resolve the locator` としか出ず、モデルが実際に何を返したかが結果 JSON からも
    /// 失敗文言からも読めなかった)。生の答えは失敗文言側で運ぶ(`unresolvedHealAnswerHint`)。
    /// **率が上がったら `resolveByText` の正規化(引用符・`#`・言語混在)を疑う**
    case healAnswerUnresolved = "heal-answer-unresolved"

    /// 自己修復は FM を呼べ、モデルは要素一覧を見たうえで**「妥当な代わりが無い」と判断した**
    /// (`LocatorRepairSuggestion.elementText` が nil。`resolveByText` にすら回っていない)。
    /// `healAnswerUnresolved`(モデルは何か名指ししたが木のどの要素にも一致しなかった=答えの質の
    /// 問題)とは別の経路 —— こちらはモデルが一覧を検討したうえで出した正常な結論で、
    /// 要素が本当に消えている場合はこれが正解になる(2026-09-02 実測: 存在しない要素をわざと叩く
    /// 陽性対照シナリオで、`elementText` が非オプショナルだったため選択肢が無く、モデルが無関係な
    /// 要素を medium confidence で提案していた)。
    /// **率が上がったこと自体は異常ではない** —— 率を見るなら「本当に消えている」件数との対比で見る
    case healNoReplacement = "heal-no-replacement"

    /// ロケータが未解決のとき、**前回このロケータが解決できた要素の属性(type+label)**で
    /// 現在の木を照合し、一致がちょうど1件だけだったので FM を経由せず決定的に解決した
    /// (`LocatorFingerprint`)。id はドリフトで変わる本人なので照合材料にせず、value は
    /// 実行ごとに変わるので控えない。**複数件一致したら不採用**(採ると別要素へ静かに解決し、
    /// 後段の検証が別要素を見て誤った緑・誤った赤を作る)。書けるセレクタが無ければ
    /// `healUnwritable` も併せて立つ。
    /// **率を見たい注記**: 増えているなら、その画面は id のリネーム(ドリフト)が起きている
    case healFingerprintMatch = "heal-fingerprint-match"

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

    /// 可視性照合(`requireVisible`。実行プロファイル `falsePositiveCheck` で有効)が **FM まで
    /// 到達したのに判定が返らなかった**(実呼び出しの失敗・ブレーカ開・直列化待ちの期限切れ・
    /// 画像の不正)。このステップは幾何の Tier-0(中心が画面外でないこと)だけで通っている。
    /// **立てるのは FM に訊いた回だけ** —— マスタースイッチ OFF・macOS 26・インクゲートで
    /// 省いた回は「訊く必要が無かった」のであって skip ではない(毎回出る注記にしない)。
    /// run 横断で率を見ると**環境側の FM 不調**が拾える(2026-08-20 受け手報告: availability は
    /// available なのに実呼び出しが ModelManagerError(1001) で落ち、可視判定が黙って通っていた)
    case visibilityGuardSkipped = "visibility-guard-skipped"

    /// **`iosAlertHandler` の登録が無い**のに、OS のシステムアラートがアプリの前面に出ていた
    /// (SpringBoard への1問 `GET /systemalert` で確認した事実)。in-app の操作は OS のイベント経路を
    /// 通らないので**背面のアプリに届いてしまう** = 人手では不可能な操作が通る(受け手報告 2026-08-22)。
    /// 聞くのは安い契機だけ: ①launch 系の直後の最初の触る操作 ②ステップが失敗したとき(1回ずつ)。
    /// 常時監視はしない(登録がある間の毎ステップの往復は SystemUIGate が別に担う)。
    /// 判定は変えず注記(+ 失敗文言に題名)に留める —— 閉じるのはシナリオの責務のまま。
    /// **率が上がったら登録漏れ**: 文言に出る題名とボタンをそのまま iosAlertHandler に書ける
    case systemAlertPresent = "system-alert-present"

    /// launch 直後の occlusion-guard 失敗が launch storyboard(crop が全画素同一)由来と
    /// 判定され、このステップの deadline を一度だけ延ばして待ち直した(`StepExecutor.firstFrameGatePending`。
    /// 一度きりの門なので同じ launch のぶんでは他のステップに重複しない)。
    /// **率が上がったら**このアプリのスプラッシュ/起動遷移が長い ——
    /// 待ってもなお赤なら `firstFrameTimeout` を併せて見る
    case firstFramePending = "first-frame-pending"

    /// `firstFramePending` で一度延ばした deadline でもなお crop が一様色のままで、
    /// occlusion 失敗として赤になった。**判定は変えない**(延長を使い切っただけ) ——
    /// 起動が既定 timeout の2倍を超えて掛かっているか、launch storyboard ではなく
    /// 本物の occlusion(不透明な起動画面が居座っている等)を疑う材料
    case firstFrameTimeout = "first-frame-timeout"

    /// 実機の `clearAppData` を uninstall + install で代替した。**シミュレータとは意味が違う**
    /// (権限の付与も消え、次の起動で OS の権限アラートが出る)ので、所要と挙動の差が
    /// 報告から説明できるように残す。判定は `ReinstallSource`
    case reinstalledToClearData = "reinstalled-to-clear-data"

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
        case .webViewUnread:
            return "the WebView contents could not be read, so this tree does not represent the page"
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
        case .systemAlertPresent:
            return "a system alert was in front of the app with no iosAlertHandler registered for it,"
                + " so the app behind it was operated anyway"
        case .firstFramePending:
            return "the screen still looked like the launch storyboard (a uniform, undrawn frame),"
                + " so this waited once more before treating it as occlusion"
        case .firstFrameTimeout:
            return "the screen still looked like the launch storyboard after waiting once more,"
                + " so this failed as occlusion"
        case .reinstalledToClearData:
            return "a physical device has no clearAppData, so the app was reinstalled instead —"
                + " permission grants are reset too, so the next launch can show system alerts"
        case .visibilityGuardSkipped:
            return "the FM visibility check gave no verdict, so this passed on tree presence and"
                + " on-screen geometry alone"
        case .healUnwritable:
            return "self-heal found a stand-in element but no selector picks it out uniquely on this"
                + " screen, so the fix was not written back — give the element a stable id"
        case .healProposalRejected:
            return "self-heal proposed a replacement but its confidence was not \"high\", so it was"
                + " not used and the locator was left unresolved"
        case .healAnswerUnresolved:
            return "self-heal got an answer from the model but it did not match any element in the" +
                " tree, so the locator was left unresolved"
        case .healNoReplacement:
            return "self-heal looked at the element list and concluded no element plays the same" +
                " role, so the locator was left unresolved"
        case .healFingerprintMatch:
            return "self-heal matched the previously-resolved element by its type and label" +
                " (locator fingerprint), with no FM call"
        }
    }
}
