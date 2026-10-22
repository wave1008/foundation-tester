# スモークと回帰を分けて回す

[in English](smoke_and_regression.md)

毎回回す短い一式(スモーク)と、全部を回す一式(回帰)に分けます。シナリオの書き換えは要りません。

## 1. フォルダに分ける

### AIへの指示文

```text
fleetest のテストプロジェクト myshop の scenarios/ の下に smoke フォルダを作って、ログインの確認とトップ画面の確認のシナリオを移して。
移したらコンパイルが通ることを確かめて。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
mkdir TestProjects/myshop/scenarios/smoke
mv TestProjects/myshop/scenarios/ログイン.swift TestProjects/myshop/scenarios/smoke/
```

シナリオの ID(`クラス名.メソッド名`)はフォルダに関係なく変わりません。

</details>
<br>

## 2. フォルダ単位で回す

### AIへの指示文

```text
fleetest のテストプロジェクト myshop の ios-run プロファイルで、smoke フォルダのシナリオだけを実行して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run --folder smoke
```

`--folder` には `scenarios/` 直下のサブフォルダの名前を渡します。複数回指定できます。`--scenario`・`--failed` とも併用できます。
フォルダを指定しなければ、全部を回します。

</details>
<br>

見えるもの: `smoke` の中のシナリオだけが実行されます。

## 3. 落ちたものだけ回し直す

### AIへの指示文

```text
fleetest のテストプロジェクト myshop で、前回の実行で落ちたシナリオだけを、同じプロファイルで実行し直して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --project myshop --profile ios-run --failed
```

結果はプロファイルごとに記録されるので、前回と同じプロファイルで回します。

</details>
<br>

## 4. 使わなくなったテスト・作りかけのテストを外す

### AIへの指示文

```text
fleetest のテストプロジェクト myshop の作りかけのシナリオ「〇〇」に @Draft("理由") を付けて、全実行から外して。
もう使わないシナリオなら @Deleted("理由") を付けて。
```

- 印を付けたシナリオは、全実行・フォルダ実行・クラス名指定の一括実行から外れ、シナリオ ID を完全に指定したときだけ回せます。
- `@Draft` は作りかけ、`@Deleted` はもう使わないもの(コードは残るので、復活は印を外すだけです)。

詳しくは[シナリオの実行(fleetest run)](../reference/running/running_scenarios_ja.md)の「主なオプション」(`--scenario`)。

## 5. CI に載せる

### AIへの指示文

```text
fleetest のテストプロジェクト myshop を CI で回すジョブを2つ作って。
1つは --folder smoke を付けて毎回、もう1つは付けずに夜に回す。
```

次へ: [CI で回す](../in_action/ci_ja.md)

### Link
- [index](../index_ja.md)
