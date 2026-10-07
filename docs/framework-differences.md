# UI フレームワーク別の差異(fleetest から見た)

アプリの UI フレームワーク(Compose Multiplatform / Jetpack Compose・SwiftUI・UIKit・Android View/XML・
Flutter・React Native)によって、**木の見え方と操作の効き方が違う**。この文書は、その差を3つに分けて並べる。

| 区分 | 意味 | シナリオを書く人がすること |
|---|---|---|
| **A. 揃えている** | 素の挙動はフレームワークで違うが、ツールが吸収して同じ結果にしている | 何もしない(知っておくと、ログの注記や遅さの理由が読める) |
| **B. 揃っていない** | 原理的に揃えられない・揃えない判断をした。シナリオから違いが見える | 書き方で吸収する(`#id` で指す・echo の文字列で確かめる 等) |
| **C. 経路だけ違う** | 結果は同じだが、ツールの内部でフレームワークごとに別の手段を使う | 何もしない(性能・注記・フォールバックの理由として読む) |

正典は別にある: **型と `#id` の実測は各 SUT の `docs/ui-contract.md`**(母体は `E2EAppCMP/docs/ui-contract.md`)、
設計の根拠は `docs/design.md`、性能の経緯は `docs/performance-tuning.md`。ここは**横に並べて比べるための索引**で、
細部は各節から正典へたどる。

---

## 0. ツールはフレームワークをどう知るか

- **判定は `FTCore.AppUIFrameworkQuery` の1箇所**。順は「.app / .ipa / .apk の目印 → iOS シミュレータに入っている
  バンドル → bundle ID ごとの台帳 → in-app ブリッジの自己申告 → 不明」。目印の規則は `UIFrameworkMarkers`
  (ホストと in-app ブリッジが同じファイルを使う)。
  - iOS: `compose-resources` か実行ファイルの `SkikoUIView` → compose / `Flutter.framework` → flutter /
    `React.framework`・hermes・`RCTBridge` → reactNative / `SwiftUI.App.main()` → swiftUI / どれも無ければ uikit
  - Android: `AndroidPackageInspector`(ブリッジは申告しない)。**compose は「Compose を含む」**で、
    View/XML に Compose を混ぜたアプリ(E2EAppAndroid)も compose になる
- **分岐は「自前描画か」(`isSelfRendered` = compose / flutter)で書く**。個別の値で分けると、語彙を足した日に
  黙って外れる。
- 不明なときは**安全側**に倒す(空打ちを撃たない・撃ち直しをする・迂回しない 等。各節の「不明なら」)。
- 物理 iPhone ではアプリの中身が読めないので、材料が無ければ台帳、それも無ければ**掴んだ要素のクラス名**
  (`AccessibilityClassHint`。Compose / Flutter の要素は `UIAccessibilityElement`、RN は `UIView`、SwiftUI は `NSObject`)。

---

## 1. 木の見え方(型・`#id`・ラベル)

### 1.1 型の対照表(同じ `#id` を指したときの型。実測)

| 要素 | CMP(iOS) | CMP(Android) | SwiftUI/UIKit | View/XML | Flutter(iOS) | Flutter(Android) | RN(iOS) | RN(Android) |
|---|---|---|---|---|---|---|---|---|
| ボタン | `button` | `button` | `button` | `button` | `button` | `button` | `button` | `button` |
| スイッチ | `switch` | `switch` | `switch` | `switch` | `switch` | `switch` | `switch` | `switch` |
| テキスト | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` |
| パスワード欄 | `textView` | `secureTextField` | `secureTextField` | `secureTextField` | `textField` | `textField` | `secureTextField` | `secureTextField` |
| チェックボックス | `button` | `checkBox` | `button` | `checkBox` | `switch` | `checkBox` | `other` | `checkBox` |
| リスト行 | `button` | `clickable` | `clickable`(UITableView) | `clickable` | `button` | `button` | `button` | `button` |

- **A. 揃えている**: ボタン・スイッチ・テキストの3つは全フレームワークで同じ型になる(下の 1.3)。
- **B. 揃っていない**: 入力欄・チェックボックス・ラジオ・スライダー・リスト行は、iOS 側の a11y が役割を
  出さないので揃えられない → **これらは型ではなく `#id` で指す**。
  - 入力欄: CMP(iOS)は単一行・パスワード・複数行とも `textView`。Flutter(iOS)は `textField`。
    **マスクの有無は iOS の Compose / Flutter では型に出ない**
  - 複数行の入力欄: SwiftUI/UIKit と RN(iOS)は `textView`、Android は `textField`

### 1.2 `#id` の出し方(アプリ側の作法。守らないと `#id` が全滅する)

| フレームワーク | 作法 | 罠 |
|---|---|---|
| Compose(Android) | `testTagsAsResourceId = true` をルートで立てる | **ダイアログは別ウィンドウ**なので、ダイアログにも付け直す(忘れると Android だけダイアログ内の `#id` が全滅) |
| Compose(iOS) | `testTag` がそのまま identifier | **Scaffold 等の容器の testTag は AX に出ない** → 着地判定は葉(Text/Button)で |
| SwiftUI / UIKit | `.accessibilityIdentifier` | **UIAlertController の title / message には効かない**(ボタンには効く)→ 見出しはラベルで指す |
| View/XML | `android:id` | **実行時に resource-id を作れない** → 動的リストは `res/values/ids.xml` に静的宣言。AlertDialog の既定ボタンは `android:id/button1` になる |
| Flutter | `Semantics(identifier:)` + `MergeSemantics` | **`ensureSemantics()` を呼ばないと木が空**。Slider を `MergeSemantics` で包むと **iOS の木が丸ごと空** |
| React Native | `testID` | RN 0.65 以降(それ以前は Android に出ない)。Modal 内にも届く |

### 1.3 ツールが揃えている木の違い(A)

