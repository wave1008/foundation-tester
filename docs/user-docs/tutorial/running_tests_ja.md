# テストを実行する

[in English](running_tests.md)

作ったテストを実行します。実行そのものに AI は使いません(シナリオはコードとして決定的に再生されます)。
ここでは、クイックスタートと「テストを作る」で作ったテストを iOS で回します。

## 1. デバイス無しで確かめる(dry-run)

### AIへの指示文

```text
fleetest のテストプロジェクト project1 のシナリオを全部 dry-run で検証し、警告があれば一覧にして報告して。
```

デバイスを起動しないので数秒で終わります。

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --project project1 --dry-run
```

VSCode では Test Explorer でシナリオを選び、「実行 (dry-run)」を使います。

</details>
<br>

見えるもの: 警告が無ければ、問題が無いと報告されます。

## 2. 実行する(2台で並列に)

### AIへの指示文

```text
fleetest のテストプロジェクト project1 のシナリオを全部 iOS(ios-run)で実行し、終わったら成否を報告して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
# 全部
../foundation-tester/.build/debug/fleetest run --project project1 --profile ios-run

# クラス(ファイル)単位・1本単位
../foundation-tester/.build/debug/fleetest run --project project1 --profile ios-run --scenario <クラス名>
../foundation-tester/.build/debug/fleetest run --project project1 --profile ios-run --scenario <クラス名>.<メソッド名>
```

`<クラス名>` はシナリオのクラス名(`scenarios/` 配下の Swift ファイルの中にあります)です。

VSCode では Test Explorer でシナリオを選び、「実行」をクリックします(実行プロファイルはコマンドパレットの
`fleetest: 実行プロファイルを選択` で選びます。1つしか無ければ自動で選ばれます)。

</details>
<br>

見えるもの: `ios-run` には[デバイスを用意する](preparing_app_and_devices_ja.md)で2台を入れたので、シナリオが2台へ自動で振り分けられ、
デバイスモニターの2台がそれぞれ別のシナリオを同時に動かします。終わると成否の一覧が出ます(シナリオ側の変更は要りません)。

<img src="../images/tutorial/ja/parallel_run.png" width="640" alt="6本のシナリオを fleetest が2台のデバイスへ自動で振り分ける">

もっと詳しく: [シナリオの実行(fleetest run)](../reference/running/running_scenarios_ja.md)・[dry-run](../reference/running/dry_run_ja.md)・[並列実行](../reference/running/parallel_execution_ja.md)

次へ: [結果を読み、失敗を調べる](investigating_failures_ja.md)

### Link
- [index](../index_ja.md)
