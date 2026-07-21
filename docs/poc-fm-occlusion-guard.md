# PoC レポート: FM 視覚照合によるアサーション偽陽性の排除(occlusion-guard)

ブランチ: `poc/fm-occlusion-verify` / 実施日: 2026-07-21 / 実行: メインセッション(Claude Code)

## 1. 背景と課題

`exists` / `textEquals` / `valueEquals` の判定は、スナップショット(アクセシビリティツリー)上に
要素が存在するかだけを見る([StepExecutor.matchDetailed](../Sources/FTCore/StepExecutor.swift))。
可視性フィルタは「hidden・サイズ0・画面外」しか落とさず、**別要素に覆われている(occlusion)/
減光されている/切れている**要素はツリーに残るため、**視覚的に見えていないのにアサーションが成功する
偽陽性**が起こり得る。`hittable` は本来この検知に使えるが、①現行 wire DTO(`ElementInfo`)に
hittable は無く、②Compose iOS では `isHittable` 自体が壊れている([compose-ios-ax-frame-clamp])ため
採用できない。

そこで、**描画(スクリーンショット)を根拠に FM(オンデバイス Foundation Models)で可視性を照合し、
覆われ/切れ/減光/不在なら assert を失敗へ反転する**方式の実現可能性・正確性・速度を検証した。

## 2. 実装(PoC)

| 追加物 | 位置 | 役割 |
|---|---|---|
| `OcclusionVerifier` | [Sources/FTAgent/OcclusionVerifier.swift](../Sources/FTAgent/OcclusionVerifier.swift) | FM 視覚照合器。`@Generable VisibilityVerdict{ visible, state, observedText, reason }` を greedy で生成 |
| `ReplayDelegate.verifyElementVisible` | [Sources/FTCore/StepExecutor.swift](../Sources/FTCore/StepExecutor.swift) | FM 非依存の delegate フック(既定実装 nil)。FTCore を FM から切り離したまま結線 |
| `StepExecutor.occlusionGuard` + `occlusionFlip()` | 同上 | ノブ。exists/textEquals がツリー一致した**一点で1回だけ** FM 照合し、`visible==false` なら `.failed("偽陽性(occlusion)…")` へ反転 |
| 計測ハーネス | `ftester-poc-occlusion`(PoC ブランチ履歴・§8) | 正解ラベル付き合成フィクスチャで正確性・速度を計測 |

検証器は 2 アームを実装して比較した:

- **cropped(本命)**: スクショを要素 frame(+24px 余白)に**クロップ**して FM に渡す。座標を言葉で
  説明する必要がなく、視覚モデルは「この領域に期待テキストが明瞭に見えるか」だけに集中できる。
  frame は pt、スクショは px なので `screen` サイズからスケールを求めて px クロップする(Retina 対応)。
- **full(比較用)**: スクショ全体＋frame 座標を**言葉で**渡し、座標→ピクセル対応を FM に委ねる。

## 3. 計測方法

実機・シミュレータ不要。iPhone 相当の logical 画面(402×874pt)を **renderScale=2 のピクセル
(804×1748px)** で CoreGraphics 合成し、pt→px 換算経路も実地で通す。ナビバー・ディストラクタ文言を
常に描き「画面に文字があれば可視」と短絡できないようにした。3 テキスト(和/英/記号)× 6 カテゴリ =
**18 フィクスチャ**、各を両アームで判定(計 36 FM コール)。2 回反復。

| カテゴリ | 内容 | 期待(assert が pass すべきか) |
|---|---|---|
| visible | 期待テキストを明瞭に描画 | **見える(pass)** |
| coveredFull | 全面を不透明矩形で覆う | 見えない(reject) |
| coveredPartial | 左 65% を覆う | 見えない(reject) |
| dimmed | alpha 0.12 で薄く描画 | 見えない(reject) |
| absent | 領域に何も描かない(ツリーだけ存在を主張) | 見えない(reject) |
| mismatch | 別テキストを描画 | 見えない(reject) |

指標: **偽陽性排除の再現率**(隠れ 15 件を reject できた割合=機能の価値)、**有害な誤反転率**
(正しく見えている 3 件を誤って reject=導入の害)、全体正解率、1 回あたりレイテンシ。

