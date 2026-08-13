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