| フレームワーク | 素の挙動 | ツールの吸収 | 場所 |
|---|---|---|---|
| Compose(Android) | Button 等の役割が「同じ矩形の無名の子」として出る。見切れると親と子が別々に切れ、同じ要素が `button` と `clickable` を行き来する | 2辺以上が一致・面積3倍以内の子の役割を親へ引き上げる | `SnapshotBuilder.looksLikeRoleMarker` |
| Flutter(Android) | テキストが `android.view.View` のまま(contentDesc だけ) | 子を持たない葉 + contentDesc を `staticText` にする | `SnapshotBuilder.mappedType` |
| Flutter(Android) | `#id` が入力欄でなく外側の入れ物に付く(入れ物は editable でなく、欄は id を持たない) | 入れ物の今の枠に収まる editable を引き直す(座標で追うと、キーボードで欄が動いた後に見失う) | `InputInjector.editableInsideTagged` |
| Android(Emulator) | 撮れていないスクショに**ステータスバーだけ**が残る(本体は真っ黒)。下端だけ除く黒い絵の判定では黒と言えず、視覚検証が OCR だけで「描かれていない」の赤を出した | 視覚検証の素通りは上端の帯も除いて判定する(凍結の警告の判定は変えない) | `BlankFrameDetector.isBlackApartFromSystemBars` |
| Compose(Android) | ブリッジが送るタッチの「道具の種類」が不明だと、指と数えない部品がある(M3 の `TooltipBox` は長押ししても出なかった) | 送るタッチは指(`TOOL_TYPE_FINGER`)と明示する | `InputInjector.event` |
| Compose(iOS / Android) | 操作の直後、絵は既に新しい状態なのに、木(アクセシビリティ情報)のラベルが遅れて追いつくことがある。「絵が古い」の判定(絵は同じなのに木が変わった)と同じ形になり、最新の絵を古いと読み違えて撮り直しの予算いっぱい待っていた | 古いと判定した絵でも、期待する文字が丸ごと読めれば古くないとみなす(注記 `stale-frame-text-visible`)。本当に古い絵(期待する文字が無い)は従来どおり待つ | `StepExecutor.staleFrameShowsExpectedText` |
| Android(全般) | 自動でフォーカスを取る欄(ダイアログの autofocus)は、キーボードが上がる間に動く | 対象の欄が既にフォーカスを持っていれば、入力の前のタップを撃たない(id で引けた欄だけ) | `BridgeRouter.tapUnlessAlreadyFocused` |
| iOS(in-app) | 同上(Flutter の iOS でも同じ形で閉じた) | 入力の前のタップは、欄が形を変えずに動いていたら動いたぶんだけ追う(大きさが変わっていたら snapshot の座標のまま) | `InAppBridge.pointFollowingMove` |
| Android(全般) | アプリが切り替わった直後、スクショが前のアプリの最後の絵を返し続けることがある(配信中・負荷時) | 起動の直前の絵と木を控え、最初の視覚検証でも「木は変わったのに絵は同じ」を拾う(注記 `stale-screenshot`・赤にしない) | `StepExecutor.recordPreLaunchFrame` |
| SwiftUI | Toggle が同じ枠の `switch` を2つ出す。UIAlertController のボタンが同じ id で2つ | 何も足さない方を畳む | `SnapshotDedupe` |
| React Native(iOS) | `FlatList` の testID が非スクロールのラッパーに付き、実際にスクロールするノードが別に出る | 同じ枠の「id 付きラッパー + 匿名 scroll ノード」を1つに統合 | `SnapshotDedupe` |
| React Native(iOS in-app) | id 付き Text が「id 付き + 同じラベルの id 無し」の対で出る | uikit 系のときだけ畳む | `SnapshotDedupe`(`InAppDriver`) |
| React Native(Android) | Pressable の内側の Text が、ボタンと同じラベルの別ノードで残る | ボタンに内包される同ラベル・無 id の staticText を畳む | `SnapshotDedupe.dropLabelTwinsInsideButtons` |
| Compose / Flutter(iOS in-app) | 入力欄が UITextField ではない合成 AX 要素で、in-app だけ `other` になっていた | テキスト入力の trait と `UITextInput` 準拠で型を付け、XCUITest と揃える | `InAppSnapshot.elementType` |
| Flutter(iOS) | SnackBar の文言が「頻繁に更新される」特性だけのノードで、型が Other・id 無しのため木から落ちていた(中のボタンだけ出る) | ラベルを持つライブリージョンを `staticText` として出す(in-app・XCUITest とも) | `LiveRegionText.isLabelOnlyLiveRegion` |
| RN(iOS・in-app) | `Pressable` は既定でアクセシビリティ要素になり、名前も id も無いと木に出ない。その中の id つきの View(`pointerEvents="none"` の欄)まで消えていた(XCUITest の木には出る) | 木に出さなかったアクセシビリティ要素は葉にせず、中を辿る | `InAppSnapshot.collect` |
| Compose(iOS) | 容器の外の行(ghost)を、ラベル無しで木に残す | 見切れの判定を容器基準にし、画面端に積もった行の山は遮蔽物扱いしない | `clippingContainer` / `OcclusionSuspicion` |

### 1.4 揃っていない木の違い(B)

| フレームワーク | 違い | シナリオでの扱い |
|---|---|---|
| 自作の部品(SwiftUI の Button で作ったチェックボックス・ラジオ等) | チェック状態を a11y に一切出さない(value も selected trait も無い) | **見本画像を `vision/classifiers/CheckStateClassifier/[ON]`・`[OFF]` に置けば画像で判定できる**(CheckStateClassifier。witness は E2E-iOS の `#cb_agree` / `#radio_*`)。見本が無いと `checkIsON` は「reports no check state」で落ちる。ほかの手段は **echo の文字列**(`agree=true` 等)か、アプリ側で公開する(SwiftUI なら `.accessibilityRepresentation { Toggle(...) }`) |
| Compose(iOS)の Checkbox/Radio・Flutter(iOS)の Radio | **オンだけ**報告する(オフと「状態を持たない」が同じ見え方) | 同じシナリオで一度オンを見た要素ならオフも確定する。見る前の `checkIsOFF` は通して警告。**見本画像を置けば、見る前のオフも画像で判定できる**(§2.6) |
| Flutter・Compose(iOS)・Android | indeterminate(一部だけ選択)をオフと区別して出さない(Flutter は `"0"`) | **`[INDETERMINATE]` の見本画像を置けば画像で判定できる**(§2.6)。ほかは echo の文字列で |
| WebKit の `<input type=radio>`(XCUITest 経路) | id の無い `other` 型(ラベル・value `"1"`/`"0"` 付き)で届き、木の規則(id の無い `other` は落とす)で**要素ごと消える** | in-app(DOM 経路)なら読める。XCUITest ではラベルのテキストを指す |
| SwiftUI・Compose(iOS) | Slider の value が `"50%"` などパーセント表記 | 値は echo の文字列で確かめる |
| SwiftUI(UITableView) | 画面外の行ラベルが、id 無しで全行分木に残る | ラベルの部分一致で不在検証しない |
| React Native(iOS in-app) | Modal の中身と背景の木が同居して見える(XCUITest は Modal だけ) | ダイアログ内は背景と衝突しない `#id` で指す |
| Flutter | ダイアログは Navigator のオーバーレイ = 普通の木なので、見出しにも `#id` が付く(SwiftUI は付かない) | 見出しは SUT ごとに id / ラベルを選ぶ |
| CMP(iOS)・Flutter(iOS)・RN(iOS / Android) | 入力欄の `text` が値ではなく**プレースホルダ**を返す(空欄で `"単一行"`。RN は入力後も)。他は空欄で空・入力後は nil。**`value` は全 SUT で値を返し、空欄は空**(2026-10-02 実測・5 SUT × 両 OS × 両エンジン) | 入力欄の値は `value*` で見る(空欄は `valueIsEmpty`)。入力欄に `text*` を当てない。witness は全 SUT の `24_空欄と否定形の検証.swift` |

---

## 2. 操作

### 2.1 タップ