## 4. 結果

2 回とも**ほぼ同一**(greedy のため決定的。full アームの誤りも同じ 4 件が再現)。

### 正確性

| アーム | 全体正解率 | 偽陽性排除の再現率 | 有害な誤反転率 |
|---|---|---|---|
| **cropped** | **18/18(100%)** | **15/15(100%)** | **0/3(0%)** |
| full | 14/18(78%) | 13/15(87%) | 2/3(67%) |

- **cropped は全カテゴリ完璧**。覆い・部分覆い・減光・不在・文言違いをすべて `visible=false` で弾き、
  正しく見えている 3 件は `visible=true` を維持。**偽陽性を 100% 排除し、正しい要素を一度も却下しなかった。**
- full は逆に**正しく見えているテキストを "covered" と誤判定して却下**(有害誤反転 67%)。座標を言葉で
  渡す方式は視覚モデルには機能せず、実用不可。

### 速度(1 回あたり、ms)

| アーム | min | median | p90 | max | mean |
|---|---|---|---|---|---|
| cropped(run1) | 1459 | 1618 | 1751 | 2937 | 1673 |
| cropped(run2) | 1454 | 1589 | 1782 | 2623 | 1655 |
| full(run1) | 1653 | 1911 | 2009 | 2201 | 1917 |
| full(run2) | 1696 | 1883 | 2036 | 2265 | 1909 |

- cropped は **median ≈ 1.6s / p90 ≈ 1.75s**。max(2.6〜2.9s)は各実行の**初回のみ**でモデルの
  コールドスタート。以降は定常。クロップで画像が小さい分 full より速い。

## 5. 分析

- **クロップが決定打**。座標を自然言語で渡す弱い手がかりを排し、視覚モデルに「この小領域を読めるか」
  という単純問題へ還元したことで精度が 78%→100% に跳ねた。設計判断(cropped を本命)は妥当。
- **`state` ラベルは不正確だが `visible` は正確**。cropped は coveredFull/Partial を "notRendered"、
  dimmed を "covered" と分類するなど state は当てにならない。だが**ガードが使うのは `visible` bool
  のみ**で、そこは 100% 正しい。state は診断メッセージ用の参考に留め、判定には使わない設計で問題ない。
- **コスト**は「ツリー一致した pass の一点で1回」。全 assert に付けると 1 ステップ +1.6s 程度。
  通常の in-app snapshot(~0.05ms)/操作に対し大きいので**常時 ON は非現実的**、ノブで**画面/シナリオ
  限定**が前提。

## 5.5 FM を「疑いがある時だけ」呼ぶ自動ゲート(追加検証)

全 assert で FM(+1.6s)を払うのは非現実的なので、**安価な事前シグナルで FM をゲート**する2段前段を
追加実装・計測した。FM に回すのは疑わしい時だけにする。

- **Tier-0 幾何**([OcclusionSuspicion.swift](../Sources/FTCore/OcclusionSuspicion.swift)・ツリーのみ・FM/スクショ不要):
  対象 frame を 40%以上覆う「記載順で後(手前寄り)の要素」/画面外はみ出し(切れ)/ロケータの
  部分一致解決、のいずれかで疑う。合成スナップショットで **5/5** 正しく発火/非発火。
- **Tier-1 ピクセル**([RegionInk.swift](../Sources/FTCore/RegionInk.swift)・スクショのみ・FM不要):
  対象 frame 領域の輝度 stddev。テキストがあれば中〜高、覆い/空/減光では低い。

ゲート規則([StepExecutor.occlusionFlip](../Sources/FTCore/StepExecutor.swift)):
**Tier-0 で疑い、または Tier-1 の stddev が閾値未満**のときだけ FM(cropped)へ。両方無罪なら FM 省略で pass。

### 事前フィルタの分離性(実測 stddev)

| カテゴリ | stddev | 判定 |
|---|---|---|
| visible | 60〜74 | 高(FM 省略で pass) |
| coveredFull / absent | **0.0** | 低(FM へ) |
| dimmed | 7〜9 | 低(FM へ) |
| coveredPartial | **31.5** | 高寄り(Tier-1 単独では取りこぼす) |
| mismatch | 48〜76 | 高(Tier-1 単独では取りこぼす) |

