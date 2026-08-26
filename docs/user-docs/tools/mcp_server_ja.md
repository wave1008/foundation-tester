# MCP サーバ

`fleetest-mcp` はデバイス操作・シナリオ実行・シナリオ作成を `ft_*` ツールとして公開する stdio
[MCP](https://modelcontextprotocol.io) サーバです。CLI・VSCode 拡張と同じ機能を、人間の代わりに
エージェントから呼び出せるようにしたものです。

## セットアップ

`foundation-tester` リポジトリのルートで Claude Code を開くと、リポジトリ同梱の `.mcp.json`
により `fleetest` サーバが自動的に登録されます(初回呼び出し時にビルドが走ります)。Codex は
`.mcp.json` を読まないので、代わりに `~/.codex/config.toml` へ登録します
([Codex](./codex_skills_ja.md)。サーバの動作に必要なサンドボックス設定も同ページ)。VSCode
拡張やプロジェクト作成を伴わず、別のプロジェクトに MCP サーバだけを追加したい場合は
[Claude Code スキル](./claude_code_skills_ja.md)(`/fleetest:fleetest-mcp`)を参照してください。

## 共通引数

デバイス系の全ツールは同じ宛先指定引数を受け取ります。

| 引数 | 意味 |
|---|---|
| `platform` | `ios`(既定)または `android` |
| `project` | テストプロジェクト名 |
| `profile` | 実行プロファイル名(`profiles/runs/<name>`)。`ft_run_scenario` と同じデバイス・エンジンで動く |
| `udid` | iOS シミュレータの UDID(`ft_list_devices` で取得) |
| `serial` | Android デバイスのシリアル番号 |
| `port` | iOS ブリッジのポート(既定: 起動中のブリッジ) |

一度いずれかの呼び出しでデバイスを明示すると、以降これらを省略した呼び出しにも記憶が使われます。
別のデバイスを一度でも明示すると、以降は再び明示が必要になります。

## ツール一覧

| ツール | 内容 |
|---|---|
| `ft_status` | 接続確認 — 宛先デバイスと、session のアプリが今も前面かを返す |
| `ft_doctor` | FM(Foundation Models)可用性。使えないときは無効になる機能(自己修復・トリアージ・`screenLooksLike`・遮蔽チェック)を返す |
| `ft_launch` / `ft_terminate` | アプリの起動・終了 |
| `ft_install` | パッケージファイルからアプリをインストール(iOS: `.app` / Android: `.apk`) |
| `ft_snapshot` | 画面要素一覧のスナップショット(圧縮された set-of-mark 形式)。`waitFor` でセレクタが出るまで待つ |
| `ft_tap` / `ft_type` / `ft_swipe` / `ft_long_press` | 画面操作 — タップ・入力(`pressEnter: true` で入力後 Enter/IME まで撃つ)・スワイプ・長押し |
| `ft_scroll_to` | セレクタが出るまでスクロールして、撮り直した要素一覧を返す |
| `ft_batch` | 複数の操作/スクロール手を1回の呼び出しにまとめ、1回の承認で実行する |
| `ft_rotate` | デバイスを回転し、新しい向きの要素一覧を返す |
| `ft_navigate` | 戻る / ホーム / タスク切替 |
| `ft_open_url` | アプリを再起動せずディープリンクを配送する |
| `ft_clear_input` | 入力欄を空にする |
| `ft_clear_app_data` | アプリのデータと権限をリセットする(iOS はシミュレータのみ) |
| `ft_dsl_commands` | DSL コマンドの索引(名前と署名)。書く前に存在確認できる |
| `ft_double_tap` / `ft_pinch` / `ft_drag` | ダブルタップ・ピンチ・任意方向のドラッグ |
| `ft_screenshot` | 視覚確認用のスクリーンショット画像 |
| `ft_list_scenarios` / `ft_run_scenario` | シナリオ一覧 / 決定的実行(自動ビルド込み。コンパイルエラーはそのまま返る) |
| `ft_dry_run` | デバイス不要の検証(セレクタの構文誤り・到達しない scene・アサーション無しの expectation・実在しない `#id`) |
| `ft_list_projects` | テストプロジェクトと実行プロファイルの一覧 |
| `ft_draft_scenario` | 探索した操作列を Swift シナリオの下書きにして返す(ファイルには書かない) |
| `ft_list_devices` / `ft_list_apps` / `ft_logs` | デバイス・アプリ・ログの棚卸し |

## 実機

画面操作系のツールは iPhone / Android の実機でも同じように使えます。シミュレータ/エミュレータ
専用の操作は自動で振り分けられます —— `ft_install` は iOS 実機では `simctl` の代わりに
`devicectl` を使い、`ft_clear_app_data` は iOS 実機では使えません(Android は実機でも `pm clear`
が効きます)。in-app エンジンは実機へ注入できないため実機では選ばれません。

## iOS のエンジン選択

`profile` を渡すと、その実行プロファイルのエンジンに追従します(実行時と同じ挙動になります)。
渡さない場合は接続先ポートのブリッジに従います —— in-app ブリッジが動いていれば、それを主にした
hybrid(in-app が実装できない操作 = ホーム/タスク切替/ドラッグ/座標長押しは自動的に XCUITest へ
回る)で動作し、XCUITest ブリッジだけならそのまま使われます。実機は常に XCUITest エンジンです。

## 役割分担

意図的に「探索」ツールは用意していません。探索・判断は呼び出し元のエージェントに残し
(スナップショットと操作プリミティブがあれば自分で探索できるため)、`fleetest` は決定性 ——
操作・再生・検証を担います。

### Link
- [index](../index_ja.md)
