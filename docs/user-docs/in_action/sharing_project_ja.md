# テストプロジェクトを共有し、2人目が回すまで

[in English](sharing_project.md)

作ったシナリオとプロファイルを git で共有し、2人目が自分の Mac で回すまでの手順です。
[クイックスタート](../quick-start_ja.md)を終えた作業フォルダがあることが前提です。

## 1. git に入れるもの・入れないものを確かめる

作業フォルダ(`Package.swift` があるフォルダ)の `.gitignore` を開きます。

### AIへの指示文

```text
この作業フォルダの .gitignore の中身を見せて。git に入れるファイルと入れないファイルを一覧にして。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
cat .gitignore
git status --short
```

</details>
<br>

期待する結果:

- `fleetest init` とインストールが、次の3行を `.gitignore` に足します(作業フォルダが git のリポジトリのとき)。

```text
.build/
.fleetest/
TestProjects/*/reports/
```

| git に入れる | git に入れない(最初の3つは `.gitignore` が外す) |
|---|---|
| `Package.swift` | `.build/`(ビルド成果物) |
| `TestProjects/<プロジェクト>/scenarios/`(シナリオ) | `.fleetest/`(この Mac の状態) |
| `TestProjects/<プロジェクト>/profiles/`(アプリ・実行プロファイル) | `TestProjects/*/reports/`(Markdown レポート。画面の文字が入る) |
| `TestProjects/<プロジェクト>/workspace/scripts/compose.yaml`(サーバーの宣言。[アプリが依存するサービス](../reference/writing/services_ja.md)) | `.mcp.json`(絶対パスを含むので Mac ごとに違う。`.gitignore` には自動では入らないので、`git add` しないか自分で足す) |
| `TestProjects/<プロジェクト>/dataset/`(共有してよいテストデータ) | `~/.config/fleetest/` の中身(作業フォルダの外にあり、そもそも git に入らない) |
| `TestProjects/<プロジェクト>/docs/`(あれば) | |

- `results/` は、自動では `.gitignore` に入りません。結果 JSON は複数の Mac の分をマージできる形で書かれますが
  ([結果の分析](../reference/running/results_analysis_ja.md)の「構成」)、同じ `results/runs/<月>/<runID>/` の下に録画も
  入ります。**録画は画面の文字が写り、容量も大きい**ので、共有する前に `git status` で何が増えているかを見て、
  入れるか決めてください([テスト結果に何が残るかを確かめる](../security/test_outputs_ja.md))。
- シークレットやパスワードは、リポジトリに入れません。後述のステップ 5 を見てください。

## 2. commit して push する

### AIへの指示文

```text
git status で入れてよいものだけを選んで commit して。results/ と reports/ は入れないで。push はまだしないで、commit の内容を見せて。
```

内容を確かめたら、push を指示します。

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
git add Package.swift .gitignore TestProjects/
git status --short           # reports/ と results/ が入っていないことを確かめる
git commit -m "Add fleetest test project"
git push
```

</details>
<br>

## 3. 2人目が clone してセットアップする

2人目は、自分の Mac でリポジトリを clone し、VSCode で開きます。fleetest のクローンは各自が持つので、
クイックスタートのステップ 3 と同じ指示文でセットアップします。

### AIへの指示文

```text
https://github.com/wave1008/foundation-tester をこのフォルダの隣に clone して
../foundation-tester/.claude/skills/fleetest-setup/SKILL.md の手順でセットアップして。
```

セットアップが終わったら、clone で持ってきた `TestProjects/` を `Package.swift` に登録します。

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest project sync
../foundation-tester/.build/debug/fleetest project list
```

`project sync` は、`TestProjects/` を走査して `Package.swift` のマーカー区間を作り直します
(手動コピーや `git pull` の後に必要です。[テストプロジェクトの作成](../reference/project/creating_project_ja.md)の「プロジェクトの管理」)。

</details>
<br>

期待する結果:

- `project list` に共有されたプロジェクトが実行プロファイル名つきで並びます。
- `⚠️ not registered in Package.swift` の注記が付いていなければ登録済みです(付いていれば `project sync` がまだです)。

## 4. 2人目のデバイスを用意する

実行プロファイルの `devices` は、デバイスを**名前**で指します。iOS Simulator は `name`(Simulator 自身の名前)と
`osVersion` で探し、Android は `avd` で探します([プロファイル](../reference/project/profiles_ja.md)の「デバイス」)。
`fleetest run` は、見つからないデバイスを**作りません**。2人目の Mac に同じ名前と OS の Simulator が無いと、
iOS では `simulator not found: <名前>(<OS>)` と、その Mac にある Simulator の名前の一覧つきで止まります。
Android は、その AVD を起こそうとして 3 回失敗してから(数分かかります)`no running emulator for AVD "<avd>"` と、
動いている Emulator の一覧つきで止まります(Emulator 自身のログには `Unknown AVD name` と出ます)。