| フレームワーク | 違い | 区分 | ツールの動き |
|---|---|---|---|
| 全部(iOS in-app) | 要素の既定動作(`accessibilityActivate`)が効く要素と効かない要素がある。RN の Pressable は tap の 96% が効かない | C | 効かなければ合成タッチに落ちる(注記 `activate did not fire -> synthetic touch`) |
| Compose(iOS in-app) | 画面遷移の直後、要素は木にあるのに activate がまだ効かない瞬間がある | A | **自前描画のアプリだけ**、整定を待って要素を取り直し activate を撃ち直す(`retriesUnfiredActivate`)。他のフレームワークでは撃ち直しても効いた実績が無いので、合成タッチの前に整定を待つだけ(v110) |
| React Native(iOS in-app) | コールドラウンチ直後にレイアウトが確定し、保存時の座標が1要素ずれる | A | 合成タッチの直前に要素を1回取り直して、今の座標で撃つ |
| SwiftUI(iOS in-app) | 合成タッチでは Button のジェスチャが発火しない | C | activate を最優先。座標指定も「その点を含む最小の要素」を activate する |
| Compose(iOS) | 画面外の要素の枠がクランプされ、`isHittable` も壊れている | C | 座標タップを維持(`.tap()`・`isHittable` を使わない) |

### 2.2 スクロール探索の直後のタップ(空打ち)

- **Compose / Flutter(iOS)**: スクロール容器が**次の1タッチを消費する** → 探索の終わりに、クリックにならない
  ドラッグ(空打ち)で肩代わりする。**A**(利用者は意識しない)
  - 指を離す点は要素の矩形の外へ横に抜く(矩形の中で離すとクリックが成立して行が選ばれる)
  - **RN・SwiftUI・UIKit・Android では撃たない**(RN は横4pt の抜きが `pressRetentionOffset` 内でクリックになり、
    Android は 2pt ドラッグがクリックとして発火する)。**不明なら撃たない**
  - 殺しスイッチ `FT_EMPTY_DRAG=off`(保守者向け)

### 2.3 スクロール

| フレームワーク | 素の制約 | ツールの手段(iOS in-app) | 区分 |
|---|---|---|---|
| SwiftUI / UIKit / RN | 合成タッチのドラッグをジェスチャ認識器が受理しない | `contentOffset` を直接動かす。端送りは1回で端へ寄せる | C |
| Compose / Flutter | `UIScrollView` を持たず、合成ドラッグも受理されない | UIAccessibility の scroll(VoiceOver と同じ経路)で送る。**1回 = 1ページで刻み幅は選べない** | C |
| 自前描画の WebView | interop がタッチと入力を横取りする | 中の `WKScrollView` の `contentOffset` を動かす | C |

**揃えている点(A)**:
- **`scrollFrame` を付けたスクロール**: Compose / Flutter でも、指定した要素がスクロール容器(枠が一致する)なら
  in-app で送る(v112)。容器でない要素(固定ヘッダ等)を指定したら XCUITest に回して、指定どおり「何も動かない」
  にする。UIKit 系も、指定領域の下にスクロールビューが無ければ何もしない(以前は画面のどこかの最大の
  スクロールビューを動かしていた)。witness = `05_スクロール` S0091 scene 4 と、固定ヘッダの scene
- **`scrollFrame` を付けないスクロール**: 「画面中央を払う」に揃える(v113)。XCUITest・Android は実際に画面中央を
  払う。in-app も**画面中央の下にあるスクロール容器だけ**を動かす(以前は in-app の Flutter・SwiftUI・RN だけ、
  画面下のカルーセルを動かしていた)。witness = S0091 scene 5
- **横方向の向き**: UIAccessibility の scroll の向きは「縦 = スクロールバーの向き(指と逆)・横 = 指の向き」。
  横も反転していた頃は、Compose / Flutter の横カルーセルが逆へ送られていた(v112 で修正)
- **端の判定**: 「受理した容器が断った = その向きの端」と読む(Flutter は端で断る。Compose は端でも受理を返すので
  木の変化で端を知る)。witness = S0091 scene 2・3
