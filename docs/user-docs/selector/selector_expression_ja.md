# セレクタ式

セレクタは文字列1本で書きます。このページは記法の全体リファレンスです。コマンドでの使い方は
[docs/commands.md](../../commands.md)を参照してください。

## 記法の表

結合の強さ(強い順): `&&` > `>>` > `||`。

| 記法 | 意味 |
|---|---|
| `#login_btn` | accessibility id(完全一致)。**identifier で1件も引けなければ placeholder を引く**(入力欄は読み取り経路によって id/placeholder が入れ替わるため。[WebView 内の要素](./webview_ja.md)参照) |
| `#login*` / `#*login*` / `#*btn` | id の前方一致 / 部分一致 / 後方一致(完全形は `idStartsWith=` `idContains=` `idEndsWith=`) |
| `ログイン` | ラベル(**完全一致のみ**。完全形は `text=ログイン`) |
| `*ログイン*` / `ログイン*` / `*ログイン` | 部分一致 / 前方一致 / 後方一致(完全形は `textContains=` `textStartsWith=` `textEndsWith=`) |
| `textMatches=^行 [0-9]+$` / `idMatches=^row_[0-9]+$` | 正規表現(**部分一致**。全体一致は `^…$` を書く) |
| `.button` / `.button[2]` | 型+順番(**1 オリジン**。`.button[2]` = 2番目の Button。1番目は `.button` または `.button[1]`) |
| `.switch#id` / `.switch&&ラベル` | 型と id/label の併用(値検証などで型を絞りたいときに使う) |
| `#save&&.button&&enabled=true` | **`&&` で AND 合成**。属性は `text` `value` `placeholder` `id` `type` `pos` `checked` `enabled`。一致方法(`Contains`/`StartsWith`/`EndsWith`/`Matches`)を持つのは `text`/`value`/`placeholder`/`id` の4属性のみで、`type`/`pos`/`checked`/`enabled` は完全一致のみ |
| `(保存\|OK)` / `text=(保存\|OK)` | **フィルタ内 OR**。`保存\|\|OK` と等価(相対セレクタの引数では括弧を自分で書く: `:right((保存\|OK))`) |
| `.button&&text!=キャンセル` / `.button&&!キャンセル` | **否定フィルタ**(`!値` は短縮形)。`textContains!=` `!#id` `!.button` も可。**否定だけの節・序数の否定は書けない** |
| `.input` / `.widget` | 型エイリアス(`.input` = textField\|secureTextField / `.widget` = OS 共通の役割型5つ) |
| `#list >> .clickable[2]` | **スコープ**(祖先 >> 子孫)。序数はスコープ内で数えるので画面クロムやスクロール位置でずれない。**祖先がアプリの a11y ツリーに公開されている必要**があり、畳まれた容器(Flutter の `MergeSemantics` 等)は子孫が消えるためスコープに使えない |
| `通知:rightSwitch` | **相対セレクタ**(**基準が先**)。基準の帯に入り、その方向にある最も近い候補。該当が無ければ失敗する。詳細は[相対セレクタ](./relative_selector_ja.md) |
| `数量:right(2)` / `#a:below(.button&&項目)` / `見出し:right:belowButton` | 序数 / 任意フィルタ / 連鎖 |
| `<変更&&.button>:right(数量)` | 基準を `<...>` で囲む(Shirates 正典形。任意。基準の範囲を目で追いやすくする) |
| `=#で始まる生ラベル` | `=` エスケープでラベル扱いを強制する(`>>` `&&` `:right` `*` を含むラベルもこれで書く) |

## 短縮形と完全形の対応

| 短縮形 | 完全形 | 意味 |
|---|---|---|
| `ラベル` | `text=ラベル` | 完全一致(暗黙の部分一致フォールバックは無い) |
| `*語*` / `語*` / `*語` | `textContains=` / `textStartsWith=` / `textEndsWith=` | 部分一致 |
| — | `textMatches=^…$` | 正規表現(部分一致。全体一致は `^…$`) |
| `#id` | `id=` | id(完全一致) |
| `#foo*` / `#*foo*` / `#*foo` | `idStartsWith=` / `idContains=` / `idEndsWith=` | id の部分一致 |
| — | `idMatches=^…$` | id の正規表現(部分一致) |
| `.型` | `type=` | 型名(先頭小文字) |
| `[n]` | `pos=n` | 候補内の順番(1 オリジン) |
| — | `value=` / `placeholder=` | 値・プレースホルダ(`text`/`id` と同じ一致方法が使える) |
| — | `checked=true\|false` / `enabled=true\|false` | 状態(`checked=false` は状態を持たない要素にも一致する) |
| `(a\|b)` | `text=(a\|b)` | フィルタ内 OR |
| `!値` | `属性!=値` | 否定フィルタ |

## `||` は AND ではなく候補集合の和

`||` は**候補集合の和**を取ります。要素を1つだけ選ぶコマンドでは、**節の順に先に解決した方**を
採用します。これにより `#login_btn||ログイン` はヒール連鎖としても働きます —— id が変わっても
ラベルの節で解決できます。実質の優先度は id > label > type+index です。

## デバイスに触れる前に構文エラーになるもの

綴り誤り・未対応記法(`:near` `:parent` 等)・数値でない序数(`[abc]`)・閉じない括弧は、
どれも実行前に落とされます。誤記が黙ってラベル扱いになり、`notExist` が誤った理由で通ってしまう
ことを防ぐためです。**未知のフィルタ名**(`名前=値`)は生ラベルとして書けます(`notify=off` 等)。
ただし、既知のフィルタ名と紛らわしいとき(前方一致関係・大小文字違い・6文字以上で1文字違い・
既知の基底名の直後に大文字が続く形 `idPrefix=` 等)は、綴り誤りとして実行前エラーになります。

## 型の語彙

型名は先頭小文字で書きます(`.button` であって `.Button` ではありません)。`.input` と
`.widget` は型エイリアスです。この記法をコンパイル時にチェック可能な形で書けるのが
[型付きセレクタ](./typed_selector_ja.md)です。

### Link
- [index](../index_ja.md)