直し方は2つあります。

- 同じ名前・同じ OS の Simulator / Emulator を作る。
- 2人目が**自分用の実行プロファイル**を作る。共有されたプロファイルを書き換えないので、1人目の設定を壊しません。
  アプリプロファイルは共有されたものを使います。

### AIへの指示文

```text
共有されている ios-app アプリプロファイルを使う、自分用の実行プロファイル ios-run-mine を作って。
デバイスは、この Mac で使える最新 OS の Simulator を選んで。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest profile setup --platform ios --app-id <bundle ID> \
  --app-ref ios-app --run ios-run-mine --auto-device
../foundation-tester/.build/debug/fleetest profile list
```

`--auto-device` は、この Mac に合う Simulator / Emulator を選び、無ければ作ります。
アプリプロファイルの `appPath` はビルド済みのアプリの場所なので、2人目の Mac でも同じパスで見つかるかを確かめます
(見つからないときは、2人目がアプリをビルドしてパスを合わせます)。

</details>
<br>

## 5. 2人目が回す

### AIへの指示文

```text
fleetest の ios-run-mine プロファイルで、すべてのシナリオを実行して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run-mine
```

</details>
<br>

次のものは**その Mac のもの**で、共有されません。2人目は自分で用意します。

- `~/.config/fleetest/dataset/<プロジェクト>/accounts.json` などの `account()` の値
  ([テストデータ・アカウント](../reference/commands/dataset_ja.md)の「ファイルの置き場と上書き」)。
  無いとその `account()` を呼んだステップが失敗し、失敗文に探したファイルのパスが出ます。
- `~/.config/fleetest/secrets/<プロジェクト>.env`(compose.yaml が参照する秘密。
  [アプリが依存するサービス](../reference/writing/services_ja.md)の「秘密」)。
- `~/.config/fleetest/config.json`(マシン設定。[マシン設定(config.json)](../reference/project/machine_settings_ja.md))。

## 6. 同じランナー機を2人で使う

ランナー機は、**同時に1つの実行しか動きません**。2人が同時に投げると、後の人が待つか、失敗するかを選べます。
体験してみましょう。2人がそれぞれの AIアシスタントに、ほぼ同時に頼みます(`M1Max` は登録したランナー機の名前)。

### AIへの指示文

```text
fleetest の ios-run プロファイルで、すべてのシナリオを M1Max で実行して。M1Max が使用中なら、最大 10 分まで順番を待って。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

2つのターミナルで、ほぼ同時に次を打ちます。

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run --runner M1Max --wait-lock 600
```

</details>
<br>

期待する結果:

- 先に打ったほうが実行を始めます。
- 後に打ったほうは実行ログに自分の順番を出して待ち、先の実行が終わると始まります。
- `--wait-lock` を付けないと、後のほうは使用中であることと、誰がいつから使っているかを出して止まります。

誰が使っているかは `fleetest remote status --runner M1Max` の LOCK 欄で見られます。自分の名前を表示に出すには、
`~/.config/fleetest/config.json` に `issuerId` を書きます。待ち方・ロックの外し方・設定は
[リモート実行](../fleet/remote_runners_ja.md)の「1台のランナー機を複数人で使うとき」にあります。
ランナー機の追加は[Mac を追加する](../fleet/adding_mac_ja.md)です。

## 7. AI が書いたシナリオをレビューする

共有するシナリオは、AI が書いたものも人が目で確かめます。見る観点は
[壊れにくいシナリオの書き方](../reference/writing/writing_robust_scenarios_ja.md)の見出しです。本文はそちらにあります。
一覧を作るところまでは AI に頼めます。

### AIへの指示文

```text
fleetest のシナリオを、壊れにくいシナリオの書き方の観点で見直して、直す候補を一覧にして。直すのは、私が一覧を確認してからにして。
```

- 要素の出現待ちに `wait` を置かない
- セレクタは記憶ではなく実スクリーンショットから採る
- 座標タップをシナリオに残さない
- 出るか不定のものは `ifCanSelect` と `irregularHandler` で包む
- `expectation` に必ずアサーションを置く
- 失敗はシナリオ全体を中断する(`afterEach` は走る)
- 両 OS で回すなら `app:` / `platform:` を書かない
- 値を読むときは先に確定させる
- 不可逆な操作は再試行を書かない

## 次へ

- [CI で回す](ci_ja.md)
- [テスト結果に何が残るかを確かめる](../security/test_outputs_ja.md)

### Link
- [index](../index_ja.md)
