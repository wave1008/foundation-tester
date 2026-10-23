# テスト結果に何が残るかを確かめる

[in English](test_outputs.md)

テストを実行すると、Mac のディスクにレポート・結果・ログ・録画が残ります。そこには**アプリの画面の文字**
(ボタンのラベル・入力した値・表示された本文)が含まれます。このページは、何がどこに残るかを実際に開いて確かめ、
秘密を伏せ、外へ送る前に中身を確かめ、不要になったものを消すまでの手順です。
[クイックスタート](../quick-start_ja.md)のステップ 7 まで(シナリオを1本作って実行する)を終えていることが前提です。

> データは Mac とデバイスの外に出ません。FM(Apple のオンデバイスのモデル)も Mac の中だけで動きます。
> 詳しくは[品質特性](../overview/quality_ja.md)の「プライバシー」を見てください。外へ出るのは、あなたが zip などを自分で送ったときだけです。

## 1. シナリオを1本回す

クイックスタートで作ったシナリオを実行します。

### AIへの指示文

```text
クイックスタートで作ったシナリオを iOS で実行して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run
```

</details>
<br>

## 2. 残ったものを開いて見る

実行のたびに、次の場所にファイルが増えます(`<プロジェクト>` は `project1` など)。

| 場所 | 中身 | 画面の文字 |
|---|---|---|
| `TestProjects/<プロジェクト>/reports/` | シナリオごとの Markdown レポート(`scenario-*.md`)。失敗したときは、失敗した瞬間の要素一覧とスクリーンショット(`.png`)も並ぶ | ステップの説明にラベルや入力した値が入る。要素一覧は画面の文字そのもの |
| `TestProjects/<プロジェクト>/results/runs/<月>/<runID>/` | `run.json`・`scenarios/<シナリオID>.json`(結果 JSON)・`events/<シナリオID>.ndjson`(シナリオの実行ログ) | 実行ログにステップの説明と `print()` の出力が入る |
| `TestProjects/<プロジェクト>/results/runs/<月>/<runID>/recordings/` | シナリオごとの録画 | 画面に写った文字すべて |

何がどこに出るかの一覧は[テスト結果ファイル](../reference/testclass/test_result_files_ja.md)、結果 JSON の読み方は
[結果の分析](../reference/running/results_analysis_ja.md)にあります。

### AIへの指示文

```text
今の実行で残ったファイルの場所を一覧にして。レポートを1つ開いて、ステップの説明にアプリの画面の文字が入っている行を見せて。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
ls TestProjects/project1/reports/ | tail -3
ls -d TestProjects/project1/results/runs/*/* | tail -1
../foundation-tester/.build/debug/fleetest results log latest
```

`results log latest` は、直近の run のシナリオごとの実行ログを表示します。ステップの行に、タップしたラベルや
入力した文字が並びます。レポートは VSCode で開くとそのまま読めます。

</details>
<br>

期待する結果:

- レポートのステップに `tap "ログイン"` のようにアプリの画面の文字が入っています。
- 録画は VSCode 拡張の「テストセッション」タブで再生できます。
- 録画には画面の文字がそのまま写ります。

## 3. 秘密を伏せる

ログインのパスワードなど、シナリオが使う秘密は `account()` で読むと、レポートに出る文字列から伏せられます
([テストデータ・アカウント](../reference/commands/dataset_ja.md))。既定では伏せません。伏せない状態と伏せた状態を
続けて見比べます。

まず、`account()` を使うシナリオにします。パスワードなどの実際の値は、**この Mac だけの**
`~/.config/fleetest/dataset/<プロジェクト>/accounts.json` に自分で書きます(リポジトリに入れません)。

### AIへの指示文

```text
ログインのシナリオが使うID とパスワードを、account("[account1].id") と account("[account1].password") から読むように直して。
accounts.json は作らなくていい(値は私が書く)。
```

次に、伏せない状態で実行し、パスワードがそのまま残ることを確かめます。

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run
grep -rl 'パスワードの値' TestProjects/project1/reports/ TestProjects/project1/results/ | head
```

`パスワードの値` は、`accounts.json` に書いた実際の値に置き換えます。

続けて、マシン設定 `~/.config/fleetest/config.json` に次を**自分で**書き(ファイルが無ければ作ります)、もう一度実行します。

```json
{ "redactAccountValues": true }
```

マシン設定は、この Mac の人が手で書きます。AIアシスタントには書かせません
(Claude Code では、導入時にこのフォルダの編集を拒否する設定が入ります)。設定キーの一覧は
[マシン設定(config.json)](../reference/project/machine_settings_ja.md)にあります。

最後に、新しい run に対して `grep` を打ちます。

```bash
grep -rn '\*\*\*' TestProjects/project1/reports/ | tail -3
```

期待する結果:

- 新しいレポート・実行ログ・結果 JSON では、パスワードが `***` になっています。
- 一方、**スクリーンショットと録画に写った文字は伏せられません**。パスワード欄が平文で表示される画面のスクリーンショットや録画を開くと、値が写っています。
- 画素の中の文字を消す手段は無いので、本番の資格情報を使わないでください。

## 4. 外へ送るときに中身を見る

不具合を報告するときは、診断情報を zip にまとめて添付します。zip の中身を共有する前に確かめます。

### AIへの指示文

```text
fleetest doctor --bundle fleetest-diag.zip で診断の zip を作って、unzip -l で中身を一覧にして。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest doctor --bundle fleetest-diag.zip
unzip -l fleetest-diag.zip
unzip -p fleetest-diag.zip | grep -a -c 'ログイン'    # 画面の文字(アプリのラベル)を数える
```

最後の行の `ログイン` は、アプリの画面に出る文字に置き換えます。

</details>
<br>

期待する結果:

- zip にはブリッジなどのログ・直近の run の結果(既定で3件。シナリオごとの実行ログを含む)・ツールと OS の版が入っています。
- 件数が 0 でなければ、アプリの画面の文字が zip に含まれています。
- このコマンドはどこへも送信しません。
- 送るのはあなたが zip を添付したときだけなので、共有する前に必ず中身を確かめてください([トラブルシューティング](../in_action/troubleshooting_ja.md)の「不具合を報告するとき」)。

## 5. 消す

溜まった録画・レポート・ログは、まず量を見てから消します。

### AIへの指示文

```text
fleetest clean --dry-run で消える量を見せて。問題なければ fleetest clean を実行して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest clean --dry-run
../foundation-tester/.build/debug/fleetest clean
```

</details>
<br>

期待する結果:

- `--dry-run` は、消さずに対象の一覧を出します。
- `clean` は、保持量の上限の 90% を超えたカテゴリを古いものから 90% まで削除します。
- 上限に届いていなければ何も消えません。
- 消えないものは結果の記録(合否・所要時間の JSON)です([長く使うためのメンテナンス](../in_action/maintenance_ja.md)の「ディスクの空きを確保する」)。

## 知っておくこと

- 録画・レポート・実行ログは、テストが終わるたびに裏で上限を超えた分が自動で削除されます。
- 録画しないときは、実行プロファイルの `record` を `false` にします([実行プロファイルの設定項目](../reference/project/run_profile_ja.md))。

<br>

次へ: [長く使うためのメンテナンス](../in_action/maintenance_ja.md)

### Link
- [index](../index_ja.md)
