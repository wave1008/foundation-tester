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
| SwiftUI | Toggle が同じ枠の `switch` を2つ出す。UIAlertController のボタンが同じ id で2つ | 何も足さない方を畳む | `SnapshotDedupe` |
| React Native(iOS) | `FlatList` の testID が非スクロールのラッパーに付き、実際にスクロールするノードが別に出る | 同じ枠の「id 付きラッパー + 匿名 scroll ノード」を1つに統合 | `SnapshotDedupe` |
| React Native(iOS in-app) | id 付き Text が「id 付き + 同じラベルの id 無し」の対で出る | uikit 系のときだけ畳む | `SnapshotDedupe`(`InAppDriver`) |
| React Native(Android) | Pressable の内側の Text が、ボタンと同じラベルの別ノードで残る | ボタンに内包される同ラベル・無 id の staticText を畳む | `SnapshotDedupe.dropLabelTwinsInsideButtons` |
| Compose / Flutter(iOS in-app) | 入力欄が UITextField ではない合成 AX 要素で、in-app だけ `other` になっていた | テキスト入力の trait と `UITextInput` 準拠で型を付け、XCUITest と揃える | `InAppSnapshot.elementType` |
| Compose(iOS) | 容器の外の行(ghost)を、ラベル無しで木に残す | 見切れの判定を容器基準にし、画面端に積もった行の山は遮蔽物扱いしない | `clippingContainer` / `OcclusionSuspicion` |

### 1.4 揃っていない木の違い(B)

| フレームワーク | 違い | シナリオでの扱い |
|---|---|---|
| 自作の部品(SwiftUI の Button で作ったチェックボックス・ラジオ等) | チェック状態を a11y に一切出さない(value も selected trait も無い) | **見本画像を `vision/classifiers/CheckStateClassifier/[ON]`・`[OFF]` に置けば画像で判定できる**(CheckStateClassifier。witness は E2E-iOS の `#cb_agree` / `#radio_*`)。見本が無いと `checkIsON` は「reports no check state」で落ちる。ほかの手段は **echo の文字列**(`agree=true` 等)か、アプリ側で公開する(SwiftUI なら `.accessibilityRepresentation { Toggle(...) }`) |
| Compose(iOS)の Checkbox/Radio・Flutter(iOS)の Radio | **オンだけ**報告する(オフと「状態を持たない」が同じ見え方) | 同じシナリオで一度オンを見た要素ならオフも確定する。見る前の `checkIsOFF` は通して警告。**見本画像を置けば、見る前のオフも画像で判定できる**(§2.6) |
| Flutter・Compose(iOS)・Android | mixed(一部だけ選択)をオフと区別して出さない(Flutter は `"0"`) | mixed を検証したいときは echo の文字列で。**CheckStateClassifier も mixed を返せない**(§2.6) |
| WebKit の `<input type=radio>`(XCUITest 経路) | id の無い `other` 型(ラベル・value `"1"`/`"0"` 付き)で届き、木の規則(id の無い `other` は落とす)で**要素ごと消える** | in-app(DOM 経路)なら読める。XCUITest ではラベルのテキストを指す |
| SwiftUI・Compose(iOS) | Slider の value が `"50%"` などパーセント表記 | 値は echo の文字列で確かめる |
| SwiftUI(UITableView) | 画面外の行ラベルが、id 無しで全行分木に残る | ラベルの部分一致で不在検証しない |
| React Native(iOS in-app) | Modal の中身と背景の木が同居して見える(XCUITest は Modal だけ) | ダイアログ内は背景と衝突しない `#id` で指す |
| Flutter | ダイアログは Navigator のオーバーレイ = 普通の木なので、見出しにも `#id` が付く(SwiftUI は付かない) | 見出しは SUT ごとに id / ラベルを選ぶ |

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
  スクロールビューを動かしていた)。witness = `05_スクロール` S0090 scene 8 と、固定ヘッダの scene
