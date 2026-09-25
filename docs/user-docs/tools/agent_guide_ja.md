# エージェント向けの手引き: アプリの画面から通るシナリオまで

このページは、`ft_*`(MCP ツール)で fleetest のシナリオを書く **AI コーディングエージェント**向けです。
手順書(クローンの `.claude/skills/fleetest-scenario/SKILL.md`)の短縮版で、規則の全体が要るときは
手順書を読んでください。

## 流れ

1. **デバイスを決める。** `ft_list_devices` のあと、すべての `ft_*` に同じ `profile:`(実行プロファイル名)
   —— または `udid:` / `port:` / `serial:` —— を渡す。探索と実行が同じデバイスを使うため。
2. **探索する。** `ft_launch` でアプリを起動し、`ft_snapshot` を撮る。各行は
   `[ref] Type "label" id=… (x,y WxH)`。`ft_tap` / `ft_type`(ref かセレクタ)で進める。
   長いリストは `ft_swipe` を繰り返さず、セレクタを渡して `ft_scroll_to` を使う。
   通った画面は全部撮っておく —— dry-run がそこで見た `#id` と照合する。
3. **下書きを得る。** `ft_draft_scenario` は、直前の `ft_launch` 以降の操作を Swift にして文字列で返す
   (ファイルは書かない)。寄り道は `drop:` / `lastN:` で落とす。
   **expectation は意図的に空で返る** —— スナップショットで見た内容をもとに自分で埋める。
4. **ファイルを置く。** `TestProjects/<プロジェクト>/scenarios/<名前>.swift`。
5. **コンパイルする。** `ft_list_scenarios` がプロジェクトをビルドし、コンパイルエラーをそのまま返す。
6. **dry-run する。** `ft_dry_run` はデバイス不要。セレクタの構文誤りは失敗(isError)になる。
   `⚠️` 行(検証の無い expectation・スナップショットで一度も見ていない `#id`)は失敗ではないが、直す。
7. **実行する。** `ft_run_scenario`。失敗は isError で返り、失敗したステップ・**失敗した瞬間の要素一覧と
   スクリーンショット**・レポートのパスが載る。まず要素一覧を読む —— スクリーンショットからは `#id` を
   読めない。

## シナリオの例

```swift
import FTDSL

@TestClass(app: "com.example.app", platform: "ios")
class SignInExample {
    @Test("Signing in shows the home screen")
    func S0010() {
        scenario {
            scene(1, "The sign-in screen opens") {
                condition {
                    launchApp()
                }.action {
                    tap("#btn_signin")
                }.expectation {
                    exist("#field_email")
                }
            }
            scene(2, "Signing in lands on home") {
                action {
                    tap("#field_email")
                    type("#field_email", "user@example.com")
                    ifCanSelect("#btn_dismiss_tips", waitSeconds: 1) {
                        tap("#btn_dismiss_tips")
                    }
                    tap("#btn_submit", scroll: .down)
                }.expectation {
                    select("#txt_title").textIs("Home")
                }
            }
        }
    }
}
```

- `scene` = 1画面。`condition`(前提)→ `action`(操作)→ `expectation`(検証)。検証の無い
  `expectation` は何も確かめていない。
- `ifCanSelect` は出るか分からないダイアログを扱う。`scroll: .down` は折り返しの下の要素に届く。
- **コマンド名を推測しない。** `ft_dsl_commands` が全コマンドとシグネチャを返す。そこに無い名前は存在しない。

## セレクタ

- `#id` を優先する。素のラベル(`"Home"`)はラベル全体との完全一致。`*text*` のワイルドカードは
  動的なテキストにだけ使う。
- `.type[n]` は兄弟要素が増減すると壊れる。スコープで絞る: `#container >> .button`。
- スナップショットで見ていないセレクタは書かない。

## 画面の大きさに依存させない

- 折り返しの下にあるものには `scroll:` か `scrollTo` で届かせる —— 見えている前提にしない。
- スワイプの始点・終点は、確実に窓の中に居る要素にする。
- 1回のスワイプで届く距離を前提にしない。`notExist` を「スクロールで画面外へ出た」の証明に使わない
  (木に残る行数は窓の高さで変わる)。

## 実行が落ちたら

| 失敗の内容 | すること |
|---|---|
| element not found | 失敗時の要素一覧でその要素を探す。`#id` が変わっていれば新しい値がそこに出ている。要素はあるが画面外なら `scroll:` |
| another window was in front of the app | システムアラートや覆いが入力を吸った。`ifCanSelect` かアラートの自動処理(コマンドリファレンス参照)で扱う |
| the app process was not running | アプリが落ちた。シナリオを触る前に `ft_logs` を見る |
| 実際の値つきでアサーションが落ちた | 要素一覧と比べる。アプリが正しいときだけ期待値を直す |

## 関連

- [MCP サーバ](mcp_server_ja.md)
- [その他のエージェント](other_agents_ja.md)
- [コマンドリファレンス](../../commands.md)

### Link
- [index](../index_ja.md)
