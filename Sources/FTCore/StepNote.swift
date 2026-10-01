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
    /// 実測(Apple マップ): 申告した容器がツリーから消え、黙った全画面スワイプへ
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
    /// (StepExecutor+Assert.swift の occlusionFlip)。**古いと判定した絵とバイト同一の絵のままなら、次のステップでも立つ**
    /// (StaleFrameDetector.isKnownStale)。待ちのループを持つ検証(exists・テキスト比較)は、古い間は判定を見送らずに
    /// 待って撮り直し、**締め切りまで古いままだった回だけ**素通りする(追いついた絵で判定した回にも立つ)
    case staleScreenshot = "stale-screenshot"

    /// 「絵が古い」と判定した絵に、期待する文字が丸ごと描かれていたので古くないとみなして合格にした
    /// (木が絵より遅れて追いついた形。StepExecutor+Assert.swift の staleFrameShowsExpectedText)。
    /// 率を見るための注記で、立った回は stale-screenshot の待ちを払っていない
    case staleFrameTextVisible = "stale-frame-text-visible"

    /// テキストの視覚検証(occlusion-guard)か screenLooksLike のスクショがステータスバー以外真っ黒
    /// (`BlankFrameDetector.isBlackApartFromSystemBars`)。絵が撮れていない・表示が凍結した回で、FM も OCR も
    /// 「何も描かれていない」「一致しない」と読むので、判定不能として素通りする(赤にしない)
    case blankScreenshot = "blank-screenshot"
    /// テキストの視覚検証の対象が WebView の内側にあり、木の上では覆われていないのに、その文字の領域が絵では一色だった
    /// (`BlankFrameDetector.webViewCaptureMissed`)。WebView の層を取り逃した絵なので判定せずに素通りした(赤にしない)。
    /// 木に載らない覆い(ページ内の描画だけで隠す等)は見逃す —— 率を見る注記
    case webViewCaptureBlank = "webview-capture-blank"
    /// findImage / findImages / existImage のスクショのアプリの領域が一色(`BlankFrameDetector.isUnjudgeable`)だったので、照合せずに待って撮り直した
    /// (`FindImage.MatchError.blankScreenshot`・待ちの列は `FindImage.anomalyRetryDelays`)。戻らなければ失敗
    case blankScreenshotRetaken = "blank-screenshot-retaken"

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

    /// 自己修復(指紋照合)が代わりの要素を見つけたのに、**この画面でそれを一意に指せる書き方が無い**
    /// (`SelectorNaming.graded` が nil)。操作はその要素で続けるが、修正提案は作らない ——
    /// 書けないセレクタを利用者の .swift へ書き戻さないため
    /// (`fleetest api apply-heal` が直接書き込む経路がある)。
    /// **率が上がったら id/ラベルの一意性を疑う**
    case healUnwritable = "heal-unwritable"

    /// ロケータが未解決のとき、**前回このロケータが解決できた要素の属性(type+label)**で
    /// 現在の木を照合し、一致がちょうど1件だけだったので決定的に解決した
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

    /// 読み返しで**中央の文字が落ちていた**(`TypeReadback.Plan.retype`)ので、消してから全文を打ち直した
    /// (in-app 経路。XCUITest ランナーの打ち直しは OKResponse.note → driverFallback に出る)。
    /// **率を見たい注記**: 緑の run で増えるなら誤検知(本当は加工された入力を打ち直している)を疑う
    case typeRetyped = "type-retyped"

    /// 打ち直しても同じ形で欠けた(`TypeReadback.maxRetypes`)ので、アプリ側の加工とみなして受理した。
    /// `typeRetyped` と対で立つ。**これが立つ欄は打鍵の落ちではない** —— `textIs` で値を別途確かめる
    case typeRetypeAbandoned = "type-retype-abandoned"

    /// 読み返しの値が**入力の前から1文字も動かなかった**が、打った文字は欄の領域に描かれていた(OCR)ので、
    /// 欄の値が入力を映さないものとして追送せずに受理した(M3 SearchBar の iOS は value に説明文を出す。
    /// 追送すると入力が重複する)。**値そのものは読み返していない** —— 必要なら後段で確かめる
    case typeReadbackUnchanged = "type-readback-unchanged"

    /// `swipeBy` の比率が片側 `ScrollGeometry.maxPanRatio` を超えていたので丸めた(比率は対象の大きさに対する
    /// 割合)。**新しい検知なので警告から**。対象より遠くへ払いたい指定の書き誤り
    case swipeByRatioCapped = "swipe-by-ratio-capped"

    /// `launchApp(url:)` が、既定の待ち時間のあいだ**利用者が触れる要素が木に載らないまま** URL を配送した
    /// (LaunchURLReadiness)。触れる要素の無い最初の画面もあり得るので失敗にはしないが、React Native の
    /// ように JS が listener を登録するまで URL を捨てるアプリでは、この注記の付いた配送は届いていない疑いがある
    case launchURLBeforeInteractiveUI = "launch-url-before-interactive-ui"

    /// OS のシステム UI(権限アラート等)がアプリを覆っていたので、**消えるまで待ってから**
    /// 操作した(`SystemUIGate`)。**率を見たい注記**: 増えているなら、そのシナリオは
    /// 権限を事前付与するか `iosAlertHandler` を登録するべき画面を通っている
    case waitedForSystemUI = "waited-for-system-ui"

    /// `tap` の対象が**まだ無効**だったので、操作可能になるまで待ってから撃った。
    /// **率を見たい注記**: 増えている画面は「出た直後はまだ触れない」ので、
    /// 到達待ちの書き方(`waitForDisplay` の対象)を見直す材料になる
    case waitedForEnabled = "waited-for-enabled"

    /// 可視性照合(`requireVisible`。実行プロファイル `fmTextOcclusionCheck` で有効)が **FM まで
    /// 到達したのに判定が返らなかった**(実呼び出しの失敗・ブレーカ開・直列化待ちの期限切れ・
    /// 画像の不正)。このステップは幾何の Tier-0(中心が画面外でないこと)だけで通っている。
    /// **立てるのは FM に訊いた回だけ** —— マスタースイッチ OFF・macOS 26・インクゲートで
    /// 省いた回は「訊く必要が無かった」のであって skip ではない(毎回出る注記にしない)。
    /// run 横断で率を見ると**環境側の FM 不調**が拾える(受け手報告: availability は
    /// available なのに実呼び出しが ModelManagerError(1001) で落ち、可視判定が黙って通っていた)
    case visibilityGuardSkipped = "visibility-guard-skipped"

    /// occlusion-guard が緑と判定したが、読めた文字は期待文字列の先頭部分だけ(`TranscriptMatch.State.partiallyHidden`)。
    /// **率を見たい注記**: 増えているならレイアウトが要素を部分的に隠す構成(長いラベルが
    /// 隣の要素に隠れる等)を疑う
    case textPartiallyHidden = "text-partially-hidden"

    /// occlusion-guard が緑と判定し、読めた文字の末尾に省略記号があった(`TranscriptMatch.State.ellipsized`)。
    /// アプリの意図した省略なので判定は変えない —— 率を見ると省略表示の画面が分かる
    case textEllipsized = "text-ellipsized"

    /// occlusion-guard の OCR と FM の判定が割れ、**FM は見えないと言ったが OCR は期待の文字を読めた**ので
    /// 緑にした(見えていると読めた側を採る。docs/poc-fm-occlusion-guard.md §5.22)。
    /// **率を見たい注記**: 多ければ FM の書き起こしの取りこぼし、あるいは OCR が見逃しを作っている疑い
    case ocrReadWhatFMMissed = "ocr-read-what-fm-missed"

    /// occlusion-guard の OCR と FM の判定が割れ、**OCR は見えないと言ったが FM は期待の文字を読めた**ので
    /// 緑にした。多ければ OCR の読み違い(短い文字列・字形)を疑う
    case fmReadWhatOCRMissed = "fm-read-what-ocr-missed"


    /// **`iosAlertHandler` の登録が無い**のに、OS のシステムアラートがアプリの前面に出ていた
    /// (SpringBoard への1問 `GET /systemalert` で確認した事実)。in-app の操作は OS のイベント経路を
    /// 通らないので**背面のアプリに届いてしまう** = 人手では不可能な操作が通る(受け手報告)。
    /// 聞くのは安い契機だけ: ①launch 系の直後の最初の触る操作 ②ステップが失敗したとき(1回ずつ)。
    /// 常時監視はしない(登録がある間の毎ステップの往復は SystemUIGate が別に担う)。
    /// 判定は変えず注記(+ 失敗文言に題名)に留める —— 閉じるのはシナリオの責務のまま。
    /// **率が上がったら登録漏れ**: 文言に出る題名とボタンをそのまま iosAlertHandler に書ける
    case systemAlertPresent = "system-alert-present"

    /// SpringBoard への1問(`GET /systemalert`)が**失敗した**(USB の token 無し・WiFi の待ち受け断・
    /// ランナーの死亡)。判定は「アラート無し」と同じ側へ倒れて操作は進むが、**確かめていない**ことを
    /// ここに残す —— 失敗を nil に畳んで黙ると、`iosAlertHandler` を登録したのにアラートへ吸われた
    /// 操作が注記なしの緑になる(実機 SE3 で実測)。失敗したステップは文言にも理由が付く。
    /// **率が上がったら経路の不調**(ブリッジの生存・token・LAN)であってシナリオの問題ではない
    case systemAlertProbeFailed = "system-alert-probe-failed"

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

    /// snapshot 1回の実測がこのステップの待ち予算(`step.timeout ?? FlowStep.defaultWaitSeconds`)を
    /// 超えた(`TimelineStepRecord.snapshotMs` で内訳を追える)。**判定は変えない** ——
    /// このステップの合否とは無関係に、遅かった事実だけを残す。`SlowSnapshotBudget` が
    /// 期限後の追加取り直しをこの所要を根拠に止める判断の材料と同じ計測値。
    /// **率が上がったらフリートの供給が詰まっている**(冷えたフリートでブリッジの
    /// a11y ツリー直列化が伸びる形の先行指標)
    case slowSnapshot = "slow-snapshot"

    /// occlusion-guard の OCR 段(FM を省くための近道)が予算内に返らず、FM へ落ちた。
    /// **判定は変えない** —— 読めなかったのと同じ扱い。率が上がったら Vision のモデルが
    /// 載っていない(プロセス初回)か、Vision 自体が劣化している(`RegionText.occlusionBudget`)
    case ocrBudgetExhausted = "ocr-budget-exhausted"
    /// OCR の近道を撃たなかった理由。「近道が効くはず」の witness(薄いテキスト)が FM に落ちて
    /// 反転したとき、理由が残らないと 1 回で切れない(負荷テスト F29)
    case ocrShortcutNotWarm = "ocr-shortcut-not-warm"
    case ocrShortcutBusy = "ocr-shortcut-busy"

    /// 近道を撃つ前に暖機の完了を待った(ユーザー決定: run の開始時には待たない・
    /// 近道を呼ぶ時点でだけ待つ)。待った時間は `DeadlineExclusion` 経由で締め切りから差し引かれる
    /// ので判定は変えない。**率が上がったら暖機の開始(FTDriveCore.init)が間に合っていない**
    /// (実行プロファイルのマスタースイッチが効いているのに最初のガードより前に終わらない)
    case ocrWarmupWaited = "ocr-warmup-waited"
    /// 暖機の待ちが `RegionText.prewarmWaitCap`(120 秒)を使い切っても終わらなかった。
    /// **判定は変えない**(読めなかったのと同じ扱いで FM へ)。**率が上がったら Vision の
    /// コンパイルがハングしている**(ANE を避けていてもこの型は起こりうる。fm-flap-ane-load-failure)
    case ocrWarmupCapped = "ocr-warmup-capped"

    /// checkIsON / checkIsOFF の状態を **CheckStateClassifier が要素の画像から判定した**
    /// (a11y の報告ではない)。見本画像の不足・見た目の変更で誤りうる側なので、判定の出どころを残す
    case checkStateClassified = "check-state-classified"
    /// CheckStateClassifier の見本画像はあるのに、学習か読み込みに失敗した、または推論の対照が外れて
    /// 答えを使わなかった(`VisionClassifier.ClassifyError`)。どちらも a11y だけで判定した
    case checkStateClassifierFailed = "check-state-classifier-failed"
    /// findImage / findImages / existImage で Vision の異常(縮退・測り直しの不一致)を検知し、
    /// 待って走査をやり直した(`FindImage.anomalyRetryDelays`)。**判定は変えない** —— 戻れば通常どおり照合し、
    /// 戻らなければ失敗。**率が上がったら機械の GPU が混んでいる**(実測: 配信 24fps + 8 並列で最初の照合の約半数)
    case visionAnomalyRetried = "vision-anomaly-retried"
    /// 起動直後の最初のロケータ操作の前に配置の静止を待ち、**待っている間に実際に木が動いた**
    /// (= 待たなければずれる前の座標を撃っていた)。立たない = 既に静止していた(`pendingLaunchSettle`)
    case settledAfterLaunch = "settled-after-launch"
    /// flick・swipe・scroll の前に木の静止を待ち、**待っている間に実際に木が動いた**(= 待たなければ動いている
    /// 最中か古い枠へ指を置いていた)。立たない = 既に静止していた
    case settledBeforeGesture = "settled-before-gesture"

    /// 1番目の occlusion-guard 評価だけで、ガード自身の所要(FM の直列化待ち+推論)が
    /// このステップの待ち予算を食い潰し、1回もポーリングできないまま反転が確定しかけたので、
    /// deadline を一度だけ延ばして撮り直したところ通った(実測: guardMs 6.3s >
    /// 既定 timeout 5s で1フレームだけ古い描画を反転として確定させた欠陥)。
    /// **立つのは撮り直しが通った回だけ** —— 撮り直しても覆われたままなら本物の occlusion
    /// なので通常の失敗文言に譲り、この注記は立てない。
    /// **率が上がったらガードの所要(gateWait+推論)がステップの既定 timeout に対して重い**
    case guardRetaken = "guard-retaken"

    /// `type` がソフトキーボードを出した/動かした直後、次のロケータ操作の解決を
    /// `settledSignature` で押し上げアニメーションの収束まで待ったところ、**待っている間に
    /// 実際に木が変わった**(= 待たなければ古い座標を掴んでいた)。`StepExecutor.pendingTypeKeyboardCheck`
    /// の doc 参照。**立つのは救えた回だけ**(最初から静止していれば立てない。guard-retaken と同じ思想)。
    /// **率が上がったらキーボードの押し上げが大きい/遅い画面**(WebView 等)を通っている
    case settledAfterKeyboard = "settled-after-keyboard"

    /// 容器の外にあると判定した対象を、掴み直しと追加の送りを上限まで行っても外のまま**操作した**
    /// (止めないのは設計どおり = docs/design.md「スクロール残像(ghost)は拒否せず、警告して撃つ」)。
    /// ステップは緑のまま。**後段の検証が無いシナリオでは、これだけが「別の物に当たったかもしれない」
    /// 痕跡**になる(実測: iPhone 13 LAN で撃った後、後段の textIs が selected=- で赤。
    /// それまでは説明文の括弧書きにしか残らず run 横断で数えられなかった)。
    /// **率が上がったら往復の遅い経路で寄せ(recoveryJump / recoveryDirection)が収束していない**
    case actedOutsideContainer = "acted-outside-container"

    /// 検証が失敗したとき、それより前のタップのうち**画面を 1 ピクセルも変えなかったもの**を失敗文言で
    /// 名指しした(`StepExecutor.tapDiagnosisHint`。追加の撮影はしない)。**判定は変えない**
    /// (変えないのが正常なタップもある)。立つのは失敗したステップだけ。
    /// **率が上がったらタップが吸われている**(遷移直後の 1 タップ目・遅い Mac。
    /// S0020 は約 130 回中 2 回で、それまでは失敗文言にしか残らず数えられなかった)
    case unchangedTapBeforeFailure = "unchanged-tap-before-failure"

    /// `hold { }` のブロックが `holdSeconds` より長く掛かり、ブリッジが**ブロックの終わりより前に**
    /// 自分の時計で指を離していた(離し時刻+`StepExecutor.holdReleaseMargin` を過ぎてから
    /// `holdEnd` が呼ばれた)。判定は変えない —— ブロックの中身(押している間しか出ない部品の確認)は
    /// 既に終わっているので失敗にはしないが、**ブロックの後半は指が上がった状態で走っていた**ことを残す。
    /// **率が上がったら `holdSeconds` がブロックの所要に対して短い**。
    /// ブロックの中で**失敗したステップ**にも、その時点で指が上がっていれば立てる(中断で `holdEnd` が
    /// 実行されないため。`StepExecutor.noteHoldAlreadyReleased`)
    case holdEndedBeforeBlock = "hold-ended-before-block"

    /// xcuitest の高速起動で、起動させた後に**ランナーがアプリを前面と見ないまま** activate を頼んだ
    /// (`FastLaunchDriver`。ランナーが 5 秒待っても前面にならなかった)。activate はアプリを
    /// 「動いていない」と見ると起動し直し、その起動が時間切れになるとランナーごと落ちる
    /// (負荷テスト L18)。**立つだけでは失敗ではない**(activate が通れば緑)。
    /// **率が上がったら起動の遅いデバイス・高負荷**で、ランナー喪失の手前にいる
    case launchActivatedBeforeForeground = "launch-activated-before-foreground"

    /// 人間向けの文言(FTRuntime がステップ説明へ括弧書きで付ける)
    public var text: String {
        switch self {
        case .ocrBudgetExhausted: return "the OCR shortcut ran out of budget (asked FM instead)"
        case .ocrShortcutNotWarm: return "the OCR shortcut was skipped: the recognizer was not warm yet (asked FM instead)"
        case .ocrShortcutBusy: return "the OCR shortcut was skipped: an earlier OCR read was still running past its budget (asked FM instead)"
        case .ocrWarmupWaited: return "the OCR shortcut waited for the recognizer to finish loading before using it"
        case .ocrWarmupCapped: return "the wait for the OCR recognizer to finish loading ran out (asked FM instead)"
        case .checkStateClassified: return "the check state was judged by CheckStateClassifier from the element's image"
        case .holdEndedBeforeBlock:
            return "the hold's block ran longer than holdSeconds, so the finger was already up for"
                + " the rest of it"
        case .checkStateClassifierFailed:
            return "CheckStateClassifier could not be trained or loaded, or its answer could not be trusted,"
                + " so the check state came from accessibility only"
        case .settledBeforeGesture:
            return "the screen was still moving before the gesture, so the gesture waited for it to settle"
        case .settledAfterLaunch:
            return "the screen was still laying out after the launch, so the target was resolved again once it settled"
        case .visionAnomalyRetried:
            return "Vision returned untrustworthy image feature prints, so the image search waited and ran again"
        case .settleCapped: return "the screen did not settle (poll limit)"
        case .heldValue: return "from the grabbed value"
        case .scrollFrameMissing: return "the scrollFrame did not resolve, so the search stopped early"
        case .sheetCollapsed: return "the list stopped moving inside a partially open sheet"
        case .staleScreenshot: return "the occlusion-guard screenshot looked stale, so the check was skipped"
        case .staleFrameTextVisible:
            return "the screenshot looked stale (the tree changed but the image did not), but the expected text was already drawn in it, so it was treated as current"
        case .blankScreenshot:
            return "the screenshot was black apart from the system bars, so the visual check was skipped"
        case .webViewCaptureBlank:
            return "the text sits in a WebView and nothing covers it in the tree, but its area of the screenshot was a single colour (the capture missed the WebView layer), so the visual check was skipped"
        case .blankScreenshotRetaken:
            return "the app area of the screenshot for the image search was a single colour, so it waited and took it again"
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
        case .typeRetyped:
            return "a keystroke was dropped mid-string, so the text was cleared and retyped"
        case .typeRetypeAbandoned:
            return "the field still lost the same characters after retyping, so the value was accepted"
                + " as input the app transforms"
        case .swipeByRatioCapped:
            return "dxRatio/dyRatio beyond ±0.9 were capped to 0.9 (the ratio is relative to the target's"
                + " size); to move farther than the target, use swipeElementToElement or swipePointToPoint"
        case .typeReadbackUnchanged:
            return "the field's value did not reflect the input, but the typed text was seen in the"
                + " field on screen (OCR), so it was not sent again"
        case .launchURLBeforeInteractiveUI:
            return "the URL was delivered before any tappable element appeared, so the app may not"
                + " have been listening yet"
        case .typeFocusRecovered:
            return "the preceding tap did not put a field in focus, so the text went to the"
                + " field it resolved to"
        case .systemAlertPresent:
            return "a system alert was in front of the app with no iosAlertHandler registered for it,"
                + " so the app behind it was operated anyway"
        case .systemAlertProbeFailed:
            return "the check for a system alert in front of the app failed, so the step went ahead"
                + " without knowing whether one was there"
        case .firstFramePending:
            return "the screen still looked like the launch storyboard (a uniform, undrawn frame),"
                + " so this waited once more before treating it as occlusion"
        case .firstFrameTimeout:
            return "the screen still looked like the launch storyboard after waiting once more,"
                + " so this failed as occlusion"
        case .reinstalledToClearData:
            return "a physical device has no clearAppData, so the app was reinstalled instead —"
                + " permission grants are reset too, so the next launch can show system alerts"
        case .slowSnapshot:
            return "a single snapshot took longer than this step's wait budget"
        case .visibilityGuardSkipped:
            return "the FM visibility check gave no verdict, so this passed on tree presence and"
                + " on-screen geometry alone"
        case .textPartiallyHidden: return "part of the text is hidden"
        case .textEllipsized: return "the text is truncated with an ellipsis"
        case .ocrReadWhatFMMissed: return "FM judged the text not visible but OCR read it, so it passed"
        case .fmReadWhatOCRMissed: return "OCR judged the text not visible but FM read it, so it passed"
        case .healUnwritable:
            return "self-heal found a stand-in element but no selector picks it out uniquely on this"
                + " screen, so the fix was not written back — give the element a stable id"
        case .healFingerprintMatch:
            return "self-heal matched the previously-resolved element by its type and label" +
                " (locator fingerprint)"
        case .guardRetaken:
            return "the occlusion check itself used up this step's wait budget on the first look,"
                + " so this waited once more and the retaken frame passed"
        case .settledAfterKeyboard:
            return "the preceding type shifted the on-screen layout (keyboard), so this waited for"
                + " it to settle before resolving the target"
        case .launchActivatedBeforeForeground:
            return "the test runner did not see the app in the foreground after launching it, so it was"
                + " asked to activate it anyway (which can make the runner relaunch the app)"
        case .unchangedTapBeforeFailure:
            return "a tap before this failure did not change the app's tree at all"
        case .actedOutsideContainer:
            return "the element was still reported outside its scroll container when this acted on it,"
                + " so the interaction may have landed elsewhere"
        }
    }
}
