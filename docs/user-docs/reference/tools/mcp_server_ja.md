# MCP サーバ

`fleetest-mcp` はデバイス操作・シナリオ実行・シナリオ作成を `ft_*` ツールとして公開する stdio
[MCP](https://modelcontextprotocol.io) サーバです。CLI・VSCode 拡張と同じ機能を、人間の代わりに
エージェントから呼び出せるようにしたものです。

## セットアップ

`fleetest` サーバは導入時(`install.sh` / `/fleetest-setup`)に登録されます。Claude Code は
作業フォルダの `.mcp.json` に**クローンの絶対パス**で書かれるので、どこでエージェントを開いても
同じサーバが起動します(初回呼び出し時にビルドが走ります)。VSCode 拡張やプロジェクト作成を
伴わず、別のプロジェクトに MCP サーバだけを追加したい場合は
[Claude Code スキル](./claude_code_skills_ja.md)(`/fleetest-mcp`)を参照してください。

**それ以外のエージェント(Codex・Cline など)でも使えます。** `fleetest-mcp` は標準の stdio
MCP サーバなので、MCP に対応したクライアントならどれでも登録できます。設定の書き方は各
クライアントに従い、起動コマンドとして次を渡してください(`<ABS_TOOL_ROOT>` は clone の
絶対パス。TOML での書き方と手順書の渡し方は[Claude Code 以外の AIアシスタント](./other_agents_ja.md)):

```json
"fleetest": {
  "command": "bash",
  "args": ["-c", "exec \"<ABS_TOOL_ROOT>/Scripts/mcp-server.sh\""],
  "env": { "FT_TOOL_ROOT": "<ABS_TOOL_ROOT>" }
}
```

`bash -c` で足ります —— `mcp-server.sh` 自身が先頭で `/opt/homebrew/bin:/usr/local/bin` を PATH に足すので、
最小の PATH でサーバを起こすクライアントでも Swift/Xcode を引けます。`-l`(ログインシェル)にはしないでください:
`~/.bash_profile` の `echo` が stdout に混ざり JSON-RPC のハンドシェイクを壊します。`FT_TOOL_ROOT` はブリッジ資産の位置で、
cwd(受け手パッケージ)とは別物です。

## 共通引数

デバイス系の全ツールは同じ宛先指定引数を受け取ります。

| 引数 | 意味 |
|---|---|
| `platform` | `ios`(既定)または `android` |
| `project` | テストプロジェクト名 |
| `profile` | 実行プロファイル名(`profiles/runs/<name>`)。`ft_run_scenario` と同じデバイス・エンジンで動く |
| `udid` | iOS デバイスの UDID(Simulator・実機とも。`ft_list_devices` で取得) |
| `serial` | Android デバイスのシリアル番号 |
| `port` | iOS ブリッジのポート(既定: 起動中のブリッジ) |
| `allowVersionSkew` | ブリッジのプロトコル版がツールと合わなくても操作する(既定 off = 拒否。押し通した応答には毎回警告が付く) |

一度いずれかの呼び出しでデバイスを明示すると、以降これらを省略した呼び出しにも記憶が使われます。
別のデバイスを一度でも明示すると、以降は再び明示が必要になります。

## ツール一覧

| ツール | 内容 |
|---|---|
| `ft_status` | 接続確認 — 宛先デバイスと、session のアプリが今も前面かを返す |
| `ft_doctor` | FM(Foundation Models)可用性。使えないときは無効になる機能(`screenLooksLike`・遮蔽チェック)を返す。自己修復は FM を使わないため影響を受けない |
| `ft_launch` / `ft_terminate` | アプリの起動・終了 |
| `ft_install` | パッケージファイルからアプリをインストール(iOS: `.app` / Android: `.apk` または分割バンドルの `.apks`) |
| `ft_snapshot` | 画面要素一覧のスナップショット(圧縮された set-of-mark 形式)。`waitFor` でセレクタが出るまで待つ |
| `ft_tap` / `ft_type` / `ft_swipe` / `ft_long_press` | 画面操作 — タップ・入力(`pressEnter: true` で入力後 Enter/IME まで撃つ)・スワイプ・長押し |
| `ft_scroll_to` | セレクタが出るまでスクロールして、撮り直した要素一覧を返す。`scrollFrame:` には `scroll` 印の容器のセレクタのほか、**任意の要素の ref**(その frame を帯として使う。Compose のチップ列・カルーセル向け)も渡せる |
| `ft_batch` | 複数の操作/スクロール手を1回の呼び出しにまとめ、1回の承認で実行する |
| `ft_rotate` | デバイスを回転し、新しい向きの要素一覧を返す |
| `ft_navigate` | 戻る / ホーム / タスク切替 |
| `ft_hide_keyboard` | ソフトキーボードを閉じる(Android のみ。iOS は `ft_type` の `pressEnter`) |
| `ft_open_url` | アプリを再起動せずディープリンクを配送する |
| `ft_clear_input` | 入力欄を空にする |
| `ft_clear_app_data` | アプリのデータと権限をリセットする(iOS 実機は `ft_install` のパスか `packagePath:` で uninstall + install に振り替える) |
| `ft_dsl_commands` | DSL コマンドの索引(名前と署名)。書く前に存在確認できる |
| `ft_double_tap` / `ft_pinch` / `ft_drag` | ダブルタップ・ピンチ・任意方向のドラッグ。iOS の Compose アプリでは実機と `xcuitest` の構成でダブルタップが効かないので、拡大が目的なら `ft_pinch` を使う([ジェスチャ](../commands/gestures_ja.md)) |
| `ft_gesture` | 指ごとの時刻つき経路を1本の連続タッチとして再生する(区切りで指を離さない)—— パターンロック・長押しからのドラッグ・独自の複数指ジェスチャ用。絶対座標のみ・ref/セレクタ形は無い |
| `ft_screenshot` | 視覚確認用のスクリーンショット画像 |
| `ft_capture_element` | 要素を画像分類器の見本として保存し、学習の点検結果を返す(`checkIsON` / `imageIs` の見本。[imageIs](../commands/image_assertion_ja.md)) |
| `ft_list_scenarios` / `ft_run_scenario` | シナリオ一覧 / 決定的実行(自動ビルド込み。コンパイルエラーはそのまま返る)。`id` にクラス名を渡すと `fleetest run` と同じく `@Deleted`/`@Draft` 以外の全本を順に流す。`profile:` は `port`/`serial`/`platform`/`udid` と併用できない。**`fleetest run` と違い、プロファイルの setup/teardown スクリプト・run 開始時の home・`results/` への記録は行わない**(フルの run は CLI で)。アプリを入れるのは、`autoInstall` のアプリを持つ `profile:` を iOS で指定したときだけ(ワークスペースへコピーし、入っている版が古ければインストールする)。それ以外は `ft_install` で入れておく。**失敗は isError で返り**、失敗したステップ・失敗した瞬間の要素一覧とスクリーンショット(最初に落ちた1本だけ)・レポートパスが載る |
| `ft_start_run` / `ft_run_status` / `ft_stop_run` | `fleetest run --profile` と同じ本番の実行。`ft_start_run` は裏で始めてすぐ返り(`profile` 必須・`scenario` / `folder` は配列・`failed`・`broadcast`・その回だけ別の機械へ送る `runner` = 登録済みの機械名か `local`)、`ft_run_status` が進み具合と結果(runID・合否・失敗したシナリオのレポート・ログの末尾)を返す。止めるのは `ft_stop_run`(SIGTERM)。結果の履歴(`results/`)・録画・セットアップ/後始末のスクリプトまで含む。MCP サーバの中で動くので、シェルのサンドボックスの中のエージェント(Codex の既定など)からも使える。同時に動かせるのはこのサーバから1本 |
| `ft_results` | 結果の履歴。`fleetest results <query>` と同じ文面(JSON は無い)。`query` は必須で `list` / `summary` / `flaky` / `trend`(`scenario` 必須) / `devices` / `slow` / `insights` / `log`(1 run のシナリオごとの実行ログ。`runId`・既定 `latest`)。任意: `since`(既定 `90d`・`log` では使わない)・`scenario`・`limit`(`list` / `slow`)・`minRuns`(`flaky`)。ファイルを読むだけなので、シェルのサンドボックスの中のエージェント(Codex の既定など)からも使える |
| `ft_dry_run` | デバイス不要の検証(セレクタの構文誤りは失敗 = isError。アサーション無しの expectation・実在しない `#id` は ⚠️ 行の警告で、失敗にはしない)。platform 宣言の無いシナリオは `platform:`(既定 ios)で `ios { } / android { }` の分岐と `#id` 台帳を選ぶ |
| `ft_list_projects` | テストプロジェクトと実行プロファイルの一覧 |
| `ft_draft_scenario` | 探索した操作列を Swift シナリオの下書きにして返す(ファイルには書かない) |
| `ft_list_devices` / `ft_list_apps` / `ft_logs` | デバイス・アプリ・ログの棚卸し。`ft_list_devices` の `profile:` はその実行プロファイルが参照するデバイスだけに絞る。別の機械に居るデバイスは名前だけ挙げて一覧には出さない |

## 実機

画面操作系のツールは iPhone / Android の実機でも同じように使えます。Simulator/Emulator
専用の操作は自動で振り分けられます —— `ft_install` は iOS 実機では `simctl` の代わりに
`devicectl` を使い、`ft_clear_app_data` は iOS 実機では uninstall + install(直前の `ft_install` の
パス、または `packagePath:`)でデータを消します(Android は実機でも `pm clear` が効きます)。
システムのアラートを SpringBoard で閉じた後は `ft_launch bundleId: <app> resume: true` で、
終了せずにアプリへ戻れます(xcuitest エンジン / Android)。in-app エンジンは実機へ注入できないため実機では選ばれません。

## iOS のエンジン選択

`profile` を渡すと、その実行プロファイルのエンジンに追従します(実行時と同じ挙動になります)。
渡さない場合は接続先ポートのブリッジに従います —— in-app ブリッジが動いていれば、それを主にした
hybrid(in-app が実装できない操作 = ホーム/タスク切替/ドラッグ/座標長押しは自動的に XCUITest へ
回る)で動作し、XCUITest ブリッジだけならそのまま使われます。実機は常に XCUITest エンジンです。

## 役割分担

意図的に「探索」ツールは用意していません。探索・判断は呼び出し元のエージェントに残し
(スナップショットと操作プリミティブがあれば自分で探索できるため)、`fleetest` は決定性 ——
操作・再生・検証を担います。

## サンドボックスと承認

MCP サーバはエージェントのシェルのサンドボックスの**外**で動きます。ビルドと実行を伴うツール
(`ft_list_scenarios`・`ft_dry_run`・`ft_run_scenario`・`ft_start_run`)は、プロジェクトのシナリオ(`.swift`)を
任意の Swift のコードとして実行します(dry-run でも動きます)。

- **シナリオは常に fleetest のサンドボックス(macOS の Seatbelt)の中で動きます。** MCP からでも、CLI からでも、
  拡張からでも同じです。サンドボックスの中のシナリオは:
  - 書けるのは、レポートの出力先・プロジェクトの `.fleetest/`・シナリオ専用の一時フォルダなどに限られます。シナリオのソース、
    fleetest 本体のクローン、ホームの他の場所には書けません。シナリオのコードから書くときは
    [`TestLog.directoryForLog` / `TestLog.directoryForTemp`](../commands/test_log_ja.md) を使います(`NSTemporaryDirectory()` には書けません)。
  - 認証情報や個人データの定番の置き場(`~/.ssh`・`~/.aws`・`~/.config`・`~/.gradle`・キーチェーン・ブラウザの
    プロファイル・Cookies・メール・メッセージ・シェルの履歴など)を読めません。
  - fleetest を起こした環境の環境変数は、fleetest が使うもの(`PATH`・`HOME`・`DEVELOPER_DIR`・`ANDROID_HOME`・
    `FT_*` など)しか見えません。`.mcp.json` の `env` やシェルに置いたトークンはシナリオに渡りません。
  - 繋げるのはこの Mac の中(ブリッジ)だけです。外部への通信は、許可したドメインだけがプロキシ経由で通ります。
  - 他のアプリを起こしたり、Simulator・iOS 実機・Android 端末を fleetest が使う決まった操作以外で操作したりできません
    (Simulator・iOS 実機・Android(adb)の操作は fleetest 本体が代わりに行い、決まった形だけを通します。
    シナリオからは adb サーバと Emulator のコンソールに繋げず、adb の鍵も読めません)。
- **サンドボックスの設定はこの Mac の `~/.config/fleetest/config.json` の `sandbox` だけ**に置きます
  (プロジェクトの中には置きません。プロジェクトはエージェントが書き換えられるためです)。

  ```json
  {
    "sandbox": {
      "denyRead": ["~/work/secrets"],
      "allowedDomains": ["api.example.com", "*.example.org"]
    }
  }
  ```

  `denyRead` は既定の一覧に**足す**場所、`allowedDomains` はシナリオから通してよい宛先です(省略すると外部へは
  一切出られません)。`"disabled": true` でこの Mac のサンドボックスを外せます。`"allowDirectAdb": true` にすると、
  シナリオが adb と bundletool を fleetest 本体に頼まず自分で使えるようになります(adb サーバと Emulator のポート、
  `~/.android` を開けます)。そのぶん、シナリオから Emulator の中のシェル経由で外部へ出られ、繋がった全 Android 端末に
  届くようになります(ほかの制限はそのまま)。所要時間はほぼ変わらないので(adb 1回あたり 1ms 未満の差)、
  必要なとき以外は使わないでください。知らないキーや壊れた JSON が
  あると、シナリオを起動せずにエラーで止まります。Claude Code では、インストーラが作業フォルダの
  `.claude/settings.json` にこのフォルダの編集を拒否する設定を書きます。
- **サンドボックスの外に残るもの**があります。ブリッジのように、この Mac の中で動くサービスには繋げます
  (他のデバイスのブリッジや、Mac の localhost で動く他のサービスも含みます)。読めたファイルの中身を、アプリへの入力としてデバイスへ
  送ることもできます。テスト対象のアプリ自体も枠の外で動きます。また、`ft_start_run` が実行する
  setup / teardown スクリプトと、ビルド時に評価される `Package.swift` はサンドボックスの対象外です。
- **承認を省く範囲は、何を外で動かすかで選んでください。**

  | 承認を求めるツール | 使い勝手 | 人を通るもの |
  |---|---|---|
  | なし | 止まらない | なし(信頼できるリポジトリとアプリが前提) |
  | `ft_start_run`(おすすめ) | テストの実行を頼んだときに1回 | setup / teardown スクリプト・別の機械への送り出し |
  | `ft_list_scenarios`・`ft_dry_run`・`ft_run_scenario`・`ft_start_run` | シナリオ作成中もコンパイル・確認のたびに聞かれる | シナリオの実行すべて |

  Claude Code では、インストーラが作業フォルダの `.claude/settings.json` に「fleetest のツールは許可
  (`mcp__fleetest`)・`ft_start_run` だけ確認(`ask`)」を書きます(おすすめの形。確認を外したければ `ask` から
  消せば、以後の更新でも戻しません)。あわせて、fleetest 本体のクローンを読み取り専用にする設定(読むのは許可・
  編集は拒否)も書きます(作業フォルダがクローンの中にある構成では書きません)。Auto モードでは、確認の要否を
  AI が自動で判断します。ただし判断の対象はツールの呼び出しで、シナリオの中身ではありません。
  Codex での書き方は[Claude Code 以外の AIアシスタント](other_agents_ja.md)にあります(サーバ全体は `default_tools_approval_mode`、
  ツールごとは `[mcp_servers.fleetest.tools.<ツール名>]` の `approval_mode`)。読むだけのツールに承認を省く
  `writes` は、画面の操作(タップ・入力)も書き込みとして聞かれるので、探索のたびに数十回の承認になります。
- **各ツールは MCP の annotations で性質を宣言します。** 承認の扱いをこれで分けるクライアントでは、宣言どおりに
  扱われます。

  | 宣言 | ツール |
  |---|---|
  | 読むだけ(`readOnlyHint: true`) | `ft_status`・`ft_list_*`・`ft_snapshot`・`ft_screenshot`・`ft_logs`・`ft_results`・`ft_run_status`・`ft_dsl_commands`・`ft_doctor`・`ft_draft_scenario` |
  | デバイスの画面やアプリの状態を変える | タップ・入力・スワイプなどの操作、`ft_launch`・`ft_terminate`・`ft_open_url`・`ft_batch`、`ft_capture_element`(プロジェクトへ見本を書く) |
  | 取り返しがつかない(`destructiveHint: true`) | `ft_clear_app_data`・`ft_install`・`ft_stop_run` |
  | プロジェクトのコードを実行する(`destructiveHint: true`・`openWorldHint: true`) | `ft_list_scenarios`・`ft_dry_run`・`ft_run_scenario`・`ft_start_run` |
- **他人から受け取ったシナリオは、中身を確かめてから実行してください。** サンドボックスはホストを守りますが、
  上の「外に残るもの」と、テスト対象のアプリやアカウントへの操作(削除・購入など)は止めません。
- **`ft_start_run` の `runner` は、登録済みの機械名と `local` だけを受け付けます。** `user@host` のような
  生の宛先は断ります(シナリオとプロファイルを、利用者が登録していない機械へ送らないため)。
  機械は `fleetest remote machines add` で登録します。CLI の `fleetest run --runner` は生の宛先も受け付けます。
- `ft_stop_run` / `ft_run_status` が扱うのは、そのサーバが `ft_start_run` で起こした実行だけです。
- `ft_start_run` は決まったコマンド(`fleetest run`)に、検査した引数を配列で渡します(シェルを通さないので、
  引数から任意のコマンドは注入できません)。`profile`・`runner`・`scenario`・`folder` の値が `-` で始まると断ります
  (`fleetest run` のオプションとして読まれ、上の `runner` の制限をすり抜けられるためです)。

## 構造化出力(明示的に有効にしたときだけ)

サーバの環境(MCP の登録の `env`)に `FT_MCP_STRUCTURED_CONTENT=1` を設定すると、`ft_run_scenario`・
`ft_dry_run`・`ft_list_scenarios` が `structuredContent`(シナリオごとの成否とレポートのパス、または
シナリオの一覧を JSON にしたもの)も返します。クライアントが MCP 2025-06-18 以降で交渉したときだけ
送ります。**Claude Code では有効にしないでください**: Claude Code は `structuredContent` があると
それだけをモデルに渡すため、文面の注記と失敗時のスクリーンショットが届かなくなります。

### Link
- [index](../../index_ja.md)
