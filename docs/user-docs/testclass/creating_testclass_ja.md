# テストクラスの作り方

テストシナリオは、1つ以上の `@Test` メソッドを持つ `@TestClass` を記述した Swift ファイルです。
このページではファイルの置き場所と、最小限必要な形を説明します。

## ファイルの置き場所

`TestProjects/<プロジェクト>/scenarios/` 配下に `.swift` ファイルを置きます(サブフォルダも可。
例: `scenarios/Login/`)。`swift build`(または任意の `fleetest run`)を実行すると新しいファイルは
自動で発見されます。登録の手続きは不要です。

## 最小の例

```swift
import FTDSL

@TestClass                                      // 対象アプリは実行プロファイルが決める
class ログインテスト {

    @Test("正しいメールとパスワードでログインできる")
    func S0010() {
        scenario {
            scene(1, "ログインする") {
                condition {
                    launchApp()
                }.action {
                    tap("#email"); type("test@example.com")
                    tap("#password"); type("password123")
                    tap("#login_btn||ログイン")
                }.expectation {
                    exist("#welcome_text||ようこそ")
                }
            }
        }
    }
}
```

- `import FTDSL` が必要です。
- `@TestClass` がクラスに付けるマーカーです。**`app:` は通常書きません** —— 対象アプリは
  実行プロファイル(アプリプロファイル → 実行中 platform の `ios.app`/`android.app`)から
  解決されます。これにより、同じシナリオを iOS と Android で別々の bundle ID のアプリに対して
  実行できます。`@TestClass(platform: "ios")`(または `"android"`)は、そのクラスが特定の OS
  でしか意味を持たないときだけ付けます。宣言した OS を回さない実行では、失敗ではなく
  skipped(対象外)として記録されます。
- `@Test("説明")` がテストメソッドに付けるマーカーです。**メソッド名は `S0010`、`S0020`、…**
  という **10 刻み**の命名慣習です(後から途中にステップを差し込んでもリネームが要りません)。
  レポート・`--scenario`・CI などで使われるシナリオ ID は `クラス名.メソッド名` です。
- 本体は `scenario { scene(n, "題") { condition { }.action { }.expectation { } } }` の形です
  —— 各ブロックの意味とチェーンの仕方は[コードの構造](./testcode_structure_ja.md)を参照してください。
- コマンド(`tap`、`type`、`exist` など)は**同期・非 throw の自由関数**です。`try`/`await`
  もクロージャ引数(`{ it in }`)も不要で、暗黙にカレントの実行コンテキストへ作用します。

## setUp / tearDown

```swift
class ログインテスト {
    func setUp() {
        irregularHandler("#promo_modal", dismiss: "#btn_promo_close")
    }
    func tearDown() {
        // 失敗しても必ず走らせたい後始末
    }

    @Test("...")
    func S0010() { scenario { /* ... */ } }
}
```

`setUp()` と `tearDown()` は、クラス内の各 `@Test` の前後で自動実行されます。
**`tearDown()` は失敗後でも実行される**ため、シナリオが途中で中断してもスキップされては
困る後始末をここに置きます。

## 未完成・廃止のマーク

- `@Draft("理由")` は未完成(実装中)であることを示すマークです。一覧には「作業中」として
  残りますが、全実行・フォルダ実行・クラス名指定の一括実行からは除外されます(完全一致 ID
  の明示指定では実行できます)。
- `@Deleted("理由")` は論理削除であることを示す同種のマークです(一括実行から除外・完全一致
  ID では実行可)。コードはファイルに残るので、アノテーションを外すだけで復活します。

どちらもクラス、あるいは個々の `@Test` メソッドに付けられます。

### Link
- [index](../index_ja.md)
