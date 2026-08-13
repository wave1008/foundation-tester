# 計測の記録

**回した bench の結果はここに残す**。生の記録(stream-json・`summary.json`・`bench.log`)は
`.ftester/bench/<日時>/` に出るが、そこは `.gitignore` されているので**結論だけを持ち越す**。
1回の計測 = 1節。**判定に使った陽性対照まで書くこと**(書いていない計測は後から
「黙らせたつもりで黙っていなかった」形と区別が付かない)。

---

## 2026-08-13 `unlabeledClickablesNote` は手数を動かすか

**問い**(docs/mcp-audit-rounds.md の未修正の持ち越し): この注記は Android メッセージの
「新しい会話」画面で偽の主張をする —— `[16] clickable (12,85 126x126)` を
「安定したセレクタで指せない」と言うが、**その内側に一意ラベル「戻る」があり `tap '戻る'` は成功する**。
矩形の**包含**を拾う幾何規則を足すべきか。台帳は「足すなら手数を測ってから」と保留していた。

**回した物**: `and-chat-newconv`(この注記が発火する盤面)/ `and-settings-keyboard`(対照。
Android 設定にこの注記は出ない)。`--repeat 5`・variant は `full` と `no-unlabeled`(= この注記だけ落とす)。

| variant | task | n | ok | tools | snaps | err | wall s |
|---|---|---|---|---|---|---|---|
| full | and-chat-newconv | 5 | 5/5 | 6 | 1 | 0 | 31.1 |
| full | and-settings-keyboard | 5 | 5/5 | 7 | 1 | 0 | 39.0 |
| no-unlabeled | and-chat-newconv | 5 | 5/5 | 6 | 1 | 0 | 33.1 |
| no-unlabeled | and-settings-keyboard | 5 | 5/5 | 7 | 1 | 0 | 35.8 |

**差: tools ±0(両タスク)**。wall の ±2〜3s は n=5 のばらつきの中。

**陽性対照**: `full` の chat の記録には注記が **1 run あたり4回**出ており、`no-unlabeled` では
**0回**(`grep "have neither a label nor an id" <variant>/and-chat-newconv-*.jsonl`)。
つまり落とす操作は効いていて、それでも手数が動かなかった。

**副次(出力バイト)**: tool_result の合計は chat が 6302 → 6218(**約 84 バイト/run**。
注記は2回目以降 `once()` で短縮されるため4回で 84 バイト)。settings は 14893 → 19494 と
**逆に増えた**が、この盤面では注記が1度も出ていないので**探索経路のばらつき**であって
注記の効果ではない。**n=5 のバイト比較は task 間で成立しない**。

**判定**: **幾何規則を足さない**。この注記は、偽の主張をしている盤面ですら手数を1手も動かして
いない —— 正しくして得られる手数は 0 以下である。台帳の持ち越しはこれで閉じる。
**消す判断は保留**: 測ったのは2盤面だけで、`ios-home` / `ios-maps_route_options` では
真陽性として出ている(`SweepHarnessTests`)。**消すならその2形にもタスクが要る**。

---

## 2026-08-13 フォームの「行き止まり」は行き止まりか / `scrollFrameCandidates` は効くか

**問い**: 監査ラウンド(フォーム)で、フォームが伸びると `#buttonPanel` が 1080x12 に潰れ
`保存`/`キャンセル` がツリーから消える形を見つけた。**呼び手は詰むのか**、詰むならキーボード注記に
閉じ方への案内を足すべきか。新設した `and-form-wifi`(Android 設定の「ネットワークを追加」。
オフラインで決定的)で測った。

**測定①(基準・`--repeat 5`)**: **5/5 完了・tools 中央値 13**。詰まらない。回復はどの run も**1手**:

- 2/5 … `ft_scroll_to '#button1'` に **`scrollFrame:"#content_parent"`** を添えて成功
- 3/5 … `ft_navigate back`(Android の戻るキーはキーボードを閉じる)で成功

**この結果は私の報告を否定した。** 「`ft_scroll_to` は届かず助言も当たらない」と書いたが、
`#content_parent` は**ツール自身が `scrollFrameCandidates` で名指ししていた**もので、
**手動プローブが自分の助言に従っていなかっただけ**だった。詰まりを主張する前に、
**自分がツールの出力どおりに操作したかを確かめる**。

**測定②(A/B・`--repeat 5`)**: では、その `scrollFrameCandidates` は手数を減らしているのか。

| variant | n | ok | tools | snaps | err | wall s |
|---|---|---|---|---|---|---|
| full | 5 | 5/5 | 13 | 2 | 0 | 74.8 |
| no-scrollframe | 5 | 5/5 | 13 | 2 | 0 | 80.1 |

**差: tools ±0**(wall の +5.3s は n=5 のばらつき)。**陽性対照**: full では 1 run あたり
**4〜5回**発火し、variant では **0回**(`grep -c "scroll areas on screen"`)。

