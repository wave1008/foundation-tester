# クイックスタート

セットアップ完了後、最初の1本を実行するまでの最短手順です。`/fleetest:fleetest-setup`
([はじめに](getting-started_ja.md)参照)が完了している前提です。未導入の場合は先にそちらを行ってください。

## 1. 前提: セットアップ済みであること

`TestProjects/` ディレクトリを含む作業フォルダが既にあるはずです(`/fleetest:fleetest-setup`
が作成します)。無ければ先に[はじめに](getting-started_ja.md)を行ってください。

## 2. プロファイルを用意する

何かを実行する前に、アプリプロファイル(対象アプリ)・マシンプロファイル(デバイス)・
実行プロファイル(アプリ+デバイスの組み合わせ)が必要です。エージェントで `fleetest-profiles`
スキルを使う(Claude Code は `/fleetest:fleetest-profiles`)か、
次のコマンドを直接実行します。

```bash
fleetest profile setup --platform ios --app-id com.example.myapp --auto-device
```

`--auto-device` を付けると、このマシンで利用可能なシミュレータ/エミュレータを自動で選定します。
実行プロファイルが何を制御するかは[実行プロファイル](./project/run_profile_ja.md)を参照してください。

## 3. シナリオを1本書く

次の3つの経路はいずれも `TestProjects/<プロジェクト>/scenarios/` 配下に同じ形の Swift ファイルを作ります。

- エージェントに書かせる(Claude Code は `/fleetest:fleetest-scenario`)
  —— 実画面を一緒に探索しながら実セレクタを採取してファイルを書きます。
- VSCode 拡張のライブ操作パネルで録画する(アプリを操作すると自動でシナリオが生成されます)。
- 手書きする。

最小のログインシナリオは次のようになります。

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

セレクタ(`#email`・`#login_btn` 等)は実画面から採る必要があります。
[セレクタ記法](./selector/selector_expression_ja.md)を参照するか、実画面から自動で採取してくれる
`/fleetest:fleetest-scenario` を使ってください。

## 4. デバイス無しで検証する(dry-run)

デバイスに触れる前に dry-run を実行します。セレクタの構文誤り・到達しない scene・
アサーション0個の `expectation` を数秒で検知します。

```bash
fleetest run --dry-run --scenario ログインテスト
```

## 5. デバイスで実行する

```bash
# クローン構成(foundation-tester のクローン内で作業している場合)
swift run fleetest run --profile <実行プロファイル名>

# 外部パッケージ構成(TestProjects/ を持つ別の作業フォルダ)
../foundation-tester/.build/debug/fleetest run --profile <実行プロファイル名>
```

`--profile` を渡すと、ステップ2で用意した実行プロファイルからアプリ・デバイス・
実行時設定(自己修復・タイムアウト等)が解決されます。

VSCode 拡張からも実行できます。**Test Explorer** を開いてシナリオを見つけ、
**実行**(または dry-run をやり直したいときは**実行 (dry-run)**)をクリックしてください。

## 6. 結果はどこに出るか

実行のたびに、成否を問わず `TestProjects/<プロジェクト>/reports/` へシナリオごとの
Markdown レポートが出力されます。scene → condition/action/expectation のステップ階層、
失敗時のトリアージ、スクリーンショット、該当すれば自己修復の提案が含まれます。

VSCode では Test Explorer が各テストに成否を直接表示し、そこから生成されたレポートを開けます。

### Link
- [index](index_ja.md)
