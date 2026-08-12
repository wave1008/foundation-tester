# MCP の使い勝手を測る(まっさらなエージェントのタスク完了)

**評価者を替えるための道具**(2026-08-12)。それまでの評価は「フルコンテキストの私が応答を読んで
違和感があるか」だった。バグは有限なので監査を重ねれば減衰するが、**「もっと分かりやすく
言えたはず」は無限に出る**ので、その評価軸では注記も分岐も単調に増え続ける(実際そうなった)。

ここで測るのは**そのアプリを初めて触るエージェントが、タスクを終えられたか・何手かかったか**。
注記を1本足すか消すかは、この手数が動いたかどうかで決める。

```
Scripts/mcp-bench.sh --list
Scripts/mcp-bench.sh --task cmp-scroll-find --repeat 3
# A/B: duplicateIDsNote を落とした版と比べる
Scripts/mcp-bench.sh --task cmp-scroll-find --repeat 5 \
  --variant full= --variant no-dupids=duplicateIDsNote
```

記録は `.ftester/bench/<日時>/`(生の stream-json・`summary.json`・`bench.log`)。

## 読み方

| 列 | 意味 |
|---|---|
| `ok` | 完了した run / 総 run。**最終行の `RESULT:` を `expect` で照合**した結果(自己申告ではない) |
| `tools` | ft_* の呼び出し回数の中央値。**これが主指標** |
| `snaps` | `ft_snapshot` + `ft_batch` の回数。注記が減らすべきは主にここ(木の読み直し) |
| `err` | `isError` で返った回数 |

差分は**両方が全 run 完了した task だけ**を比べる(手数が少ないのは早々に諦めたからかもしれない)。
`tools +3` は「その注記を落としたら手数が3増えた = 注記は効いていた」と読む。

## 判定の規律

- **1回のグリーンで判定しない**。`--repeat` は最低3、差が小さいなら5以上
- **陽性対照を先に確かめる**: `--variant` を渡した run は、サーバが起動時に
  `FT_MCP_NOTES_OFF: silencing …` を stderr へ出す(`bench.log` に残る)。
  これが出ていない run の A/B は無効(黙らせたつもりで黙っていない)。
  綴りを間違えた鍵は `NOT a note key (ignored)` として名指しされる
- **差が出ないときは実験系を疑う**。ビルドは毎回 `swift build --product ftester-mcp` を通すが、
  タスク・盤面・デバイスが変わっていれば手数は簡単に動く
- **CLAUDE.md の無い作業ディレクトリで走らせている**(`<out>/cwd`)。保守者向けの指示を
  読んだエージェントは「まっさらな読み手」ではない

## タスク

| id | archetype | 何を代表するか |
|---|---|---|
| `cmp-scroll-find` | dense-list | スクロール容器の中の探索(縦リスト + 横カルーセルが同居する画面) |
| `cmp-text-input` | form | 入力とソフトキーボードの遮蔽 |
| `cmp-noid-directional` | no-id | id を公開しないアプリ(方向セレクタしか使えない) |
| `cmp-webview-aria` | webview | `#id` が効かない画面・`aria-label` 由来のラベル(内蔵 HTML なので通信に依存しない) |
| `maps-route` | map | 実アプリ・高密度・システムアプリ(xcuitest ブリッジが要る) |
| `ios-settings-about` | settings | 実アプリ・深い設定ツリー(2階層たどって値を読む) |

自前 SUT の4つは**対照**(盤面が契約で固定されているので手数のブレが小さい)。
`maps-route` だけが実アプリで、**自前 SUT は実アプリの形を代表しない**(遮蔽・積み重なり・
中身外しは実アプリでだけ出る。`Tests/Fixtures/RealAppSnapshots/README.md` 参照)。
**両方を見ること** —— 対照だけだと実アプリの難しさが測れず、実アプリだけだと盤面のブレを
注記の効果と取り違える。

`expect` は**契約から決めた値**(`E2EAppCMP/docs/ui-contract.md`)。SUT の契約を変えたら
ここも変えること。

## アーキタイプを足すとき

**足すならアプリ名ではなくアーキタイプで足す**。スナップショットのコーパスは 2026-08-12 に
19 枚(地図 14)→ 25 枚(地図 14 + settings 2 + chat/keypad/media/webview 各1)へ広げ、
それだけで**「地図でしか出ない」と見えていた注記5本のうち3本が他アーキタイプでも出た**
(`Tests/Fixtures/RealAppSnapshots/README.md`)。1アプリを深く掘るより、初見のアーキタイプを
1つ足すほうが1件あたり安い。

タスク側は 2026-08-12 に settings と webview を足して **実アプリ2 + 自前 SUT 4**。
コーパスにあってタスクに無いアーキタイプは **chat / media / keypad**。

**監査ラウンドとの関係**: 監査(docs/mcp-audit-rounds.md)で初見のアプリを触ったら、
フィクスチャを1枚採るのと同じ流れでここへタスクを1本足す。そうすると
「そのアーキタイプで手数が減ったか」を次の変更のときに測れる。

## ここで測れないもの(2026-08-12 時点の穴)

**実 web ページを相手にする注記は、いまのタスク集合では手数を測れない**。タスクは
通信に依存しない盤面だけで組んでいる(`cmp-webview-aria` は内蔵 HTML)ので、
「a11y ツリーが実際に取りこぼす」形 —— 格子の見出し行の欠落・アドレスバーのリダイレクト ——
を再現する offline の盤面が無い。`gridWithoutHeaderNote` / `addressBarNote` はこのため
**手数の差ではなく「実機の witness + 固定コーパス 33 枚で誤検知0」を根拠に入れた**。
埋めるなら E2E-CMP の内蔵 HTML に「見出しを a11y へ出さない表」を足すのが筋だが、
SUT の契約(`E2EAppCMP/docs/ui-contract.md`)を 5 SUT ぶん動かすことになるので未着手。
**ライブの web を叩くタスクは足さない**(盤面が毎日変わり、手数の差が注記の効果と混ざる)。