可視(≳60)と 全覆い/空/減光(≲9)は **大きなギャップで分離**。閾値 10〜30 のどこでも同挙動(既定 12)。

### ゲート後パイプライン(Tier-1 単独・閾値スイープ)

| 閾値 | FM呼出 | FM削減 | 生存偽陽性 | 有害誤反転 | 総合正解 |
|---|---|---|---|---|---|
| 12〜25 | 9/18 | **50%** | 6 | **0** | 67% |

- **FM 呼出を半減、有害な誤反転は 0**。全覆い/空/減光は Tier-1 が確実に FM へ回して捕捉。
- 生存偽陽性 6 = coveredPartial×3 + mismatch×3。**Tier-1 単独の弱点は「部分覆い」と「文言違い」**
  (残テキストのインクが多く高分散に見える)。
  - mismatch は本来 occlusion ではなく、`textEquals` の完全一致・`exists(id)` の実在で別途弾かれる筋
    (このガードの対象外と見なせる)。
  - coveredPartial は **Tier-0 幾何**が補う: 覆う要素がツリーに載っていれば、高インクでも FM に回す。
    Tier-0/Tier-1 を OR で併用する実装にした理由がこれ。
- **Tier-0 で拾えない残余**(覆う要素がツリーに載らない部分覆い)は原理的に FM 前段では検知不能。
  ここだけは「全件 FM」でないと 100% にはならない。実運用では稀と見て、ゲート既定 ON を推奨する。

## 5.7 実機(シミュレータ)再計測 — 合成では見えなかった重大な誤反転(2026-07-21)

空きデバイス **A012ADD8**(iPhone 17 Pro/iOS 27、モニター占有外)に inapp ブリッジを注入起動し、
**sut-ec-mobile** の実画面で計測(ハーネス `ftester-poc-occlusion` の Live.swift・§8、
`ftester-poc-occlusion live <udid> <bundle> <port> <dir>`)。ground truth はスクショ目視で確定。

### 結果: unconditional FM は実 UI で**約50%の有害誤反転**

ランディング + おすすめ商品の実テキスト/アイコン 24 要素中、**視覚的には全て可視**なのに
cropped 検証器が `visible=false` を返した誤反転が **約12件(≈50%)**。レイテンシは実機で
median≈1.5s(合成と同等)。誤反転はすべて次のパターン:

| 誤反転の型 | 例 | 原因 |
|---|---|---|
| **アイコン/画像**(a11y label は説明文) | ハート「お気に入りに追加」、商品画像 label=商品名 | 画面に描かれるのは絵で、label の文字列ではない → 「その文字が無い」と判定 |
| **絵文字** | 「📱」「👕」単体要素 | 絵文字を期待テキストとして読めず notRendered |
| **結合セマンティクス** | 「📱, 家電・電化製品」(タイル全体) | 絵文字+全文の合成 label。視覚とは別物 |
| **省略テキスト(…)** | label「家電・電化製品」→ 実描画「家電・電化**…**」 | 末尾省略で全文が見えない → 覆い/切れ扱い |

**決定的な対比**: 同じ行で label「ファッション」(省略なし)は `visible=true` ✓、
label「家電・電化製品」(実描画は「家電・電化…」)は `visible=false` ✗。**省略(ellipsis)が
誤反転の主因**であることが実機で確定した。合成フィクスチャは省略/アイコン/画像/絵文字を含まなかった
ため、この失敗モードを完全に見落としていた。

### なぜ「疑い時だけ FM」ゲートが実運用では安全側に働くか

上記の誤反転要素の輝度 stddev は **すべて 23〜99(高インク)**。ゲート(閾値 12)は高インク領域で
**FM を呼ばず素通り(pass)**にするため、**これらの誤反転は一切発生しない**(gate ON なら実質
0 誤反転)。FM が起動するのは stddev<12 の**ほぼ無地**の領域だけ — そこは「覆い/空」が明白で、
FM が最も信頼できるケース。逆に言うと:

- **unconditional FM(全 pass で FM)は実 UI では採用不可**(誤反転が多すぎる)。
- **2段ゲートは、FM が不得手な高インク領域(アイコン/画像/省略)から FM を遠ざける**ことで
  安全性を確保している。ゲートは単なるコスト最適化ではなく**正しさの前提**。