- **`scrollFrame` を付けないスクロール**: 「画面中央を払う」に揃える(v113)。XCUITest・Android は実際に画面中央を
  払う。in-app も**画面中央の下にあるスクロール容器だけ**を動かす(以前は in-app の Flutter・SwiftUI・RN だけ、
  画面下のカルーセルを動かしていた)。witness = S0090 scene 9
- **横方向の向き**: UIAccessibility の scroll の向きは「縦 = スクロールバーの向き(指と逆)・横 = 指の向き」。
  横も反転していた頃は、Compose / Flutter の横カルーセルが逆へ送られていた(v112 で修正)
- **端の判定**: 「受理した容器が断った = その向きの端」と読む(Flutter は端で断る。Compose は端でも受理を返すので
  木の変化で端を知る)。witness = S0090 scene 6・7

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
| doubleTap | in-app で撃つ(XCUITest の doubleTap は2打の間隔が 0ms で、Compose が2打目を捨てる) | XCUITest へ回す(合成タッチでは発火しない) | C |
| pinch | in-app で短辺の 90% まで開く(XCUITest は指を約 8px しか開かず、Flutter のしきい値に届かない) | XCUITest へ | C |
| 長押し | — | SwiftUI は in-app で発火しない → XCUITest へ | C |
| ジェスチャ目的の `swipe` | XCUITest へ(AX の scroll に流すと、パッドの上でもスクロール可能な親が受理して空振りする) | XCUITest へ | C |
| `hideKeyboard` | Compose は受け口がフォーカスを持ち続け閉じられない(in-app は 501) | 閉じられる | B |
| 戻る | Compose / Flutter には BackButton が無い → エッジスワイプ | 戻るボタンがあれば押す | C |

---

### 2.6 チェック状態(`checkIsON` / `checkIsOFF` / `checked=`)

iOS は実装ごとに状態の出し方が違う(2026-09-18 実測・両エンジン同値)。**A. 揃えている** ——
`FTCore.CheckStateReading` が全部を読み、オン / オフ / mixed / 不明に畳む。

| 実装(iOS) | オン | オフ |
|---|---|---|
| Flutter の Checkbox/Switch・SwiftUI の Toggle・RN の role=switch | value `"1"`(型 switch) | value `"0"` |
| RN の role=checkbox / radio | value `"checkbox, checked"` 等 | `"checkbox, unchecked"` 等 |
| Compose の Checkbox/Radio・Flutter の Radio | selected trait | 何も出さない(→ 1.4 の B) |
| Compose の Switch | selected trait | 何も出さない(型 switch なのでオフと読める) |
| WebKit(XCUITest)/ DOM 経路 | value `"1"` | value `"0"`(mixed は `"2"`) |

Android はどのフレームワークも `isChecked`(checkable なら value `"1"`/`"0"`)で出す。
**B. 揃っていない**ものは 1.4 の表(状態を出さない自作の部品・オンだけ報告・mixed)。

**画像での判定(CheckStateClassifier。Shirates Vision の移植)** —— a11y が状態を出さない部品を救う経路。
プロジェクトの `vision/classifiers/CheckStateClassifier/[ON]`・`[OFF]` に見本画像があれば、要素の枠で
切ったスクリーンショットを Create ML の画像分類器に掛け、1位のラベルで判定する(フレームワークを問わない)。

| 設定 `preferCheckStateClassifier` | 分類器を使う要素 |
|---|---|
| `true`(**既定**) | 見本があれば全部(a11y が状態を報告していても分類器が勝つ) |
| `false` | a11y が状態を報告しない要素だけ(自作の部品・オンを見る前の Compose の Checkbox 等) |

見本は**推論と同じ a11y の枠で切る**(witness は E2E-iOS の scenario 08 = `#cb_agree` / `#radio_*` / `#sw_notify`)。
画像で判定したステップには注記 `check-state-classified`。

