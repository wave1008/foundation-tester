# 独自コマンド

組み込みの DSL コマンドで足りない、自分のアプリ固有の繰り返し手順(ログイン・共通の前提条件・
[`gesture`](../commands/gestures_ja.md) で組んだ独自のマルチタッチジェスチャ等)は、`scenarios/`
配下に**素の Swift 関数**として書きます。これは Shirates の `macro` に相当しますが、fleetest では
独立した機構ではなく、ただの関数です。

```swift
func login(user: String, password: String) {
    tap("#login_email")
    type(user)
    tap("#login_password")
    type(password)
    tap("#btn_login")
    exist("#home_title")
}
```

`scene` の中から他のステップと同じように呼び出せます:

```swift
scene(1, "ログイン") {
    action {
        login(user: "demo@example.com", password: "hunter2")
    }
}
```

## コマンド索引へ公開する(`@FTCommand`)

上のような素の関数はそのまま動きますが、どこにも現れません —— MCP サーバ(`ft_dsl_commands`)や
`fleetest-scenario` スキルでシナリオを書くエージェントは、その関数の存在を知る手段が無いため
再利用せず、同じ手順を手で書き直してしまうことがあります。`@FTCommand("説明")` を付けると
公開されます:

```swift
@FTCommand("メールとパスワードでログインし、ホーム画面まで進む")
func login(user: String, password: String) {
    tap("#login_email")
    type(user)
    tap("#login_password")
    type(password)
    tap("#btn_login")
    exist("#home_title")
}
```

`fleetest api dsl-commands --project <name>` と MCP ツール `ft_dsl_commands`(`project:` を渡す —
省略時は唯一のプロジェクト、または VSCode 拡張が設定されているプロジェクトに解決される)は、
これを組み込みコマンドと並べて `[project: ファイル:行]` 付きで一覧に出します。新しいシナリオを
書くよう頼まれたエージェントは、似た手順を手書きするより先にこちらを優先するよう案内されます
——自分のアプリで「ログイン済み」が何を意味するかなど、チーム自身の取り決めが埋め込まれているためです。

`@FTCommand` はマーカーであり、コードは何も生成しません。付けても付けなくても関数の挙動は
まったく同じで、付けると見つけやすくなるだけです。

### `extension FTElement` のメソッド

掴んだ要素に対して働くヘルパーは、自由関数ではなく `FTElement` の extension として書くと、
組み込みの `.textIs(...)` などと同じ形でチェーンできます:

```swift
extension FTElement {
    @FTCommand("この要素をタップし、次の要素が現れることを確かめる")
    @discardableResult
    func tapAndConfirm(_ next: String) -> FTElement {
        tap()
        return exist(next)
    }
}
```

```swift
select("#btn_add_to_cart").tapAndConfirm("#txt_cart_badge")
```

索引はこの種のエントリに印を付けるので、読み手は `select(...).tapAndConfirm(...)` の形で
呼び出すことが分かります(自由関数としてではありません)。

## 規則

- `@FTCommand` を付けられるのは**トップレベルの関数**、または**`extension` の中のメソッド**
  (多くは `extension FTElement { }` ブロック)だけです。`class` や `struct` の中のメソッドへの
  付与はコンパイル時にエラーになります —— トップレベル関数として書くか、extension へ移してください。
- 引数は空でない文字列リテラル1つです: `@FTCommand("何をするか")`。
- 組み込みの DSL コマンドと同じ名前(`tap`・`type` 等)を付けると、索引の応答が警告を出します——
  読み手がどちらを指しているか分からなくなるため、別の名前を選んでください。
- `private`/`fileprivate` を付けた `@FTCommand` 関数は、実際には別のシナリオファイルから呼べない
  ため、コマンドとしては**一覧に載りません**——代わりに索引の応答にその関数名を挙げた警告が付きます。
  他のシナリオファイルからも再利用したいならアクセス修飾子を外し、本当にそのファイルだけで使う
  ものなら `@FTCommand` の方を外してください。
- レポートや実行ログに並ぶのは、ヘルパーの中の個々のコマンドです(ヘルパーの名前は出ません)。
  失敗したときに示されるのも、中のコマンドの行です。
- 索引はヘルパーを**一覧するだけ**で、実行はしません。`ft_batch`(シナリオを保存せずに DSL の
  1行ずつを直接実行する MCP ツール)が理解するのは組み込みの operation/scroll コマンドだけです——
  project コマンドはバッチではなく、シナリオの `.swift` ファイルに直接書いてください。

### Link
- [index](../index_ja.md)