- ただしゲートは低インク領域しか FM に回さないので、**高インク下に隠れる部分覆い**は依然
  取りこぼす(Tier-0 幾何で一部補うのみ)。

## 5.8 足切り+省略許容を実装して再計測 — 誤反転 50%→0%(2026-07-22)

§5.7 の誤反転(アイコン/画像/絵文字/結合/省略)への対策を実装し、同じ A012ADD8 で再計測した。

**対策1: FM 前の要素足切り**([OcclusionEligibility.swift](../Sources/FTCore/OcclusionEligibility.swift)・ツリーのみ)。
`StaticText`/`Text` 等のテキスト型のみを対象にし、**非テキスト型(Button/Image/Cell)・結合 label
(`, ` を含む)・文字を含まない label(絵文字/記号のみ)を除外**。実機ダンプで検証:

| 除外されたもの | 残ったもの(適格) |
|---|---|
| カテゴリタイル(Button)、商品カード(Button)、商品画像(Image)、ハート(Button/Image)、絵文字単体「📱」 | 見出し・バナー・カテゴリ label・商品名・価格・評価・「セール」「新着」等の StaticText |

**対策2: 省略許容プロンプト**([OcclusionVerifier.swift](../Sources/FTAgent/OcclusionVerifier.swift))。
「末尾の… や折り返しは visible=true。false にするのは 覆い/単色空白/全く別の文字列 の時だけ」に改訂。

### 結果: 実機で有害誤反転 0

3 画面・**適格テキスト 36 要素すべてで `visible=true`(ground truth 全可視 → 誤反転 0/36)**。
各画面 26 要素は足切りで FM を呼ばず除外。レイテンシ median≈1.6s。

- **決定的**: §5.7 で誤反転していた ref9「家電・電化製品」(実描画「家電・電化**…**」)が、省略許容で
  `fullyVisible` に是正。価格「¥18,000」評価「(610)」商品名など省略/記号交じりの実テキストも全て正。
- **誤反転率 ≈50% → 0%**(実 UI・同一デバイス)。足切り+省略許容で素の FM の実用不能問題は解消した。

**未取得**: 実機での true-positive(実際に覆われた要素を false と当てる)。iOS シミュレータは
ハードウェアキーボード接続時にソフトキーボードが出ず(02≈03 が同一)、狙った occlusion を作れなかった。
occlusion 検知能力の裏付けは現状 §4(合成: 覆い/空/減光を 100% 検知)+低インクゲートに依存。
実オーバーレイ(モーダル/シート/スナックバー)での true-positive 確認が残タスク。

## 5.9 実機 true-positive を取得(2026-07-22)

`occtest` モード(ハーネス Live.swift・§8)で実 occlusion を作って検証:
商品詳細で「カートに追加」→ スナックバー(`カートに追加しました 見る`)が下部を覆う瞬間に snapshot+screenshot し、
覆われた適格テキストを verifier が捕捉できるか確認した。ground truth はスクショ目視。

| 要素 | 追加前 | スナックバー中 | ground truth | 判定 |
|---|---|---|---|---|
| **¥24,000**(111,695) | visible ✓ | **covered** | 追加前=見える / スナックバーが上端を覆う | **true-positive**(可視→覆いを正しく追従) |
| **レビュー**(16,857) | covered | covered | 両方とも sticky「カートに追加」バーの裏で不可視 | **true-positive**(安定・sd=0 でゲートが FM 起動) |
| 他の可視テキスト(価格/評価/商品名/バナー等) | visible | visible | 可視 | 正(誤反転 0) |
| スナックバー自身「カートに追加しました」 | — | visible | 可視 | 正 |

- **狙いどおりの実証**: 同一要素「¥24,000」が、スナックバー出現で `visible→covered` に正しく反転。
  「ツリー上に在るが視覚的に覆われて見えない」偽陽性を実機で捕捉できた。
- **レビュー**は sticky ボトムバーの裏に隠れた要素で、静止画面(追加前)でも安定して covered。
  当初の動機(ツリーに在るが見えない)そのものの実例を、低インクゲート(sd=0)が FM に回して正しく検知。

