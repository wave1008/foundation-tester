# クイックスタート

セットアップ完了後、最初のシナリオ1本を実行するまでの最短手順です。
`TestProjects/` を含む作業フォルダがまだ無ければ、先に[はじめに](getting-started_ja.md)の
`/fleetest:fleetest-setup` を済ませてください。

## 1. プロファイルを用意する

実行には3つのプロファイルが必要です —— 対象アプリを定めるアプリプロファイル、デバイスを
定めるマシンプロファイル、両者を組み合わせる実行プロファイル。エージェントで
`/fleetest:fleetest-profiles` を使うか、コマンドで直接作ります。

```bash
fleetest profile setup --platform ios --app-id com.example.myapp --auto-device
```

`--auto-device` は、このマシンで利用可能なシミュレータ/エミュレータを自動で選びます。
このコマンドでは実行プロファイルの名前はプラットフォーム名(ここでは `ios`)になり、完了時に
次に実行すべき `fleetest run` コマンドが表示されるので、それをコピーしてください。
プロファイルの詳細は[プロファイル](./project/profiles_ja.md)。

## 2. シナリオを1本書く

作り方は3通りあり、どれも `TestProjects/<プロジェクト>/scenarios/` に同じ形の Swift ファイルを
作ります。

- エージェントに書かせる(`/fleetest:fleetest-scenario`)。実画面を探索しながらセレクタを
  採取してくれます
- VSCode 拡張のライブ操作パネルで録画する。アプリを操作すると、シナリオが自動で生成されます
- 手書きする

最小のログインシナリオはこうなります。

```swift
import FTDSL

@TestClass
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

セレクタ(`#email` など)は実画面から採る必要があります。手で書くなら
[セレクタ式](./selector/selector_expression_ja.md)を参照してください。

## 3. デバイス無しで検証する(dry-run)

デバイスに触れる前に dry-run を実行します。セレクタの構文誤り・到達しない scene・検証の無い
`expectation` を数秒で検知します。

```bash
fleetest run --dry-run --scenario ログインテスト
```

## 4. デバイスで実行する

```bash
# クローン構成(foundation-tester のクローン内で作業している場合)
swift run fleetest run --profile ios

# 外部パッケージ構成(TestProjects/ を持つ別の作業フォルダ)
../foundation-tester/.build/debug/fleetest run --profile ios
```

`--profile` には、ステップ1で用意した実行プロファイルの名前を渡します(上のコマンドなら `ios`。
`--run <名前>` を指定した場合はその名前)。アプリ・デバイス・実行時設定はそこから解決されます。

VSCode からは **Test Explorer** でシナリオを選び、**実行**をクリックします。

## 5. 結果を見る

実行のたびに、成否を問わず `TestProjects/<プロジェクト>/reports/` にシナリオごとの Markdown
レポートが出ます。ステップごとの結果とスクリーンショット、失敗時は原因のトリアージと
自己修復の提案が載ります。

VSCode では Test Explorer が成否を直接表示し、そこからレポートを開けます。

### Link
- [index](index_ja.md)