**判定**: **この盤面では効いていない**。落とすと 5/5 とも `ft_navigate back` に流れるだけで、
**同じだけ安い代替がある**ため。ただし**この注記を消す根拠にはならない** —— 10 フィクスチャ
(map/chat/picker/browser/form)で発火しており、**容器の中でしかスクロールできない画面**
(地図のシート等)では「back で閉じる」という代替が無い。**消すならその形でも測ってから**。

**この2件目で分かった型**: 注記が効いているように見えるのは、**代替手段が無い盤面**でだけ。
A/B を組むときは「その注記が無いと本当に手詰まりか」を先に考える —— 代替がある盤面で測ると、
効いている注記でも必ず ±0 が出る。

---

## 2026-08-13 「セレクタの品質」の軸を足した(手数では測れない側)

**動機**: 注記には読者が2種類いる —— ⒜ いま作業しているエージェント(タスクを終えるための情報)と
⒝ シナリオを書く人(壊れないセレクタを書くための情報)。**⒝ は手数では原理的に測れない**
(エージェントは常に ref で叩けるので、落としても手数は動かない)。出力バイトの主因である
`duplicateIDsNote`(15.1KB)/ `ambiguousLabelsNote`(10.0KB)/ `unlabeledClickablesNote` は
全部 ⒝ で、**bench はカタログの量の大半を判定できないままだった**。

**足したもの**: タスクに `"draft": true` を書くと、台本が「最後に `ft_draft_scenario` で書き戻せ」を
プロンプトへ足す(**指示は台本側に1本だけ** —— タスクごとに文言を書くと A/B の両側で頼み方が
変わる)。`bench-summary.mjs` の `draftQuality()` が下書き本体を読み、
**安定セレクタ / 索引セレクタ / `// TODO: no stable selector`** を数えて `sel ok/weak` 列に出す。
既存タスクは `draft` を持たないので**1バイトも変わらない**(過去の計測と比較可能なまま)。

**空回りしていないことの確認**(`--repeat 3`):

| task | sel ok/weak | 中身 |
|---|---|---|
| `and-form-wifi` | **8/0** | 8手すべて `#ssid` / `#security` / `.clickable&&…` で解決 |
| `and-chat-newconv` | **1/2** | `#start_chat_fab` は解決、無ラベルの戻るボタンと **`ft_type` の手**が TODO |

**この軸で当初やろうとしたことはできない(判明した制約)**: 下書きのセレクタは
**エージェントではなくサーバが選ぶ**(ツール説明「Every step is written with the selector this
server recommended at the time」)。したがって**注記を落としても下書きは変わらない** ——
`duplicateIDsNote` をこの軸で A/B するという当初の狙いは**成立しない**。
注記がこの軸に効く経路は「エージェントがどの要素を狙うか」だけで、間接的。
**軸そのものには価値がある**(探索が「再生できるシナリオ」を産んでいるかの回帰ゲートになり、
盤面ごとの書き取りやすさが出る)が、**カタログを縮める道具にはならない**。ここは正直に書いておく
—— この軸を足した理由が、測ってみたら成り立たなかった。

**初回の使用で欠陥を1件見つけ、直した**: `ft_type` の手が
**id を持つ欄でも下書きで `// TODO: no stable selector — type` になっていた**。

- 再現: Google メッセージの「新しい会話」で `ft_type ref:<#ContactSearchField の ref>` を撃ち、
  `ft_draft_scenario` を呼ぶ。**3/3** の run で TODO
- **退行ではない**(今日の変更前 05545ed でも同じ・2回反復して一致)。
  **`snapshotAfter` の有無も原因ではない**(フォーム盤面は snapshotAfter 付きで
  `type("#ssid", …)` が解決している)
- **機構は推測せず一時計測で押さえた**。`recordInteraction` に観測を差し、実機で:

      REC action=tap  ref=14 refs=1,2,3,…    → 引ける
      REC action=type ref=21 refs=26,27,28,… → 引けない(木が入力後の世代)

  `lastSnapshots` は「最後に読んだ木」であって「その ref が属する木」ではない。
  `ft_type` は入力の読み返しと `snapshotAfter` を**記録より先に**通すので、記録時点では
  ref が別世代の番号になっていた
- 修正は `MCPServer.namingSnapshot`(純粋関数)——**ref が属する世代の木で名付ける**。
  実機で **2/2** が `type("#ContactSearchField", …)` になった
- **新しい軸がそのまま回帰ゲートになった**: `and-chat-newconv` の `sel ok/weak` が
  **1/2 → 2/1**(残る1は無ラベルの戻るボタン = アプリ側の性質)

**配線も後で守れるようにした**(同日。当初は「守れていない」と書いたが訂正)。
偽ドライバで流れが再現しなかったのは、**台本が `value` だけを変えていた**から ——
`adoptSnapshot` は identity(ref/type/identifier/label)が同じなら世代を使い回すので
ref が進まず、**欠陥そのものが起きなかった**。実機では入力後に候補一覧が現れて顔ぶれが
変わるので世代が進む。台本を実機の形(要素が増える)に直したら**変異 2/2 を検出**。
**この罠は `FakeDriver.scriptedSnapshots` の doc に書いた** —— 知らずに value だけ変える
台本を書くと、流れのテストが黙って空回りする。

