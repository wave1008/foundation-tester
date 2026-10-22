# 結果を読み、失敗を調べる

[in English](investigating_failures.md)

テストを実行するたびに、成否を問わず結果が残ります。読むのも AIアシスタントに任せられます。
fleetest が記録するのは、どの段階で・どの操作が・どう失敗したかという事実だけで、原因は決めつけません。

## 1. 結果を要約してもらう

### AIへの指示文

```text
fleetest のテストプロジェクト myshop の直近の実行結果を要約し、失敗があれば、失敗したシナリオと落ちた手順を一覧にして。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

- `TestProjects/myshop/reports/` にシナリオごとの Markdown レポートがあります。
- VSCode では Test Explorer が成否を直接表示し、そこからレポートを開けます。
  コマンド「fleetest: 結果ダッシュボードを開く」で、実行の履歴と成功率も見られます。

</details>

## 2. 失敗の原因を調べてもらう

### AIへの指示文

```text
fleetest のテストプロジェクト myshop の直近の実行で落ちたシナリオについて、レポートから原因を調べて。
アプリの不具合らしいのか、テストの書き方の問題らしいのかも分けて報告して。
シナリオはまだ直さないで(期待値をアプリに合わせて通すこともしないで)。
```

- 「直さないで」を必ず添えます。調査と修正を同時に頼むと、アプリの不具合で落ちたテストが、期待値をアプリに合わせる形で通されてしまうことがあります。
- 報告を読んでから、直すかどうかをあなたが決めます。

見えるもの: レポートには失敗した手順・失敗メッセージ・失敗した瞬間の要素一覧とスクリーンショットが載ります(下はサンプルアプリの例)。

<img src="../images/tutorial/ja/report_failure.png" width="600" alt="失敗したレポートの抜粋。落ちた手順と失敗メッセージ、失敗した瞬間の要素一覧(折りたたみ)とスクリーンショットが載っている">

### 原因の見当がついたら

- アプリの不具合: テストはそのままにして、アプリを直したら次の指示で確かめます。

```text
fleetest のテストプロジェクト myshop で、前回落ちたシナリオだけを実行し直して。
```

- 画面が変わってテストが古くなった: [追従させる](keeping_up_with_app_changes_ja.md)
- 出たり出なかったりするダイアログが割り込んだ: [アプリの変更にテストを追従させる](keeping_up_with_app_changes_ja.md)の「新しい割り込みが増えたとき」
- よく分からない:

```text
fleetest のテストプロジェクト myshop の〇〇のシナリオを5回実行して、落ちる回と通る回で何が違うかを調べて。まだ直さないで。
```

## 3. 不安定なテストを見つける

### AIへの指示文

```text
fleetest のテストプロジェクト myshop の過去の実行結果から、通ったり落ちたりする不安定なシナリオと、遅くなってきたシナリオを洗い出して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest results flaky --project myshop      # 成功も失敗もするシナリオ
../foundation-tester/.build/debug/fleetest results insights --project myshop   # 退行・連続失敗・遅くなったシナリオ・特定デバイスへの偏り など
../foundation-tester/.build/debug/fleetest results slow --project myshop       # 平均所要時間が長い順
```

</details>

### 見つけた後にすること

#### AIへの指示文

```text
fleetest のテストプロジェクト myshop の不安定なシナリオ〇〇を、壊れにくいシナリオの書き方(待ちの置き方・セレクタ・出るか不定のものの扱い)に沿って直して。
直したら、iOS で5回続けて実行して全部通ることを確かめて。落ちた回があれば、何回目に何で落ちたかを報告して。
```

- 1回通っただけでは直ったと言えません。必ず数回続けて回します。
- Mac が重いと不安定になりやすくなります。デバイスモニターの「ライブ更新」を OFF にして回し直します([VSCode で見る](watching_in_vscode_ja.md)の「Mac が重いとき」)。
- CI ではリトライで隠さず、見つけて直す方針です([CI で回す](../in_action/ci_ja.md))。

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

回数を指定するオプションはありません。シェルのループで、同じシナリオを続けて回します。

```bash
for i in 1 2 3 4 5; do
  ../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run --scenario <クラス名> --quiet || echo "失敗: $i 回目"
done
```

`<クラス名>` は、シナリオのファイル名(拡張子なし)です。各回の末尾にまとめの行が出て、落ちた回だけ続けて `失敗: N 回目` と出ます。

</details>

## 実行の様子を見返す

### AIへの指示文

```text
fleetest のテストプロジェクト myshop の直近の実行のログインのテストの実行ログを見せて。どの手順で何が出たかを順に説明して。
```

録画は既定で有効で、シナリオごとの動画が残ります。VSCode 拡張の「テストセッション」タブで見られます([VSCode で見る](watching_in_vscode_ja.md))。容量を抑えたいときは、そう指示します。

```text
fleetest のテストプロジェクト myshop の iOS の実行で、失敗したシナリオの録画だけ残すようにして。
```

## fleetest 自体の不具合かもしれないとき

AIアシスタントに調べてもらっても原因がツールの側にありそうなら、fleetest の開発者へ報告します。診断情報はどこへも送信されません。

### AIへの指示文

```text
fleetest doctor --bundle fleetest-diag.zip で診断の zip を作って、中身を一覧にして。アプリの画面の文字が入っていないかも確かめて。
```

報告先と、zip を共有する前の注意は[トラブルシューティング](../in_action/troubleshooting_ja.md)にあります。

## もっと詳しく

[テスト結果ファイル](../reference/testclass/test_result_files_ja.md) / [結果の分析](../reference/running/results_analysis_ja.md)

次へ: [アプリの変更にテストを追従させる](keeping_up_with_app_changes_ja.md)

### Link
- [index](../index_ja.md)
