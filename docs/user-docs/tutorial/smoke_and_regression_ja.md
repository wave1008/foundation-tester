# スモークと回帰を分けて回す

[in English](smoke_and_regression.md)

毎回回す短い一式(スモーク)と、全部を回す一式(回帰)に分けます。シナリオの書き換えは要りません。
ここでは、スモークを「商品詳細を開くテスト(クイックスタートで作ったもの)+ カートのテスト」、回帰を「全部」とします。

## 1. フォルダに分ける

### AIへの指示文

```text
fleetest のテストプロジェクト project1 の scenarios/ の下に smoke フォルダを作って、商品詳細を開くテストとカートのテストのシナリオを移して。
移したらコンパイルが通ることを確かめて。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
mkdir TestProjects/project1/scenarios/smoke
mv TestProjects/project1/scenarios/<ファイル名>.swift TestProjects/project1/scenarios/smoke/
```

シナリオの ID(`クラス名.メソッド名`)はフォルダに関係なく変わりません。

</details>
<br>

期待する結果:

- `scenarios/smoke/` に2本の Swift ファイルが入ります。

## 2. フォルダ単位で回す(スモーク)・全部回す(回帰)

### AIへの指示文

```text
fleetest のテストプロジェクト project1 の ios-run プロファイルで、smoke フォルダのシナリオだけを実行して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../foundation-tester/.build/debug/fleetest run --project project1 --profile ios-run --folder smoke
```

`--folder` には `scenarios/` 直下のサブフォルダの名前を渡します。複数回指定できます。`--scenario`・`--failed` とも併用できます。
フォルダを指定しなければ、全部を回します。

</details>
<br>

期待する結果:

- `smoke` の中の2本だけが実行されます。

続けて、フォルダを指定せずに全部を回して(回帰)、本数の違いを見比べます。

```text
fleetest のテストプロジェクト project1 の ios-run プロファイルで、全部のシナリオを実行して。
```

次へ: [VSCode で見る](watching_in_vscode_ja.md)

### Link
- [index](../index_ja.md)