---

## 2026-08-13 実際の run で「どの注記が何バイト出ているか」を測った

**動機**: カタログを縮めたいのに、**削る候補を「実際に出ている量」で並べられなかった**。
`NoteCoverageTests` は固定コーパスに対する**満額**のバイト数で、実運用の頻度を含まない。
`bench-summary.mjs` に `noteCost()` を足し、記録に残っている tool_result から
注記行(`note:` / `caution:` / `⚠️`)を拾って**署名ごとにバイトを畳む**ようにした
(鍵との写像は持たない —— 二重管理は必ずズレる)。**デバイス時間はゼロ**で、
既に取ってある記録に後から流せる。

**`and-form-wifi`(5 run・合計 15,870 B)**:

| バイト | 回数 | 注記 |
|---|---|---|
| 3255 | 31 | `long labels are shown cut off with "…"`(**短縮形が 6回/run**) |
| 2480 | 20 | `2 scroll areas on screen: #content_parent …` |
| 1795 | 5 | `this tree was read immediately after the action …` |
| 1760 | 22 | `the soft keyboard covers (0,1541 1080x883) …` |
| 1655 | 5 | `these ids are shared by multiple elements …`(初回の満額) |

**`and-chat-newconv` + `and-settings-keyboard`(20 run・合計 19,481 B)**:

| バイト | 回数 | 注記 |
|---|---|---|
| 7180 | 20 | `this tree was read immediately after the action …`(**359 B × 1回/run**) |
| 3471 | 39 | `duplicate ids — write one of these instead …` |
| 3310 | 10 | `these ids are shared by multiple elements …` |

**分かったこと**: **実現コストの順位は、固定コーパスの満額バイトの順位と違う**。
カタログのコメントは主因を `duplicateIDsNote`(15.1KB)/ `ambiguousLabelsNote`(10.0KB)と
書いているが、実際の run で最も多く出ているのは:

1. **`this tree was read immediately after the action`** —— `snapshotAfter` を使うたびに
   **359 B を毎 run 満額で**払う静的な但し書き
2. **`long labels are shown cut off`の短縮形** —— 1回 105 B が **6回/run** 繰り返される
   (`once()` で短くはなっているが、**短縮形でも 100 B 級**で、しかも毎回出る)

どちらも**画面の中身に依らない定型文**で、**削る/短くする判断が手数と独立に立てられる**
(「この但し書きが無いと手詰まりになる」形が想像しにくい)。

**同日に削って測り直した**(`and-form-wifi`・`--repeat 5`):

| 注記 | 1回あたり | 変化 |
|---|---|---|
| `this tree was read immediately after the action …` | 359 B → **239 B** | **−33%** |
| `long labels …` の短縮形 | 105 B → **67 B** | **−36%** |

**合計は 15,870 B → 14,890 B(−6.2%)**。ただし合計は run ごとの経路のばらつきを含む
(同じ注記の発火回数が 31→33、20→23 と動いている)ので、**1回あたりのバイトのほうが
きれいな指標**。**挙動は変わっていない**: 完了 5/5、`sel ok/weak` は 8/0 のまま、
手数は 13 → 14(この task は 12〜14 で揺れており n=5 の範囲内)。

**落としたもの**: ⒜ 「不変に見えたら1回だけ待って撮り直した(上の注記を見よ)」——
**それが実際に起きた回には settle-lite の注記そのものが出る**ので二重だった
⒝ 短縮形の「最初の注記を見よ」—— 短縮形なのに満額の指示を繰り返していた。
**残したのは行動に要る部分だけ**(「操作直後の木である」「`waitFor` で確かめてから無いと言え」
「`*prefix*` で書け」)。

**次の候補**(同じ理由で削れる可能性): `2 scroll areas on screen …`(2,852 B / 23回)と
`the soft keyboard covers …`(1,920 B / 24回)。どちらも**毎回同じ形**で出る。
ただし前者は**代替手段が無い盤面がある**(容器の中でしかスクロールできない画面)ので、
消すのではなく**短くする**側で測ること。

---

## この計測で見つかった bench 側の欠陥(修正済み)

- **`--out` に相対パスを渡すと 20 run すべてが起動しない**。run は `cd "$CWD"` してから
  `claude` を起動するので、相対の `--mcp-config` は cwd 側で解決されて必ず見つからない。
  それでも `claude` は 1 イベントも出さずに終わるので、集計は `0/5` = **タスク失敗と
  見分けが付かなかった**。`--out` を絶対パスへ正規化し、**記録が空の run はその場で名指し**して
  集計の前に「台本の失敗」だと言うようにした
- **README が書いていた陽性対照が届かない**。「サーバが起動時に `FT_MCP_NOTES_OFF: silencing …` を
  stderr へ出すので `bench.log` で確かめる」とあるが、**MCP サーバの stderr は `claude` が
  抱えるので `bench.log` には出ない**(実測 0 件)。効く対照は**記録の中の注記そのもの**を
  数えること(上の陽性対照)。README を直した