**それでも救えない形**(a11y・分類器のどちらにも根拠が無い):

| 形 | 理由 | 扱い |
|---|---|---|
| 要素が木に出ない(a11y から隠した部品・XCUITest 経路の WebKit のラジオ) | 分類器は「掴んだ要素の枠」を切るので、掴めなければ使えない | ラベルの文字を指す / in-app(DOM 経路)で読む |
| mixed(一部だけ選択) | 分類器が状態に写すのは `[ON]`/`[OFF]` だけ。a11y も Flutter・Compose(iOS)・Android は区別しない | echo の文字列で。**既定(分類器を優先)では、a11y が mixed を正しく出す WebKit・RN でも分類器がオン/オフに振る** —— mixed を扱う画面は `preferCheckStateClassifier: false` |
| 見本に無い見た目(ダークモード・テーマ・サイズ・無効・押下中・フォーカスリング・枠に入るラベルの文字や言語・切替アニメーション中) | 分類器は必ずオンかオフのどちらかを答える = 見本外の見た目は誤りうる | 回す条件ごとの見本を置く(Shirates の見本も bright / dark を持つ) |
| 状態を持たない要素(ただのボタン)を指した checkIsON/OFF | 既定(分類器を優先)では、画像からどちらかの判定が付いてしまう(以前は「報告なし」で落ちるか素通り) | 状態を持つ部品だけを指す |
| 見切れた要素(枠が画面外にはみ出す) | 切り出せないので a11y の判定に戻る(a11y も不明なら不明) | 画面内へ送ってから検証する |

## 3. 待ちと鮮度

| フレームワーク | 違い | 区分 | ツールの動き |
|---|---|---|---|
| Compose・Flutter(Android) | 新しく出た要素を a11y のキャッシュへ 800ms 以上出さない。まばらに読むと出現の検出が1周期遅れる(50ms 刻みで読み続けると遅れは出ない) | A | 待つ間の**2回目以降の読みだけ**キャッシュを迂回する(`repollBypassesCache`)。1秒遅延の出現待ちが CMP で 2.9 → 1.1 秒 |
| Compose(Android) | スクロールした後に古い木が返る | A | 自分で画面を動かした直後の1枚はキャッシュを迂回して撮る |
| Android の WebView(全フレームワーク) | DOM の変更が a11y へ 4〜8 秒遅れる | A | WebView の中のノードだけ `refresh()` してから読む |
| Compose(iOS) | 縁のぼかし(scroll edge effect)のアニメーションが終わらず、整定が上限に張り付く | A | `filters.*` のアニメーションを動きとして数えない |
| Flutter(iOS) | 慣性が 800ms でも収束しない | C | XCUITest ランナーの整定予算を固定(待ち切らない) |
| Flutter / Compose / SwiftUI / RN | 起動直後の白い画面(blank)の長さが描画の重さに比例する(誤った再起動は Flutter 10・Compose 3・SwiftUI/RN 0) | C | blank の判定窓を約10秒にする |
| React Native | JS が listener を登録する前に届いた warm な URL を捨てる | A | `launchApp(url:)` は最初の画面が描かれてから URL を配送する |
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
  Flutter Android は約8秒)→ `timeout:` を長めに

---

## 5. 起動の速さ

- **CMP(iOS)は SwiftUI より起動が約 0.8 秒遅い**(B・アプリ自身の性質)。in-app の launch の待ちは「アプリのメインスレッドが
  空いてブリッジが答えるまで」で、差はそこにだけ出る。仕組みの違う XCUITest の launch でも同じ差(docs/performance-tuning.md §6)
- Android でも CMP の起動は他より遅め。ツールの待ち方(80ms 間隔の問い合わせ)は全フレームワーク共通

---

## 6. ツールの変更で差を詰めた履歴(新しい順)

| 版・コミット | 内容 |
|---|---|
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
