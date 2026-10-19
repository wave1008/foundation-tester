# 自己修復

[in English](self_healing.md)

自己修復が有効な状態でデバイス実行中にセレクタが解決できなくなると、シナリオを失敗させる前に、
次の順で代わりの要素を探します。

1. **プライマリセレクタ**、続いて**自分で書いたフォールバック**(`a||b`)——通常どおり。
2. **ロケータの指紋** — そのステップのセレクタが直前に直接解決できた要素の型とラベル
   (入力欄はプレースホルダも)を控えておき、今の画面で**ちょうど1件だけ**その指紋に一致すれば
   その要素を使います。「id だけが変わってラベルは同じ」という典型的な変化に決定的に追従します。
   ラベルもプレースホルダも無い要素は控えません(型だけでは要素を特定できないため)。複数の要素に
   一致したときも使いません。

自己修復はロケータの指紋照合だけです。FM(Foundation Models)は呼びません。

## 有効にする

- **`--profile` を使う実行は `heal` の既定が ON** です。プロファイルを使わない素の
  `fleetest run` は既定 OFF です。`fleetest run --profile <name> --set heal=<true|false>` で、
  プロファイルを書き換えずに1回の実行だけどちらの既定も上書きできます(`--set` については
  [running_scenarios_ja.md](./running_scenarios_ja.md)参照)。
- 実行プロファイル自体では、`heal`(既定 `true`)は FM・OCR 系のトグル
  (`fmTextVisibilityCheck`・`screenLooksLike`・`ocrTextVisibilityCheck`)から独立した単独のトグルです
  ([run_profile_ja.md](../project/run_profile_ja.md)参照)。
- VSCode 拡張では、設定 `fleetest.heal` が Test Explorer の「実行」「デバッグ」の呼び出しに
  `--set heal=true` を付与します(「実行 (dry-run)」には付与されません。dry-run はデバイスに
  触れないため)。`fleetest.heal` が `false`(既定)で `fleetest.profile` を使っている場合は、
  実行プロファイル側の `heal` 設定がそのまま使われます。

## 修復が起きたときの挙動

- 修復で通ったシナリオは**成功のまま**です(exit code も `0`)。代わりに、`fleetest run` の最後に
  「self-healing で通ったシナリオが N 本ある」という ⚠️ の行が出ます。`--junit` の JUnit では、そのシナリオの
  `<system-out>` に、修復したステップの数と修正提案(ファイル・行・変更前と変更後のセレクタ)が載ります。
  CI で緑のままセレクタが古くなっていくのを、ここで見つけられます。
- ロケータの指紋で修復した回はキャッシュしません(毎回、指紋で照合し直します)。
  指紋は `TestProjects/<name>/.fleetest/locator-fingerprints.json` に置かれ、そのステップの
  セレクタがそのまま解決できた実行のたびに更新されます。
- 修復が起きた実行のシナリオレポート(`reports/scenario-*.md`)には、ソース位置付きの
  修正提案が出ます。例:

  > `TestProjects/SampleApp/scenarios/LoginTest.swift:17` — change the selector "#email_input" to
  > "#email||.textField[1]" (passed via locator fingerprint matching; reason: matched by locator
  > fingerprint (type+label))

  レポートの文は英語です。書き戻された後の実行は新しいセレクタで直接解決するので、修復は起きません。

- 一致した要素に一意に書けるセレクタが無いときは、操作自体は続行しますが修正提案は出しません。

## ソースへの自動書き戻し

実行の最後に、修正提案(ファイル・行・変更前・変更後のセレクタが揃ったもの)を**シナリオの
`.swift` ソースへ自動で書き戻します**。プロジェクトを git で管理している前提です。差分を
`git diff` で確認してコミットしてください(ツールはコミットしません)。

- **書くのは結果を受け取った側です。** `fleetest run`(プロファイルの有無を問わない)・
  `fleetest api run`(VSCode 拡張が使う)・MCP の `ft_run_scenario` と `ft_start_run` が書きます。
  リモート実行(`--runner <host>` / フリート)では、結果を集めた発行元の Mac が書きます。
  ランナー機の手元のコピーは書き換えません。dry-run では書きません。
- **機械ごとに分かれる実行**(`--fleet`、デバイスが複数の機械にまたがるプロファイル)では、
  全部の機械の実行が終わってから、全部の提案をまとめて1回だけ書きます。
  別々の機械で同じ場所に違う提案が出たときも、その場所には書きません。
- **書き戻しの規則**:
  - 変更前のセレクタが、その行に Swift の文字列リテラルとしてちょうど1回出現するときだけ、
    変更後のセレクタに置き換えます。
  - 同じ場所(ファイル・行・変更前セレクタ)に別々の変更後セレクタが提案されたとき(同じシナリオを
    複数のデバイスで実行して、別々の要素に一致した場合など)は、その場所には何も書きません。
  - 同一の提案は1回だけ書きます。
  - このプロジェクトの `scenarios/` フォルダの外のファイルと、シンボリックリンクのファイルには書きません。
  - 行に変更後のセレクタがすでにあり変更前が無いときは、書き込み済みとして扱います(エラーにしません)。
  - ビルド後にユーザーがファイルを編集して行が変わっていたときは書かず、理由を報告します。
- 同じプロジェクトへ書く実行が同時に走っても、ロックファイル
  `<プロジェクト>/.fleetest/heal-writeback.lock` で直列化されます。
- レポートと `--junit` の `<system-out>` には、書き戻しの有無にかかわらず修正提案が載ります。

実行の出力には、既存の ⚠️ の行のあとに次の行が出ます(`fleetest api run` では標準エラー出力)。

```text
✏️ Self-healing wrote 1 selector fix(es) back to the scenarios — review them with git diff and commit:
   - scenarios/LoginTest.swift:17: "#email_input" → "#email||.textField[1]"
```

書けなかったものは次の形で理由とともに出ます。提案はシナリオレポートに残ります。

```text
⚠️ Self-healing could not write 1 selector fix(es) back (the suggestions stay in the scenario reports):
   - scenarios/LoginTest.swift:17: <reason>
```

書き戻したくないときは、自己修復を切ります(`--set heal=false`、または実行プロファイルの `heal: false`)。

### VSCode 拡張

dry-run ではない実行が修復の提案を出して終わると、VSCode 拡張は直したセレクタの件数を通知します。
書き戻した結果と書き戻せなかったものは実行ログに出ます。「変更を表示」ボタンで VSCode のソース管理ビューが開くので、
git の差分を確認してコミットしてください。

### Link
- [index](../../index_ja.md)