### 発見した運用上の罠: snapshot と screenshot の非原子性

スナックバー中「見る」(311,717・実際は可視)を sd=0・covered と誤判定。原因は **snapshot(frame)と
screenshot(pixel)を別コールで取得するため、アニメーション中は両者が時間的にズレる**こと。
frame は或る瞬間、pixel は別の瞬間のもので、crop がズレて空領域を掴む。
→ **占有ガードは静止後に実行するか、snapshot/screenshot を極力連続で取得すること**が前提。
StepExecutor.occlusionFlip は既に「操作の settle 後・pass 確定の一点」で1回だけ実行する設計なので、
通常の assert(整定後)では問題になりにくいが、アニメ中の assert では留意が必要(diagnosis に state を残す理由)。

## 5.10 DSL: 全アサーションを既定で可視性確認・`requireVisible: false` でオプトアウト(2026-07-22)

occlusion-guard を利用側の既定挙動にし、**`requireVisible` 引数で統一**した(ユーザー決定)。
`visible()` / `present()` は削除(検討の経緯は本節末尾)。

```swift
exist("#msg")                        // 既定: ツリー存在 + 実際に見えているかを FM で確認(見えなければ失敗)
exist("#icon", requireVisible: false) // ツリー存在のみ(見えているかは問わない・高速・アイコン/画像向け)
textIs("#msg", "完了")                // 既定: 一致 + 見えている
textIs("#msg", "完了", requireVisible: false)  // 一致のみ
valueIs("#sw", "1")                   // 同上(既定ガード)
```

- **既定 ON**: exist/textIs/valueIs は、ツリー一致で pass した直後に occlusion-guard を発火
  (足切り→低インク/幾何→FM→visible)。覆われ/切れ/不在なら偽陽性として失敗に反転。
- **`requireVisible: false`**: occlusion 確認を省く(FM を一切呼ばない・ツリー一致のみ)。
- **配線**: `FlowStep.occlusionGuard: Bool?`([Flow.swift](../Sources/FTCore/Flow.swift))を DSL 引数が true/false で
  立て、[StepExecutor.occlusionFlip](../Sources/FTCore/StepExecutor.swift) が `step.occlusionGuard ?? executor 既定`
  で判定。executor 既定は false のまま(api/record 経路や raw FlowStep=nil は非ガード)。
- **安全策**: FM 未配線(不可)時は guard も素通り(pass)= `requireVisible: false` と同一挙動。足切りで
  非テキスト型(アイコン/画像/絵文字)は自動除外、高インク領域は FM を呼ばない(コスト最小化)。
- **ソース契約**: 逆写像コード生成(既定=引数省略 / オプトアウト=`, requireVisible: false`)・VSCode パラメータ
  編集(`requireVisible` bool・既定 true)を exist/textIs/valueIs に登録。
- **テスト**: 反転/pass/オプトイン(raw exists=nil は FM 不呼出)を StepExecutorTests、各コマンドの
  パラメータ解析・オプトアウトを StepCommandParamsTests で検証(全 green)。

> **命名の経緯**: 当初 `visible()`(別コマンド)→ 実機で誤反転が多く不採用。次に `exist`(既定ガード)+`present`
> (ツリーのみの別コマンド)→ テキスト系に対を持てず非対称。最終的に**全コマンド共通の `requireVisible` 引数**に統一。
> `occlusionGuard` は専門用語で不採用、`visible: false` は「非表示を検証」と誤読されるため不採用。

> **コスト注意**: 既定 ON により各アサーション通過で **スクショ 1 枚**(+疑わしい低インク領域のみ FM ~1.6s)が乗る。
> 可視テキストが多い通常画面は高インクで FM を呼ばないため増分は小さいが、大量に検証を回すシナリオでは
> 可視性が不要な箇所を `requireVisible: false` にするのを推奨。
> 未了: (a)`textIs` 等への guard 付与は未実施。(b)explore 自動生成は guard を明示しない(既定に従う)。

## 5.11 実行時配線の修正 + エンドツーエンド実機確認(2026-07-22)

