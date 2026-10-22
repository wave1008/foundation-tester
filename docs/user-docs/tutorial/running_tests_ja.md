# テストを実行する

[in English](running_tests.md)

作ったテストを実行します。実行そのものに AI は使いません(シナリオはコードとして決定的に再生されます)。

## 1. デバイス無しで確かめる(dry-run)

### AIへの指示文

```text
fleetest のテストプロジェクト myshop のシナリオを全部 dry-run で検証し、警告があれば一覧にして報告して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --project myshop --dry-run
```

VSCode では Test Explorer でシナリオを選び、「実行 (dry-run)」を使います。

</details>

## 2. 実行する

### AIへの指示文

```text
fleetest のテストプロジェクト myshop のシナリオを全部 iOS で実行し、終わったら成否を報告して。
```

1本だけ・一部だけを動かすときは、テストの名前や画面で指定します。

```text
fleetest のテストプロジェクト myshop のログインのテストだけを Android で実行して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
# 全部
../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run

# クラス(ファイル)単位・1本単位
../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run --scenario LoginTest
../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run --scenario LoginTest.S0010
```

VSCode では Test Explorer でシナリオを選び、「実行」をクリックします(実行プロファイルはコマンドパレットの
`fleetest: 実行プロファイルを選択` で選びます。1つしか無ければ自動で選ばれます)。

</details>
<br>

## 3. 複数のデバイスで速く回す

### AIへの指示文

```text
fleetest のテストプロジェクト myshop のシナリオを、実行プロファイル ios-run の全デバイスに振り分けて並列に実行して。
```

実行プロファイルに複数のデバイスが入っていれば、シナリオ側の変更なしで自動で振り分けられます。デバイスの増やし方は[アプリとデバイスを用意する](preparing_app_and_devices_ja.md)。

<img src="../images/tutorial/ja/parallel_run.png" width="640" alt="6本のシナリオを fleetest が3台のデバイスへ自動で振り分ける">

全部のデバイスで同じシナリオを1回ずつ動かしたいとき(機種ごとの見え方を比べたいときなど)は、そう指示します。

```text
fleetest のテストプロジェクト myshop のログインのテストを、iOS の全デバイスで1回ずつ実行して。
```

## 4. 落ちたテストだけ実行し直す

### AIへの指示文

```text
fleetest のテストプロジェクト myshop で、前回 iOS で落ちたシナリオだけを実行し直して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run --failed
```

</details>

## 失敗したときの動き

### AIへの指示文

```text
fleetest のテストプロジェクト myshop のシナリオのうち、送信・購入・登録のような取り消せない操作を含むものを洗い出し、
テスト用の決済・ステージングのサーバーに向いているか確認して。
```

- 1か所でも失敗すると、そのシナリオの残りは実行せず打ち切ります。他のシナリオは続きます。
- 失敗した操作を自動で撃ち直すことはしません。
- ただし、デバイスの不調で結果を信用できないときは、シナリオを最初から丸ごとやり直すことがあります。**送信・購入・登録のような取り消せない操作は、1回の実行の中で2回行われることがあります**。2回行われても困らない相手(テスト用の決済・ステージングのサーバー)に向けてください([CI で回す](../in_action/ci_ja.md)・[壊れにくいシナリオの書き方](../reference/writing/writing_robust_scenarios_ja.md))。
- 画面の ID が変わった程度の変化は自己修復が吸収し、実行の終わりに直したセレクタがシナリオのソースへ自動で書き戻されます。git で差分を確認してコミットします([アプリの変更にテストを追従させる](keeping_up_with_app_changes_ja.md))。

失敗の調べ方は[結果を読み、失敗を調べる](investigating_failures_ja.md)。

## 別の Mac・CI で回す

[リモート実行](../fleet/remote_runners_ja.md)・[CI で回す](../in_action/ci_ja.md)

## もっと詳しく

[シナリオの実行(fleetest run)](../reference/running/running_scenarios_ja.md)・[dry-run](../reference/running/dry_run_ja.md)・[並列実行](../reference/running/parallel_execution_ja.md)・[アプリが依存するサービス](../reference/writing/services_ja.md)

次へ: [結果を読み、失敗を調べる](investigating_failures_ja.md)

### Link
- [index](../index_ja.md)
