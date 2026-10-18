# スモークと回帰を分けて回す

[in English](smoke_and_regression.md)

シナリオが数本たまったら、毎回回す短い一式(スモーク)と、全部を回す一式(回帰)に分けます。
シナリオを書き換える必要はありません。フォルダに分けるだけです。

## 1. フォルダに分ける

`scenarios/` の直下にフォルダを作り、代表的なシナリオ(ログインして主要な画面に入れる、など)を移します。

### AIへの指示文

```text
TestProjects/project1/scenarios/ の下に smoke フォルダを作って、ログインの確認とトップ画面の確認のシナリオを移して。
移したらコンパイルが通ることを確かめて。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
mkdir TestProjects/project1/scenarios/smoke
mv TestProjects/project1/scenarios/ログイン.swift TestProjects/project1/scenarios/smoke/
```

シナリオの ID(`クラス名.メソッド名`)はフォルダに関係なく変わりません。

</details>
<br>

## 2. フォルダ単位で回す

### AIへの指示文

```text
fleetest の ios-run プロファイルで、smoke フォルダのシナリオだけを実行して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run --folder smoke
```

`--folder` には `scenarios/` 直下のサブフォルダの名前を渡します。複数回指定できます。`--scenario`・`--failed` とも併用できます。
フォルダを指定しなければ、全部を回します。

</details>
<br>

見えるもの: `smoke` の中のシナリオだけが実行されます。

## 3. 落ちたものだけ回し直す

### AIへの指示文

```text
前回の実行で落ちたシナリオだけを、同じプロファイルで実行し直して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --profile ios-run --failed
```

結果はプロファイルごとに記録されるので、前回と同じプロファイルで回します。

</details>
<br>

## 4. 使わなくなったテスト・作りかけのテストを外す

回帰にまだ入れたくないシナリオは、クラスかメソッドに印を付けます。付けたものは、全実行・フォルダ実行・クラス名指定の一括実行から外れます。
シナリオ ID を完全に指定したときだけ回せます。

- `@Draft("理由")`: 作りかけ(これから使う)。
- `@Deleted("理由")`: もう使わない。コードは残るので、復活は印を外すだけです。

### AIへの指示文

```text
作りかけのシナリオ「〇〇」に @Draft を付けて、全実行から外して。
```

実行の指定との関係は[シナリオの実行(fleetest run)](../reference/running/running_scenarios_ja.md)の「主なオプション」(`--scenario`)にあります。

## 5. CI に載せる

CI では、スモークを毎回、全部を夜に回します。ジョブを2つ作り、`--folder smoke` を付けたものと付けないものを定期実行にします
([CI で回す](../in_action/ci_ja.md))。

次へ: [CI で回す](../in_action/ci_ja.md)

### Link
- [index](../index_ja.md)