**配線バグ修正(重要)**: 実ランナーの `LazyFMDelegate`([ScenarioRunnerMain.swift](../Sources/FTScenarioRunner/ScenarioRunnerMain.swift))が
新メソッド `verifyElementVisible` を転送しておらず、実シナリオ実行では `exist` のガードが `ReplayDelegate`
既定実装(nil)に落ちて**黙って素通り**していた(=機能が実行時に無効)。転送を追加して実効化。

**E2E 実機確認**: 実ランナーと同一構成(`StepExecutor` + `FMReplayDelegate`)で、A012ADD8 の
商品詳細画面(sticky「カートに追加」バー裏に「レビュー」= 実オクルージョン)に対し実行:

| 実行 | 結果 | 判定 |
|---|---|---|
| `exist("レビュー")`(既定ガード・覆い) | **failed**「偽陽性(occlusion): …[covered] 領域が不透明な要素に覆われている」 | ✓ 実オクルージョンを失敗へ反転 |
| `exist("レビュー", requireVisible: false)`(ガード無) | passed | ✓ ツリー存在のみで通過 |
| `exist("在庫あり")`(可視) | passed | ✓ 可視テキストは誤反転せず通過 |

→ **ランタイム経路(StepExecutor.execute → occlusionFlip → FMReplayDelegate.verifyElementVisible →
OcclusionVerifier)が実機で機能することを確認**。これで PoC は 合成 → 実機誤反転修正 → 実機TP → DSL →
配線 → E2E まで一通り実証済み。

## 5.12 poll-until-visible: 過渡的オーバーレイでの誤失敗を回避(2026-07-22)

当初は「pass 確定の一点で1回」ガードを実行し、その瞬間に覆われていると即失敗していた。これは
**ローディング表示・スナックバー・遷移アニメ等の過渡的オーバーレイ**で誤失敗を招く(消えるはずの覆いで落ちる)。
`exists`/`textEquals` の poll ループを、要素が見つかっても覆われている間は即失敗せず、既存の
「出現待ち」意味論と同様に **timeout まで可視化を待つ**よう変更([StepExecutor.swift](../Sources/FTCore/StepExecutor.swift))。

- 覆い判定は `lastOcclusion` に保持し、可視化されれば pass、timeout まで覆われ続ければ occlusion 失敗を返す。
- コストは足切り+低インクゲートで従来どおり抑制(可視な高インク領域は FM を呼ばず即通過)。覆われ続ける
  場合のみ timeout 窓内で数回 FM(実測 median≈1.6s/回。既定 5s 窓で ~3 回)。
- テスト: 過渡的(covered→visible)は pass、覆われ続けは timeout で occlusion 失敗、を StepExecutorTests で検証。
- 実機 E2E 再確認: sticky バー裏「レビュー」の `exist` は依然 failed(可視化されないため timeout で反転)、
  `requireVisible: false`/可視テキストは pass(無回帰)。

## 5.13 textIs / valueIs も既定 occlusion-guard 化(2026-07-22)

`exist` と揃え、`textIs` / `valueIs` も**既定で可視性確認あり**(一致かつ実際に見えていること)に。
オプトアウトは共通の `requireVisible: false`(§5.10 参照。当初は `exist`=present / テキスト系=引数 と
非対称だったが、最終的に全コマンド共通の `requireVisible` 引数へ統一)。内部の `FlowStep.occlusionGuard`
フィールドは実装名として据え置き。

- 機構は既存の textEquals/valueEquals 経路の occlusionFlip をそのまま使用(poll-until-visible も適用)。
- ソース契約: codegen(オプトアウト時のみ `, requireVisible: false` を付与)・VSCode パラメータ編集
  (`requireVisible` bool・既定 true)を textIs/valueIs に登録。FTElement チェーン(`.textIs`/`.valueIs`)も対応。
- テスト: textEquals 経路のガード反転(StepExecutorTests)、textIs/valueIs のパラメータ解析・オプトアウト
  (StepCommandParamsTests)を検証(全 green)。

これで存在系(`exist`)・一致系(`textIs`/`valueIs`)とも既定で「見えていること」を確認する。
`present` は存在系のツリーのみ版、テキスト系は `occlusionGuard: false` がオプトアウト。

## 5.14 スクショ再利用: 操作を挟まない連続ガードで往復(~125ms)を回避(2026-07-22)

