# コードの構造

シナリオは `scenario → scene → condition/action/expectation`(CAE)の階層で組み立てます。
このページでは、各階層が実行とレポートにどう関わるかを説明します。

## CAE の連鎖

1つの `scene` の中では、`condition` / `action` / `expectation` を `.` で繋いで何度でも
連鎖できます。

```swift
scene(2, "下位画面へ遷移して戻る") {
    action {
        tap("#nav_selector")
    }.expectation {
        select("#screen_title").textIs("セレクタ")
    }.action {
        tap("#btn_back")
    }.expectation {
        select("#screen_title").textIs("ホーム")
    }
}
```

`condition` は scene が必要とする状態を整え(多くの場合 `launchApp()`)、`action` は操作を、
`expectation` は検証を行います。3つすべてを書く必要はなく、上の例のように
`action`/`expectation` を必要な回数だけ交互に繋げます。

**scene の番号と題はレポートの見出しになります。** レポートは `scene → condition/action/
expectation → ステップ` の階層で構成されるため、「2番目のステップ」のような機械的な題ではなく、
その scene が何を確かめているかが分かる番号・題を付けてください。

## 失敗のセマンティクス

コマンドが1つ失敗すると、シナリオ全体が中断します —— **以降のステップは、現在の scene
だけでなく残りの scene もすべてスキップ**されます。唯一の例外は `tearDown()` で、失敗後でも
実行されます。

**ブロック内の生の Swift コードはこの仕組みでスキップされません**(スキップされるのは DSL
コマンドだけです)。前段の失敗後に走らせたくない素の Swift ロジックがある場合は、
`procedure { }`(→ [記述子](../commands/descriptors_ja.md))で包んで同じスキップ挙動に
乗せてください。

## 1ステップの時間上限

各コマンド(各ステップ)には**壁時計で120秒**の上限があります。時間内に返らない場合はそのステップが
失敗となり、実行中の処理は背後で走らせたままにせずキャンセルされます。

## 構造化と値の受け渡し

`group("名前") { }` は実行や失敗の扱いを変えずに、レポート上でひとまとまりのステップに
ラベルを付けます。`procedure("説明") { }` は任意の Swift(`try`/`await` を含む)を1ステップ
として記録します —— これにより、イレギュラー処理やテストデータ投入を固定の DSL 語彙ではなく
コードでそのまま書けます。詳細: [記述子](../commands/descriptors_ja.md)。

## 検証していないシナリオの検知

`expectation { }` に検証コマンドが1つも無いと、レポートとログに警告が出ます(失敗にはしません)
—— 操作はしたが何も確認していないシナリオを見つけるためです。`fleetest run --dry-run`
(または `ft_dry_run`)を使うと、デバイスに触れずにこれを検知できます。詳細:
[dry-run](../running/dry_run_ja.md)。

## OS による分岐

OS 固有の挙動を書く手段は、階層の異なる2つがあります:

- **`@TestClass(platform:)` / `@Test(platform:)`** はクラスまたはメソッド全体が特定の OS
  にしか当てはまらないことを宣言します。宣言した OS を回さない実行では、そのシナリオは
  skipped(未実行・失敗にはカウントしない)として記録されます。
- **`ios { }` / `android { }`** は scene の**内側**で分岐します。シナリオの大部分は共通だが、
  一部のステップだけ OS ごとに違う(片方の OS にしか無いコントロール操作など)場合に使います。

テスト全体が片方の OS に当てはまらないなら `platform:` を、共通のシナリオの一部ステップだけ
違うなら `ios { }`/`android { }` を使い分けてください。

### Link
- [index](../index_ja.md)
