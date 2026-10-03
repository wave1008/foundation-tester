# group, procedure, beforeEach, afterEach

ステップをレポート上でまとめる、任意の Swift を1ステップとして記録する、各テストの前後処理を
行うための構造コマンドです。

## 関数

| 関数 | 説明 |
|---|---|
| `group("名前") { }` | 中のステップにレポート上で `[名前]` を前置します。実行・失敗の扱いは素の列と同じです。 |
| `procedure("説明") { try await ... }` | 任意の async Swift を1ステップとして記録します。throw するとシナリオが失敗します。 |
| `func beforeEach()` | テストクラスに定義すると、各 `@Test` の前に自動実行されます。 |
| `func setUpDevice()` | テストクラスに定義すると、**1回の run × 1デバイス × 1クラスで高々1回**、そのデバイスに配られたそのクラスの最初のシナリオの `beforeEach()` の前に自動実行されます。用意した値は [`writeMemo` / `readMemo`](memo_ja.md) で他のシナリオへ渡します。 |
| `func afterEach()` | テストクラスに定義すると、各 `@Test` の後に自動実行されます。**失敗後でも実行されます**。 |
| `func tearDownDevice()` | テストクラスに定義すると、**そのデバイスがその run のシナリオをすべて終えた後**に1回だけ自動実行されます(そのデバイスでそのクラスのシナリオが1本でも走った場合)。`setUpDevice()` の片付けに使います。 |

## 例

```swift
@TestClass(app: "com.example.myapp", platform: "ios")
class ログインフロー {
    func beforeEach() {
        irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
    }

    func afterEach() {
        terminateApp()
    }

    @Test("正しい認証情報でログインできる")
    func S0010() {
        scenario {
            group("テストデータの準備") {
                procedure("API 経由でアカウントを投入する") {
                    try await seedTestAccount()
                }
            }
            scene(1, "ログインする") {
                action {
                    launchApp()
                    tap("#email"); type("user@example.com")
                    tap("#password"); type("secret")
                    tap("#login_btn")
                }.expectation {
                    exist("#welcome_text")
                }
            }
        }
    }
}
```

## 注意点

- **`procedure { }` は、失敗後に走らせたくない処理を置く場所です。** ブロック内の生 Swift
  コードは、そのシーンの前段が失敗していてもスキップされません。壊れた状態で発火させたく
  ない処理は `procedure { }` に包んでください(中で throw すれば、コマンドの失敗と同じように
  シナリオが中断します)。
- `setUpDevice()` はその最初のシナリオのプロセスの中で走るため、**中で設定したインスタンスのプロパティは他のシナリオからは見えません**。値の受け渡しは `writeMemo` / `readMemo` を使ってください。失敗すると、同じデバイスで同じクラスの残りのシナリオは実行されずに失敗として記録され、同じ run の中で再試行もされません。
- `afterEach()` は `@Test` が失敗した後でも実行されます。アプリの終了など、成否に関わらず
  必要な後片付けに使ってください。
- `tearDownDevice()` は専用のプロセスで走ります。メモは読めます。`setUpDevice()` が失敗していても走ります。デバイスが途中で使えなくなった場合や run を中断した場合は走りません。結果は run のログとレポートに残り、テストの合否には数えません。
- `@Deleted("理由")` と `@Draft("理由")` は `@TestClass` または `@Test` に付けて、削除済み・
  作業中であることを示します。どちらも一括実行(全件・フォルダ・クラス名指定)からは除外され、
  完全一致 ID を明示したときだけ実行できます。アノテーションの一覧は
  [テストクラスの作成](../testclass/creating_testclass_ja.md) を参照してください。
- fleetest は Shirates の `describe` / `caption` / `manual` / `knownIssue` を持ちません
  —— この種の説明は scene の題名に書きます。

### Link
- [index](../../index_ja.md)