実測(§crop 検討)で、ガード発火のたびに全画面スクショ往復 **~125ms** を払っていた。**操作を挟まない
連続ガード**(`exist` を並べる等、同一静止画面)では 1 枚を使い回して往復を省く。

- StepExecutor に `cachedScreenshot` を持ち、occlusionFlip の取得を `guardScreenshot()` 経由に。
- **無効化**(古いスクショの再利用防止): ① action(tap/type/swipe 等= executeAction 冒頭)
  ② performCustom(launch/wait/procedure = executor をバイパスするため [FTRuntime](../Sources/FTDSL/FTRuntime.swift) から
  `invalidateScreenshotCache()` を呼ぶ)③ poll 待機ごと(poll-until-visible で画面が変わり得る)
  ④ **200ms TTL**(静止画面前提の staleness 上限)。
- 効果: 連続する N 個の可視ガードが **スクショ 1 回**で済む(従来 N 回)。実測往復 ~125ms/回なので
  例: 連続 5 ガードで ~500ms 削減。FM が絡む場合は FM 側が支配的なので効果は相対的に小。
- テスト: 連続ガードでスクショ 1 回に集約 / 操作を挟むと取り直す、を StepExecutorTests で検証(count で確認)。
  実機 E2E 無回帰(覆い→failed / 可視→passed)。poll-until-visible とも両立(待機ごとに取り直すため覆いは再判定)。

## 5.15 レビュー反映(別セッションのレビュー・2026-07-22)

- **#1 座標系の食い違い(要修正・中)**: textEquals/valueEquals がフォールバックドライバ(SystemUI/springboard)
  由来の要素に一致した場合、その frame/screen は primary と別座標系なのに occlusionFlip へ primary の
  snapshot/screenshot を渡していた(FM に別アプリのスクショ+システム要素を渡し偽陽性化しうる)。
  → **fsnap 由来一致はガードをスキップ**(exist の fsnap 経路と同契約)。`fromFallbackDriver` で判定。
- **#2 結合 `, ` 規則の過剰適用(低〜中)**: `textIs("#x", "Hello, World")` のような正当な句読点入り期待値が
  結合セマンティクス扱いで黙って素通りしていた。→ eligibility に `isUserText` を追加し、**ユーザー期待値
  (textEquals/valueEquals)には `, ` 規則を当てない**(型・絵文字の規則は維持)。
- **#5 stale occlusion(軽微)**: 覆い観測後にテキストが不一致へ変化して timeout すると、実態(不一致)を
  隠して古い occlusion 失敗を返していた。→ **`actual != expected` を観測したら `lastOcclusion` をクリア**。
- **#3 既定 ON の是非(設計判断)**: exist/textIs/valueIs の既定 ON は全既存シナリオの検証意味論を変える。
  三段ゲート+スクショ再利用で実コストは抑制済み。**ユーザー決定で「既定 ON のまま」本流方針とする**
  (2026-07-22 確定)。オプトアウトは `requireVisible: false`。
- **#4 TTL 200ms / 良い点**: 指摘どおり論理健全・コメントに根拠あり(変更不要)。

テスト追加: #1 fsnap 一致でガード不呼出 / #2 eligibility の isUserText / #5 不一致時に occlusion を返さない
(StepExecutorTests・全 green)。

## 6. 既知の限界

1. **合成フィクスチャでの計測**。実機スクショ(半透明シート、影、アンチエイリアス、動的コンテンツ)は
   未検証。次段で sut-ec-mobile の実オーバーレイ画面で再計測すべき。
2. **Compose iOS の frame クランプ画面では無力**。クロップ先の frame 自体が嘘([compose-ios-ax-frame-clamp])
   なので、退化 frame は `occlusionFlip` がスキップする実装にした(素通り=従来動作)。この画面群は
   本ガードの対象外と割り切る。
3. **判定不能時(FM 不可・画像不正)は素通り**。ガードは「積極的に偽陽性を潰す」だけで、可用性は落とさない。
4. **coveredPartial の閾値は主観**。65% 覆いを「見えない」と定義。どこまでを許容するかは要件次第。
5. **poll 挙動**。現状は「ツリー一致の一点で1回照合し、不可視なら即失敗」。過渡的オーバーレイ
   (スピナー等)を待ちたいなら「可視になるまで poll、timeout で失敗」に変える余地(FM コール増)。