- **端へ飛んだ後に続きを描き足すリスト(RN の FlatList)**: in-app は端まで一度に飛ぶので、描き足し(実測 0.4〜0.7 秒)の
  前に「余地が無い」になる。しかも飛ぶたびにセルが同じ座標に並ぶので、木の署名では動いたと読めない。
  → 端の確定は最後に動いてから 1.0 秒後・ブリッジは `contentOffset` を動かしたら `atEdge: false`(v116)。
  witness = RN の S0091 scene 2(開いた直後の `scrollToRightEdge`。直す前は #tag_13 で止まった)。
  **Compose / Flutter の AX の scroll は「受理 = 動いた」と言わない**(Compose は端でも受理するので、言うと
  端を確定できず maxSwipes まで送る。v115 で実際に踏んだ)

**揃っていない点(B)**:
- 1回の送りで進む距離はエンジン・フレームワークで違う(Compose / Flutter の in-app は1ページ、XCUITest は慣性つき
  約1.1画面、Android はフリング)。**1回で届く距離を前提にシナリオを書かない**(`scrollTo` / `withScroll*` の探索で届かせる)
- Compose の in-app は、**容器そのもの**(scroll 印の要素)は scroll を断り、受理するのは内側の要素(ツールは容器を
  根に内側を走査する。C)

### 2.4 文字入力・Enter・消去(iOS in-app の受け口の違い。すべて C)

| フレームワーク | `type` | `pressEnter` | `clearInput` |
|---|---|---|---|
| Compose | 別ウィンドウにある本物の受け口(`IntermediateTextInputUIView`)を探して `insertText` | `insertText("\n")` が IME アクションになる(完全一致の `"\n"` だけ) | 全範囲を空に置換 → 残れば deleteBackward |
| UIKit / SwiftUI / RN | `insertText` | `textFieldShouldReturn:` + EditingDidEndOnExit を再現(SwiftUI の `onSubmit` もこの経路) | 置換後に EditingChanged と通知を補う |
| Flutter | `insertText` | engine の私有 API(`flutterTextInputView:performAction:withClient:`)へ配送。欠けていれば 409 | **in-app では非対応** → XCUITest へ |

- **入力欄でない対象(ボタン等)への `type` / `clearInput` は、自前描画でないと確定しているとき(UIKit / SwiftUI / RN /
  Android View)は撃つ前に失敗させる**(ドライバは打つ・消す前に対象をタップするので、撃つと押してしまう。
  `StepExecutor.nonTextInputPreflightRefusal`。入力欄をちょうど1つ包む容器は撃つ)。同じ判定で、in-app の 409 からの
  XCUITest への撃ち直しも止める(in-app がタップ済みのところへ XCUITest がもう一度タップすると2回押す)。
  **Compose / Flutter / 判定不明は従来どおり回す**(型名が入力欄の判定に当てにならない)。**B**(型の対象が誤っているシナリオの
  失敗の仕方が割れる。判定は `TypeReadback.isPositivelyNonTextInput`)
- **`\n` を含む `type` は、フレームワークを問わず XCUITest へ回す**(改行の意味を iOS の Return キーに揃えるため。
  in-app の `insertText("\n")` はフレームワークによって改行になったり、アクションになったり、握り潰されたりする)。
  **A**(結果を揃える)。tap の直後なら、先に焦点が立つのを待つ
- **Android の Enter**: View/XML の EditText には、ソフトキーボードが出ていると `keyevent 66` が届かない(IME が
  消費する)。Compose は届く → 既定を a11y の `ACTION_IME_ENTER` にして揃えている(A)
- **Android の入力**: Flutter は `findFocus` が半分の確率で入れ物(FlutterView)を返す → 木から編集可能な欄を探し直す(A)。
  Compose は焦点の無い欄への `ACTION_SET_TEXT` が true を返して反映しない → 焦点が立つまで撃たない(A)

### 2.5 ジェスチャ(iOS in-app)

| 操作 | Compose / Flutter | SwiftUI / UIKit / RN | 区分 |
|---|---|---|---|
| doubleTap | in-app で撃つ(**Compose は XCTest の合成タッチをダブルタップとして一度も数えない** —— 2回の独立したタッチで間隔を 0.1〜0.25 秒にしても同じ。2026-09-24 実測。ios-xcuitest の設定では Compose のダブルタップは成立しない) | XCUITest へ回す(ランナーは非公開 API で2回の独立したタッチを送る。XCTest の `doubleTap()` = 1回のタッチに tapCount=2 は RN が単タップと読む) | C |
| pinch | host の `FTCore.PinchGesture` が組んだ指の経路を in-app が再生 | XCUITest へ(同じ経路を非公開 API で再生。API が無い Xcode だけ要素ピンチへ縮退) | A |
| pinch の指の置き方 | **iOS**: 領域の長辺に沿って横に2本並べ、両端の 0.8 内側・両端で 20% 保持。**Android**: 領域の短辺の 90% から幅を決め中心に置く(最小 16px)。だから**対象未指定のピンチで領域を絞るのは iOS だけ**(Android は狭い領域だと最小スケール幅 27mm に届かない)。決めるのは `FTCore.PinchGesture`(指の座標)・対象領域は `FTCore.PinchRegion` | B |
| 長押し | — | SwiftUI は in-app で発火しない → XCUITest へ | C |
| ジェスチャ目的の `swipe` | XCUITest へ(AX の scroll に流すと、パッドの上でもスクロール可能な親が受理して空振りする) | XCUITest へ | C |
| `gesture`(多点・時刻つき経路) | XCUITest へ(in-app にこの経路自体が無い) | XCUITest へ | A(フレームワークを問わず同じ結果。座標ピンチと同じ非公開 API でフォールバック無し = 使えない Xcode では 422) |
| `hideKeyboard` | Compose は受け口がフォーカスを持ち続け閉じられない(in-app は 501) | 閉じられる | B |
| 戻る | Compose / Flutter には BackButton が無い → エッジスワイプ | 戻るボタンがあれば押す | C |

---

### 2.6 チェック状態(`checkIsON` / `checkIsOFF` / `checked=`)

iOS は実装ごとに状態の出し方が違う(2026-09-18 実測・両エンジン同値)。**A. 揃えている** ——
`FTCore.CheckStateReading` が全部を読み、オン / オフ / indeterminate / 不明に畳む。

| 実装(iOS) | オン | オフ |
|---|---|---|
| Flutter の Checkbox/Switch・SwiftUI の Toggle・RN の role=switch | value `"1"`(型 switch) | value `"0"` |
| RN の role=checkbox / radio | value `"checkbox, checked"` 等 | `"checkbox, unchecked"` 等 |
| Compose の Checkbox/Radio・Flutter の Radio | selected trait | 何も出さない(→ 1.4 の B) |
| Compose の Switch | selected trait | 何も出さない(型 switch なのでオフと読める) |
| WebKit(XCUITest)/ DOM 経路 | value `"1"` | value `"0"`(indeterminate は `"2"`。ARIA / RN の語は `mixed`) |

Android はどのフレームワークも `isChecked`(checkable なら value `"1"`/`"0"`)で出す。
**B. 揃っていない**ものは 1.4 の表(状態を出さない自作の部品・オンだけ報告・indeterminate)。

**画像での判定(CheckStateClassifier。Shirates Vision の移植)** —— a11y が状態を出さない部品を救う経路。
プロジェクトの `vision/classifiers/CheckStateClassifier/[ON]`・`[OFF]` に見本画像があれば、要素の枠で
切ったスクリーンショットを Create ML の画像分類器に掛け、1位のラベルで判定する(フレームワークを問わない)。

| 設定 `preferCheckStateClassifier` | 分類器を使う要素 |
|---|---|
| `true`(**既定**) | 見本があれば全部(a11y が状態を報告していても分類器が勝つ) |
| `false` | a11y が状態を報告しない要素だけ(自作の部品・オンを見る前の Compose の Checkbox 等) |

1コマンドだけ変えるのは `checkIsON(prefer: .classifier / .accessibility)`(`checkIsOFF` も同じ)。**全 SUT の
`21_チェック状態の判定元.swift` が同じ要素を両方の優先で読む**。`.accessibility` を指定しても分類器が判定した組み合わせ
(2026-09-19 実測・結果 JSON の注記 `check-state-classified` で確認)= a11y が状態を報告しない所:
Compose iOS の Checkbox / Radio の**オフ**、Flutter iOS の Radio の**オフ**、E2E-iOS の自作ボタン(常に)。
Android の4 SUT と RN iOS は、どの部品もオン/オフとも a11y が判定した。

見本は**推論と同じ a11y の枠で切る**(witness は E2E-iOS の scenario 08 = `#cb_agree` / `#radio_*` / `#sw_notify`)。
画像で判定したステップには注記 `check-state-classified`。
**`[INDETERMINATE]` のラベル(fleetest 独自)** に見本を置くと indeterminate も判定でき、`checkIsON` / `checkIsOFF` の
両方が「indeterminate」と言って落ちる(Shirates はこのラベルをどちらにも当てないので結果は同じで、理由を言えるだけ違う)。
同じ学習・推論(`FTCore.VisionClassifier`)を `imageIs`(DefaultClassifier。`vision/classifiers/DefaultClassifier/` の見本で
要素の画像のラベルを検証)も使う。どちらも要素の枠で切ったスクリーンショットを見るので、**フレームワークの違いに
左右されない**(差が出るのは a11y の枠の取り方だけ = 見本も同じ枠で切る)。
`findImage` / `findImages`(同じ見本をテンプレートに使う)も候補は a11y 要素の枠なので、**アイコンが a11y に1要素として
載らない実装では探せない**(フレームワークごとの実測はまだ無い。確かめたのは E2E-iOS の SwiftUI だけ)。

**それでも救えない形**(a11y・分類器のどちらにも根拠が無い):

| 形 | 理由 | 扱い |
|---|---|---|
| 要素が木に出ない(a11y から隠した部品・XCUITest 経路の WebKit のラジオ) | 分類器は「掴んだ要素の枠」を切るので、掴めなければ使えない | ラベルの文字を指す / in-app(DOM 経路)で読む |
| indeterminate の見本を置いていない画面の indeterminate | 分類器は見本のラベル(`[ON]`/`[OFF]`)のどちらかを必ず答える。a11y も Flutter・Compose(iOS)・Android は区別しない | `[INDETERMINATE]` に見本を置く。**置かないまま既定(分類器を優先)だと、a11y が indeterminate を正しく出す WebKit・RN でも分類器がオン/オフに振る** |
| 見本に無い見た目(ダークモード・テーマ・サイズ・無効・押下中・フォーカスリング・枠に入るラベルの文字や言語・切替アニメーション中) | 分類器は必ず見本のラベルのどれかを答える = 見本外の見た目は誤りうる | 回す条件ごとの見本を置く(Shirates の見本も bright / dark を持つ) |
| 状態を持たない要素(ただのボタン)を指した checkIsON/OFF | 既定(分類器を優先)では、画像からどちらかの判定が付いてしまう(以前は「報告なし」で落ちるか素通り) | 状態を持つ部品だけを指す |
| 見切れた要素(枠が画面外にはみ出す) | 切り出せないので a11y の判定に戻る(a11y も不明なら不明) | 画面内へ送ってから検証する |

## 3. 待ちと鮮度

| フレームワーク | 違い | 区分 | ツールの動き |
|---|---|---|---|
| Compose・Flutter(Android) | 新しく出た要素を a11y のキャッシュへ 800ms 以上出さない。まばらに読むと出現の検出が1周期遅れる(50ms 刻みで読み続けると遅れは出ない) | A | 待つ間の**2回目以降の読みだけ**キャッシュを迂回する(`repollBypassesCache`)。1秒遅延の出現待ちが CMP で 2.9 → 1.1 秒。**迂回はキャッシュを更新しない**ので、迂回の周で待ちが成立したら**次の操作の解決の1枚も迂回する**(`nextResolveBypassesCache`。素取得だと兄弟の古い位置を叩く = E2E-CMP 09 S0010 が実機 Android で 8/9 赤) |
| Compose(Android) | スクロールした後に古い木が返る | A | 自分で画面を動かした直後の1枚はキャッシュを迂回して撮る |
| Android の WebView(全フレームワーク) | DOM の変更が a11y へ 4〜8 秒遅れる | A | WebView の中のノードだけ `refresh()` してから読む |
| Compose(iOS) | 縁のぼかし(scroll edge effect)のアニメーションが終わらず、整定が上限に張り付く | A | `filters.*` のアニメーションを動きとして数えない |
| Flutter(iOS) | 慣性が 800ms でも収束しない | C | XCUITest ランナーの整定予算を固定(待ち切らない) |
| Compose・Flutter(iOS・in-app) | 画面を切り替えた直後、a11y の木は新しい画面なのに絵(自前の Metal 描画)が追いつかない。CMP は起動後の初回訪問でタップが返ってから 0.27〜0.45 秒のあいだ**切り替え前の絵**をバイト同一で返す(2回目の訪問・SwiftUI では起きない) | A | 操作の直前に低解像度の画素と木の指紋を控え、**木が変わったのに画素が操作前のままの間だけ**待ってから撮る(`InAppRenderCatchUp`・v117)。遷移の完了は待たない。操作1回あたり約 12ms、待つのは追いついていない回だけ(初回訪問で約 0.3〜0.4 秒) |
| Compose(iOS・XCUITest エンジン) | 上と同じ遅れが XCUITest のスクリーンショットでも起きる。タブを切り替えた直後の 0.3 秒以上、**切り替え前の画面**が返る(木は新しい画面)。ただし絵はバイト同一ではなく、押したタブの強調が載っている | B | **既知の制約**。待たずに1回だけ見る `findImage` / `findImages`(既定 `waitSeconds` 0)は別の画面を切って「無い」と答える。待つ `existImage` と、`waitSeconds` を渡した `findImage` は通る。in-app の v117 を移しても直らない(押した強調で画素が変わるので「画素が操作前のまま」の判定が発火しない)ので入れていない。fleetest 自身の E2E は、待つ版を E2E-CMP 20 S0020 に、待たない版(in-app の証人)を 23 に分け、後者は `Scripts/e2e.sh` が in-app のときだけ回す |
| Flutter / Compose / SwiftUI / RN | 起動直後の白い画面(blank)の長さが描画の重さに比例する(誤った再起動は Flutter 10・Compose 3・SwiftUI/RN 0) | C | blank の判定窓を約10秒にする |
| React Native | JS が listener を登録する前に届いた warm な URL を捨てる | A | `launchApp(url:)` は最初の画面が描かれてから URL を配送する |
| Flutter(Android 12 の実機) | 入力欄の外を叩いて IME が閉じ始めると、dumpsys は即「非表示」なのに a11y の木は**約 5.4 秒**キーボードを申告し続け、下端のタブバーを `isVisibleToUser = false` で落とす(`refresh` しても同じ。Pixel 3a で実測・Pixel 4a の Android 13 は 0.32 秒) | A | `hideKeyboard` の後、次のロケータ操作の最初の解決で木がキーボードを申告していれば消えるまで待ってから整定を見る(`pendingHideKeyboardWait`。上限 5 秒 = `FlowStep.defaultWaitSeconds`(実測の 5.4 秒は IME が閉じ始めた時刻から。hideKeyboard の時点では残り約 4.7 秒)。Android だけ・消えていれば費用ゼロ) |
| Android(全般・OS で割れる) | `type` は焦点を要求して文字を書き込むとすぐ返り、ソフトキーボードの表示を待たない(表示要求から表示完了まで中央値 0.2 秒・最大 0.89 秒)。次の解決の木にまだ無いと、後で出てダイアログが動き古い座標を撃つ。iOS の `type` は出現まで返らないので起きない | A | Android だけ、打つ前も次の木にもキーボードが無く改行で終わらない `type` の後、次のロケータ操作の解決の前に最大 1.5 秒(`KeyboardWait.appearSeconds`)、出現を待ってから整定を見る。出なければ注記 `keyboard-not-shown-after-type`・以降の木で出たら `keyboard-appeared-late` |
| Flutter(Android) | 起動直後の数百 ms はタップを取りこぼす。タップ直後は入力接続が未確立 | B | SUT のシナリオは起動直後・タップ直後に `exist` を1往復挟む |

---

## 4. WebView

| 構成 | 木の出どころ | 操作 | 区分 |
|---|---|---|---|
| iOS in-app・SwiftUI/UIKit ホスト | DOM を JS で読む(in-app から WebView の a11y は見えない) | 合成タッチ | C |
| iOS in-app・Compose / Flutter / RN ホスト | DOM を JS で読む | **ref を座標に直して XCUITest の実タッチ**(interop が合成タッチと入力を横取りする)。スクロールだけは in-app | C |
| iOS XCUITest | a11y(中身が出るまで約2.3秒) | 実タッチ | C |
| Android | a11y + debuggable なら CDP で DOM | 実タッチ | C |

- interop かどうかは **WKWebView ごとに祖先のクラス名で**決める(アプリ単位で決めない。add-to-app で混ざるため)
- **B**: WebView の中の `#id` は経路で出たり出なかったりする(DOM 経路は出る・WebView 124 は placeholder だけ・150 は id だけ)
  → 入力欄は `#wv_input||#WebView 入力` のように**2つ並べて書く**。初回表示は SUT で 0〜8 秒違う(ネイティブ Android は即時・
  Flutter Android は約8秒)→ `waitSeconds:` を長めに

---

## 5. 起動の速さ

- **CMP(iOS)は SwiftUI より起動が約 0.8 秒遅い**(B・アプリ自身の性質)。in-app の launch の待ちは「アプリのメインスレッドが
  空いてブリッジが答えるまで」で、差はそこにだけ出る。仕組みの違う XCUITest の launch でも同じ差(docs/performance-tuning.md §6)
- Android でも CMP の起動は他より遅め。ツールの待ち方(80ms 間隔の問い合わせ)は全フレームワーク共通

---

## 5.1 各フレームワークの固有部品(E2EX で実測・2026-09-28)

共通契約の SUT に載らない**定番部品**は、別の5 SUT(`E2EXAppCMP/`・`E2EXAppFlutter/`・`E2EXAppRN/`・`E2EXAppAndroid/`・
`E2EXAppIOS/`。画面・`#id`・echo の契約は `E2EXAppCMP/docs/ui-contract.md` と `ui-contract-wave2.md`、SUT ごとの差分は
各 `docs/ui-contract.md`)と `TestProjects/E2EX-*` で確かめる。回すのは `Scripts/e2ex.sh`。
**利用者向けの書き方は `docs/user-docs/reference/writing/ui_component_patterns_ja.md` が正典**(ここは結論だけ)。
既知の制約に当たるシナリオは `@Draft("既知の制約: …" / "調査中: …")` で既定の実行から外してある(名指しで回すと再現する)。

| 部品 | 違い | 区分 |
|---|---|---|
| モーダル(ドロワー・メニュー・シート) | 開いている間、背後の画面が木から消える(CMP 両 OS・SwiftUI) | B |
| 選択式の欄 | 値の置き場が違う: CMP = `value`(iOS の .text はラベル・Android は nil)/ SwiftUI `Picker(.menu)` = **ラベル**(`果物, バナナ`)/ Flutter `DropdownMenu` = 内側の要素の value(iOS)・Android は木に無い / Android `MaterialAutoCompleteTextView` = 木に無い | B |
| SwiftUI `Stepper` | 増減ボタンが `#<id>-Increment` / `#<id>-Decrement` | B |
| iOS のシステムの戻る | UIKit・SwiftUI・RN native-stack は `#BackButton`(ラベルは前の画面のタイトル) | A |
| 引っ張って更新(iOS) | SwiftUI `.refreshable`・RN の `RefreshControl` は長く引かないと始まらない(約 260pt では走らず約 470pt で走る) | B |
| タブのラベル | Flutter `Tab`・RN material-top-tabs はラベルに「Tab 3 of 3」「tab, 2 of 3」が付く | B |
| ドロワーを払って開く | Flutter `Drawer`・Android `DrawerLayout`・react-navigation drawer は端からの払いだけ。端は Android の戻るの帯 | B |
| Flutter の戻る(iOS) | go_router + MaterialPage で、合成したエッジスワイプでは戻らない(始点 x=1〜19・0.25〜0.8 秒)。原因未特定 | B |
| Flutter の iOS のオーバーレイ | オーバーレイ(Tooltip・Dialog)を一度出すと、次の画面遷移までその画面の a11y の矩形が 1/画面倍率に縮む(ルートのノードが「FlutterView ÷ 倍率」を申告し、その下が同じ比で縮む)。**in-app も XCUITest も同じ = Flutter 側の申告**。in-app ブリッジは補正する(`AXFrameRescale`・v132)。XCUITest エンジンは未補正 |
| Flutter `SearchAnchor` | バーを押すと別の入力欄(`#id` 無し)が開く。ツールは焦点の移った欄への type を断る(重複入力の安全策) | B |
| CMP の iOS | 既定の `OnFocusBehavior.FocusableAboveKeyboard` がキーボードの高さぶん画面全体を押し上げる | B |
| RN の iOS | `accessible` な祖先が子を1要素へ畳む(paper Tooltip・gorhom BottomSheetModal の既定)/ 1画面に Navigator を2つ置くと落ちる / paper Menu は Android の戻るを消費しない | B |
| Android BottomAppBar | FAB の切り欠きで幅が足りないと項目が「その他のオプション」へ畳まれる | B |
| 並べ替え・ピンチ | 同じドラッグ量でも着地が ±1 行ずれる / 指示した倍率に届かない(Android `ScaleGestureDetector` で 2.0 → 1.2) | B |
| TooltipBox(Compose・Android) | 押している間だけ出て指を離すと消える。表示中も文字は別ウィンドウ | B |

**ツール側で見つけて直した不具合(回帰テストは各 `90_不具合の回帰.swift` と `15_検索バー.swift`)**:

| 症状 → 直し方 | 起きた構成 |
|---|---|
| M3 SearchBar(iOS)で `type` が入力を重複(`apapapapap`)→ 値が1文字も動かなければ OCR で画面を見る(コンパイルを待つ・キリル同形異字を `OCRHomoglyphs` で畳む)・追送は1回まで | iOS hybrid |
| HorizontalPager の `scrollToLeftEdge` が端の手前で止まる → 端の署名に id とラベル(**送っている容器の中だけ**。容器の外の表示は送りの副作用で変わる = `edgeContentRegion`) | 全エンジン |
| 上端で状態が行き来する一覧(RefreshIndicator)で上限まで送る → **一度見た署名へ戻ったら進んでいない**(ドライバが動いたと申告した直後は数えない) | Flutter iOS |
| in-app の `tap(x:y:)` が Popup の外側に届かないのに緑 → 自前描画(か不明)で要素の無い点は XCUITest | iOS hybrid |
| `swipeBy` の始点が Android の戻るの帯 → 帯の幅を SystemUI の dump から読んで経路を寄せる / 比率 >0.9 は注記 | Android |
| 画面の最下端から始まる座標ドラッグ(`swipeElementToElement` / `swipePointToPoint` / `swipeBy`)が Android のホーム操作に取られアプリが離脱する → 下端のジェスチャ帯(dump の `mBottomGestureHeight`。Pixel 9 の Emulator・ジェスチャーナビで 84px = 32dp を実測。読めなければ 48dp × 密度 = 3 ボタンの高さを上限とした見積り)の中なら始点を帯の上へ寄せて注記(`ScrollGeometry.clearingBottomGestureBand`)。`gesture` の多点は寄せない | Android |
| 横の探索の scrollFrame が画面に半分未満しか見えず(縦の一覧の中の横の一覧が下端で切れる)払いが画面の縁に乗って数枚しか進まない → 探索の前に外側の縦の容器を送って枠を窓へ入れる(`ScrollGeometry.bringIntoView`・上限2回) | iOS(E2EY-iOS)・Flutter |
| `scrollToTop` の確認の払いが更新を撃つ → Android ブリッジ(v74)の `scrollActions` で送らずに端を確定。**容器は画面中央を含む最小のもの**(入れ子の SwipeRefreshLayout で効かなかった) | Android |
| スクロール探索が、末尾で続きを読み込む一覧を途中で打ち切る → 探索の打ち切りにも `edgeClaimGraceAfterMove` | 全エンジン |
| フォーカスを取らない別ウィンドウ(ExposedDropdown・Spinner の候補)の中身が木に無い → Android ブリッジ(v75)が同じアプリの手前の窓の中身を足す(`inOverlayWindow`。覆いの判定から除外) | Android |
| 横の探索(ページャ)で見つけた直後にページが前へ戻り、対象が消える → 探索後の空打ち(自前描画の容器が吸う1タッチの肩代わり)を**探索の軸と直交する向き**へ抜く(`StepExecutor.emptyDragEnd`。横へ抜くとページャがページ送りとして受けていた) | iOS(Compose・Flutter) |
| RN の PagerView(`UIPageViewController`)を in-app で送れず探索が「何も動かない」で打ち切る → 指の下が `UIPageViewController` のスクロールビューなら 501 で XCUITest へ回す(v133) | iOS in-app |
| XCUITest の探索が見つけた直後の tap が Compose の全幅の行(ListItem)で吸われて遷移せず、緑のまま次で赤 → ①フリングの尾(1pt/周で 1 秒以上這う)を止まったとみなす(`SettleMotion.restThresholdPt` = 2pt。1 点比較の減速判定は撮る間隔のぶれで「増加」に見えて打ち切っていたので 2 点ずつの和で比べる)②横に抜けられない全幅の行の空打ちは画面の中心へ寄る向きに縦へ抜く(`StepExecutor.emptyDragEnd`。インセットの行は従来どおり横) | iOS(Compose・Flutter) |
| Wipe Data の直後・作りたての AVD で、最初のテキスト入力に Gboard の「入力レイアウトの選択」シートが出てキーボードと画面の下半分を覆う(1度出たら次からは出ない = Wipe した台の最初の1本だけ赤)→ ブリッジがアプリを起動する前に、自前の空の画面でキーボードを出して閉じておく(v80 `ImeOnboarding.primeOnce`・言語ごとに1回。Gboard の IME ウィンドウに Button が2つ同じ行に並ぶ形だけ・左を押す。**入力の経路では閉じない** = 待つ間に欄が動いて Flutter で欄を見失う) | Android |
| 貼り付く見出し(操作不能のテキストの帯)に潜った行を押すと見出しに当たる → 撃つ前に送って外す対象を「容器の縁に揃った名前つきの帯」へ広げる(`TapTargetGeometry.isPinnedTextBand`。名前の無い暗幕・縁から浮いたラベルは従来どおり外さない) | 全エンジン |
| Flutter の iOS でオーバーレイを出した画面の a11y の矩形が 1/画面倍率に縮み、タップが全部ずれる → in-app ブリッジが「FlutterView ÷ 倍率」を申告するセマンティクスの容器を見つけ、その下を実の枠へ写す(`FTCore.AXFrameRescale`・v132。PlatformView の中身は実の枠なので掛けない) | iOS in-app |
| 上端へ戻す最後の1本のドラッグが、端を越えた余りで入れ子の親(SwipeRefreshLayout・RefreshControl)を引っ張り更新を走らせる → 端送りは a11y のスクロール操作で送る(ブリッジ v78 `POST /scrollAction`。軸の合う最小の容器・軸が分からなければ従来のドラッグ・送れない向きなら「もう端」) | Android |
| 反転したリスト(RN の `inverted`・transform で上下反転した UITableView のチャット)を in-app で送れず、最新の位置で「もう端」と判定して探索が1回も送らない → contentOffset 経路が容器の座標の反転を見て指の向きを裏返す(`FTSwipeDirection.inContentSpace`・v144。E2EY の反転チャット) | iOS in-app(UIKit 系) |
| 一覧に浮いた FAB を、包むビューが木に出ない(RN の iOS の `Animated.View`)ために深さでたどると上部バーが親に見え、容器の外へはみ出た要素(ghost)と読んで一覧を送り、FAB を隠していた → 祖先にスクロール容器が見つからないときは、中心を含む最小の申告スクロール容器で代えて浮いた物と読む(`ContainerGeometry.isFloatingOverDeclaredScroller`。E2EY-RN の隠れるバー) | iOS(RN)・Android |
| キーボード側の窓に載る `inputAccessoryView` の入力バー(Signal の会話画面の形)が in-app の木に出ない(キーのために窓ごと除いていた)→ first responder と first responder である VC の accessory の部分木だけを木に足す(`inputAccessoryRoots`・v144。E2EY-iOS の反転チャット) | iOS in-app |
| SwiftUI の `Text` + `onTapGesture`・ミニプレーヤー・OTP の箱を in-app で押すと、activate が不発のあと合成タッチ(UIGestureRecognizer が受理しない)に落ちて 200 のまま空振りする → SwiftUI の a11y ノード(UIView でない要素)だけ 501 を返し、ホストが XCUITest で今の枠の中心を座標タップする(`AppUIFramework.rejectsSyntheticTap(nodeIsView:)`・v146。**SwiftUI のアプリでも UIView の要素 = `.alert` の UIAlertController のボタン・UIKit 部品は合成タッチのまま** —— v145 は SwiftUI 全体を回して、XCUITest のランナーが「アラートが手前」で断りダイアログの E2E が退行した。RN・Compose・Flutter・UIKit も従来の合成タッチ。E2EY-iOS) | iOS in-app |
| `scrollViewDidEndDragging` 等の「止まった」で位置を確定する UIKit アプリ(反転チャットの `at_bottom`・ページ送り・末尾の追加読み込み)が、in-app の contentOffset 送りで反応しない(`scrollViewDidScroll` しか呼ばれない)→ アプリ自身の delegate へ WillBeginDragging → WillEndDragging → DidEndDragging(減速なし)を合成する。SwiftUI の内部 delegate・WKScrollView は呼ばない(`ScrollDelegateNotification`・v145。E2EY-iOS) | iOS in-app |
| 段に吸着する容器(gorhom の半分のシート)の中の探索が Android で「1度も動かなかった」で落ちる(ブリッジの払いは ACTION_UP を実時計で送り離す瞬間の速度 ≒ 0 = 伸ばした分を元の段へ戻される)→ **探索がまだ1度も動かせず、直前の1本も何も動かさなかったときだけ**次の1本を fling 付きで撃つ(`FTSwipeIntent.searchFling`。一度でも動いた後は掛けない = 木の公開の遅れで慣性を足すと飛び越す。E2EY-RN) | Android |
| scrollToTop が1本も払わずに終わり、縮んだヘッダが開かない(同じ枠に横のページャ「forward・right」と縦の一覧が重なり、ホストがページャの申告を縦の端と読んだ。RN は汎用の forward だけの容器が先頭)→ 端の判定の容器は**軸の違う向きだけを申告した容器を外し、同じ大きさなら軸の向きを申告した容器を採る**(`scrollContainerElement(vertical:)`。ブリッジの `smallestScrollableOnAxis` と同じ考え方。E2EY-CMP・RN) | Android |
| 探索の直後のタップが払う前の座標を撃つ(縮むヘッダのタブ・一覧の行。読み直しの `refresh()` はキャッシュを更新せず、Compose は親の配置だけがずれた変化をイベントで知らせない = 次の素取得が払う前の木を返し続けた)→ 読み直しのときに `UiAutomation.clearCache()`(API 34+・Android ブリッジ v86)。34 未満はホストが、読み直しの後の素取得を直近の読み直しと比べ、食い違えば読み直して確かめる(`A11yCacheStalenessGuard`。Pixel 3a で直す前 0/4 → 4/4。E2EY-CMP) | Android |
| 一部しか見えていない段を scrollFrame に指した横の探索で、外側の縦の容器を先に送る `bringIntoView` が効かない(枠の中心が外側の一覧の下端の外 = 中心で外側を探していた)→ 縦に重なっていれば外側とみなす(E2EY-iOS の `#shelf_9`。末尾のカードは既定の 8 本で届かない距離なのでシナリオが `maxSwipes: 12`) | 共通(ホスト) |
| 見つけた行が容器の縁で見切れたときの戻しが、in-app の Compose / Flutter では1ページ送りになり逆側へ飛び越して往復する(反転チャットで 8 本を使い切った)→ この経路では戻しを**必ず距離どおりのドラッグ**で撃ち(小さい量は 60pt へ広げる)、1pt 未満のはみ出し(浮動小数の差)は見つかったとする。SwiftUI は従来の容器基準の払い(E2EY-CMP の iOS) | iOS in-app(Compose・Flutter) |

**残っている制約(`@Draft` の理由と対応)**: **E2EY**: RN の collapsible-tab-view でタブを替えた直後、iOS では行がヘッダの裏に居る(in-app の木に覆っている物が出ないので名指しも回避もできない。XCUITest の木には `#Toolbar` として出る)/ Flutter の `AnimatedSlide` で上へ逃げたバーを、セマンティクスが元の位置のまま申告し(木では見えている)、探索が送らずに撃って見た目には無いボタンを押す(どちらも木だけでは決められない。押す前に絵で確かめる検証は FM を使う UI の視覚検証にあたり新設しない)/ iOS で半分開いた gorhom のシートが一覧の上からの払いで伸びない(XCUITest の本物の払いでも同じ・見出しからなら伸びる。木にグラバーが出ないので伸ばす場所を決められない。Android は直した)(以上 E2EY の `@Draft`)/ Flutter の iOS で scrollToTop が引っ張って更新になる / Flutter iOS のオーバーレイ後の座標(XCUITest エンジンだけ未補正)/ Android の一部の欄で
ACTION_SET_TEXT が拒まれる / Android のツールチップ・一部のオートコンプリートの候補が木に出ない / Flutter iOS の
スナックバーが見つからない(FM が止まった Mac で観測。帰属未確定)。
**XCUITest エンジンだけで赤(既定の in-app は緑・`Scripts/e2ex.sh --ios-xcuitest` で 13 本)**: CMP の refresh S0020(上) /
Flutter の tooltip・menu(オーバーレイ後の 1/3 座標は XCUITest では未補正)/ RN の sticky・date(XCUITest の木は全画面の
`#Toolbar` を手前に置くので、覆いの判定が見出しでなく Toolbar を採り lift が効かない)/ SwiftUI の pinch reset・sheet の
探索・inputs S0020/30/40 / CMP の inputs S0030/40(打鍵が欄に入らない)。

**同じ型の残り(未対処・再現していない)**: テキストの視覚検証の OCR 段も英語モデルのキリル同形異字で読み違えうる
(固定コーパス `Tests/Fixtures/OcclusionCrops/` の読みを1件ずつ見てから畳む)。

---

## 6. ツールの変更で差を詰めた履歴(新しい順)

| 版・コミット | 内容 |
|---|---|
| `9bbf17dd` | 入力系(`type` / `pressEnter` / `clearInput`)の 409 を、MCP・ライブ操作でも XCUITest へ回す(`DriverError.isTextInputFallback` / `isClearInputFallback`)。この表の「→ XCUITest へ」は DSL でしか成り立っておらず、**同じ構成の同じ操作が `ft_type` / `ft_press_enter` / `ft_clear_input` では落ちていた** |
| v117 | in-app のスクリーンショットは、自前描画(Compose / Flutter)で木が絵より先に進んでいる間は撮らない(`InAppRenderCatchUp`。findImage / imageIs / 分類器 / occlusion-guard が別の画面の画素を切り出していた) |
| — | チェック状態を見本画像から判定する CheckStateClassifier(Shirates Vision の移植。実行プロファイル `preferCheckStateClassifier`・既定 true) |
| v114 | チェック状態を value からも読む(Flutter・SwiftUI Toggle・RN・WebKit で `checkIsON` が落ちていた)。DOM 経路で `aria-checked`・`indeterminate` を読む |
| `e83c9ba2` | tap の直後の改行入り `type` は、XCUITest へ回す前に焦点を待つ |
| v113 `46c188f5` | `scrollFrame` 無しのスクロールを、in-app でも画面中央の下の容器に揃える |
| v112 `075ca1af` | Compose / Flutter の `scrollFrame` を in-app で送る。横の向きの修正。UIKit 系の領域指定で最大のビューへ落とさない |
| `8726f1ff` | Android の自前描画で、待つ間の読み直しだけキャッシュを迂回する |
| v110 `e9f90818` | in-app の activate の撃ち直しを自前描画に限る(整定待ちは全フレームワークで残す) |
| v102〜v103 | フレームワーク判定を `AppUIFrameworkQuery` / `UIFrameworkMarkers` に一本化(RN・SwiftUI・Android も判定) |

---

## 7. この文書を直すとき

- フレームワークで挙動が割れる変更を入れたら、該当節の表に1行足す(区分 A / B / C を必ず付ける)。
  **B を A に変えた**ときは、witness(赤になるシナリオ)を併記する
- 型・`#id` の実測値そのものは各 SUT の `docs/ui-contract.md` が正典。ここへは結論だけ写す
- 利用者向けの書き方の指針(`#id` で指す・echo で確かめる等)は `docs/user-docs/` と
  `E2EAppCMP/docs/ui-contract.md` の全体規約が正典