## 7. 推奨(実機計測を踏まえ改訂)

実機で **unconditional FM は約50%誤反転**する事実が判明したため、当初の楽観的推奨(cropped を広く採用)
を**取り下げる**。改訂版:

1. **unconditional FM は不可**。全 assert 通過で FM を呼ぶ運用は実 UI で誤反転が多すぎる。
2. **FM は必ずゲート越し**。`occlusionInkThreshold`(既定 12)未満の低インク領域だけ FM に回す。
   これで実運用の誤反転をほぼ 0 にできる(実機で確認)。`occlusionGuard` 既定 OFF、限定 ON を推奨。
3. **FM に回す前に要素種別・省略で足切りする**(次段の必須タスク):
   - 対象は「label が verbatim 描画されるテキスト要素」に限定。**アイコン/画像/結合セマンティクス
     (label に区切りの `, ` を含む合成ノード)/絵文字単体は除外**。
   - **省略対策**: 期待テキストが末尾省略され得る場合、完全一致でなく「先頭一致/省略記号許容」で
     判定するか、そもそも FM 判定から外す。
4. **本採用の前提**: 上記 3 の足切り実装 → 再計測 → 実オーバーレイ(モーダル/シート/キーボード)での
   true-positive 確認(今回キーボードが上がらず未取得)。DSL 露出(`assertVisible` 等)はその後。
5. state 分類は判定に使わない(diagnosis ログのみ)。判定に使うのは `visible` bool と 2 段ゲートのみ。

**結論(2026-07-22 更新)**: 「疑い時だけ FM」ゲート + **要素足切り(非テキスト型/結合/絵文字を除外)**
+ **省略許容プロンプト**の3点を揃えれば、実機で有害誤反転 0%・レイテンシ median≈1.6s を達成できた。
これらは全て実装・結線済み([OcclusionEligibility](../Sources/FTCore/OcclusionEligibility.swift)・
[RegionInk](../Sources/FTCore/RegionInk.swift)・[OcclusionSuspicion](../Sources/FTCore/OcclusionSuspicion.swift)・
[OcclusionVerifier](../Sources/FTAgent/OcclusionVerifier.swift)・StepExecutor.occlusionFlip)。

**実機 true-positive も取得済み(§5.9)**: スナックバー occlusion で「¥24,000」が visible→covered に
正しく反転、sticky バー裏の「レビュー」も安定検知。実機で **誤反転 0 かつ 実 occlusion 捕捉**を両立できた。

残タスクは **①高インク下の部分覆いの取りこぼし**(Tier-0 幾何で一部補完・原理的限界あり)、
**②snapshot/screenshot の非原子性**(アニメ中は整定後に実行・§5.9 の罠)。
**③DSL 露出は実装済み**(§5.10 `visible()`)。これらを踏まえれば実採用の目処は立った。
単体の FM を無差別に当てる案は引き続き非推奨。

**採用形の推奨まとめ**: `occlusionGuard` をノブ提供(既定 OFF・画面/シナリオ限定 ON)、判定は
`eligible(足切り) → 低インク or Tier-0幾何(疑い) → FM(cropped・省略許容) → visible判定`の順。
整定後の assert 一点で1回だけ実行。state は診断ログのみ。

## 8. 再現手順(計測ハーネス)

計測に使った単体ハーネス `ftester-poc-occlusion`(合成フィクスチャ計測+実機駆動の
live/dump/explore/occtest/e2e モード)は **PoC ブランチ `poc/fm-occlusion-verify` の履歴に保存**され、
本流(main)には含めていない(実機を hardcoded フローで駆動する調査足場のため)。再計測が必要なら
当該ブランチから `Sources/ftester-poc-occlusion/` と Package.swift の該当ターゲットを取り出す:

```
git show poc/fm-occlusion-verify:Sources/ftester-poc-occlusion/main.swift
swift build --product ftester-poc-occlusion   # ターゲット復元後
.build/debug/ftester-poc-occlusion <出力ディレクトリ>   # 合成計測
.build/debug/ftester-poc-occlusion e2e <udid> <bundleID> <port>   # 実機 E2E
```

[compose-ios-ax-frame-clamp]: ./design.md
