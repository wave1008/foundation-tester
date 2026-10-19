# 用語集

[in English](glossary.md)

fleetest 固有の用語を五十音順に並べました。英字で始まる語は読みの位置に並べています。各語の説明の末尾に、詳しく書いてあるページへのリンクがあります。

## 用語

- **アプリプロファイル** — テスト対象のアプリ(bundle ID / パッケージ名、ビルド成果物のパス)を記す設定です。`profiles/apps/<name>.json` に置きます。 詳しくは [プロファイル(アプリ / 実行)](../reference/project/profiles_ja.md)。
- **FM(Foundation Models)** — Apple のオンデバイスの言語モデルです。macOS 27 以降で Apple Intelligence を有効にすると使えます。使うのはオンデバイスのモデルだけで、画面の情報は Mac の外に出ません。テキストの可視性検証・`screenLooksLike`・`draft-scenario` の構造化などが使います。 詳しくは [環境](environments_ja.md)。
- **MCP サーバ(ft_*)** — デバイス操作・シナリオ実行・シナリオ作成を `ft_*` ツールとして公開する stdio の MCP サーバ(`fleetest-mcp`)です。AIアシスタントが人の代わりに CLI・拡張と同じ機能を呼び出せます。 詳しくは [MCP サーバ](../reference/tools/mcp_server_ja.md)。
- **エンジン** — iOS で画面を読み操作する経路です。in-app(アプリへ注入。高速)・XCUITest(汎用)・hybrid(in-app 主 + XCUITest フォールバック)があり、既定は hybrid です。iOS の実機は常に XCUITest です。Android に選択肢はありません。 詳しくは [実行プロファイルの設定項目](../reference/project/run_profile_ja.md)。
- **仮想デバイス** — Simulator(iOS)と Emulator(Android)の総称です。実機とは区別します。 詳しくは [フリートの考え方](../fleet/concepts_ja.md)。
- **型付きセレクタ(Sel)** — セレクタ記法を型で書けるようにしたものです(例: `.id("login_btn").or(.text("ログイン"))`)。文字列版に併設され、綴り誤りをコンパイラで捕まえられます。 詳しくは [型付きセレクタ(Sel)](../reference/selector/typed_selector_ja.md)。
- **結果 JSON** — `results/runs/<YYYY-MM>/<runID>/` に残る機械可読な記録です。run 全体は `run.json`、シナリオ1本ごとは `scenarios/<シナリオID>.json` で、CI のゲート判定やダッシュボードの情報源になります。 詳しくは [テスト結果ファイル](../reference/testclass/test_result_files_ja.md)。
- **作業フォルダ** — `TestProjects/` があるフォルダです。fleetest を使うあなたのフォルダで、foundation-tester のクローンは既定ではその隣に置きます。 詳しくは [クイックスタート](../quick-start_ja.md)。
- **サンドボックス(Seatbelt)** — シナリオを常に入れて実行する macOS のサンドボックス(Seatbelt)です。秘密の読み取り・任意の書き込み・許可していない宛先への通信などを OS が断ります。デバイス操作と外部への通信は、枠の外の fleetest 本体が代行・中継します。 詳しくは [サンドボックスを確かめて、必要な穴をあける](../security/sandbox_ja.md)。
- **サービス(compose.yaml)** — テスト対象のアプリが依存する DB・API・スタブサーバなどです。`scripts/compose.yaml` に宣言すると、fleetest が run ごとに起動して終わったら止めます。探索用には `fleetest services up` で手で上げます。 詳しくは [アプリが依存するサービス(compose.yaml)](../reference/writing/services_ja.md)。
- **シナリオ** — AIアシスタントが書く Swift のファイルです(1ファイルに複数のテストが入ります)。個々のテスト(`@Test` メソッド)を指すこともあり、実行時のシナリオ ID は `クラス名.メソッド名` です。 詳しくは [テストクラスの作成](../reference/testclass/creating_testclass_ja.md)。
- **シーン(CAE)** — シナリオの中の場面の単位 `scene(n, "題")` です。中を `condition`(前提)・`action`(操作)・`expectation`(検証)の3層で書きます(CAE)。番号と題はレポートの見出しになります。 詳しくは [テストコードの構造](../reference/testclass/testcode_structure_ja.md)。
- **JUnit** — `fleetest run --junit <パス>` で追加出力する JUnit XML 形式のレポートです。JUnit XML を読める CI システムでテスト結果を扱うために使います。 詳しくは [CI で回す](../in_action/ci_ja.md)。
- **自己修復** — セレクタが解決できなくなったとき、直前に解決できた要素の型とラベルの「ロケータの指紋」が今の画面でちょうど1件だけ一致すれば、その要素を使う仕組みです。FM は使いません。直ったセレクタは実行の終わりにシナリオのソースへ自動で書き戻されます(git で差分を確認してコミットします)。 詳しくは [自己修復](../reference/running/self_healing_ja.md)。
- **実機** — 物理端末(本物の iPhone / Android)だけを指す語です。Simulator・Emulator は含みません(それらは「仮想デバイス」です)。実行プロファイルには `"kind": "physical"` と端末の識別子を書きます。 詳しくは [実機を追加する](../fleet/adding_physical_devices_ja.md)。
- **実行プロファイル** — どのアプリを、どのデバイス(それぞれ居るマシンを名乗る)で、どんな実行時設定で回すかを決める設定です。`profiles/runs/<name>.json` に置きます。 詳しくは [実行プロファイルの設定項目](../reference/project/run_profile_ja.md)。
- **スキル** — 導入・プロファイル設定・シナリオ作成などを自動化する Claude Code のスキルです。インストーラが作業フォルダの `.claude/skills/` へコピーし、`/fleetest-scenario` のように名前で呼び出します。 詳しくは [Claude Code のスキル](../reference/tools/claude_code_skills_ja.md)。
- **スナップショット** — 今の画面のアクセシビリティの木です。シナリオを書くときは、スナップショットから実際の id やラベルを採ってセレクタにします(MCP の `ft_snapshot`、CLI の `fleetest snapshot`)。 詳しくは [MCP サーバ](../reference/tools/mcp_server_ja.md)。
- **整定(settle)** — 操作のあとに画面の遷移が落ち着くのを待つことです。ドライバーの中で自動で行うので、固定の `wait()` を置く必要はありません。明示して待つ `waitForSettle` もあります。 詳しくは [wait, waitForDisplay, waitForClose, waitForSettle](../reference/commands/wait_ja.md)。
- **セレクタ** — 画面の要素を文字列1本で指す記法です。`#login_btn`(accessibility id)・`ログイン`(ラベル)・`.button[2]`(型と順番)を、`&&`(かつ)・`||`(または)・`>>`(スコープ)で組み合わせます。 詳しくは [セレクタ式](../reference/selector/selector_expression_ja.md)。
- **相対セレクタ** — 基準の要素からの位置関係で候補を指すセレクタです(例: `通知:rightSwitch`)。対象自身に id や確実なラベルが無い画面で使います。基準を先に書きます。 詳しくは [相対セレクタとスコープ](../reference/selector/relative_selector_ja.md)。
- **テキストの可視性検証** — 木で一致した要素について、その文字が画面に実際に描かれているかをスクリーンショットで確かめ、見えていなければ失敗にする検証です。OCR と FM を組み合わせて判定します。 詳しくは [テキストの可視性検証の判定](../reference/testclass/text_visibility_check_ja.md)。
- **テストクラス** — `@TestClass` を付けた、1つ以上の `@Test` メソッドを持つクラスです。シナリオのファイルは、テストクラスを書いたものです。 詳しくは [テストクラスの作成](../reference/testclass/creating_testclass_ja.md)。
- **テストプロジェクト** — 1つのアプリに対するシナリオ・プロファイル・レポートをまとめる器です。`TestProjects/<name>/` に置きます。 詳しくは [テストプロジェクトの作成](../reference/project/creating_project_ja.md)。
- **テストベース** — シナリオの根拠にする仕様・テスト観点・元ネタを Markdown で置いたものです。`TestProjects/<プロジェクト>/docs/testbases/` に置き、`fleetest draft-scenario` でシナリオの下書き(`@Draft` 付き)にできます。 詳しくは [テストベースとシナリオの下書き](../reference/running/testbases_ja.md)。
- **デバイスモニター** — VSCode 拡張のタブで、デバイスの画面と状態を見る場所です。上から順に、ラインビュー(デバイスタイルの並び)・グリッドビュー(選択したデバイスの拡大表示)・実行ログビュー(選択したデバイスの実行ログ)の3つの常設のペインに分かれます。グリッドビューと実行ログビューに出るのは、ラインビューで選択したデバイスだけです。 詳しくは [VSCode 拡張](../reference/tools/vscode_extension_ja.md)。
- **dry-run** — デバイスにも FM にも触れず、シナリオのステップを列挙・検証する実行です(`fleetest run --dry-run`)。セレクタの構文誤りやアサーションの無い `expectation` などを数秒で見つけます。 詳しくは [dry-run(No-Load-Run)](../reference/running/dry_run_ja.md)。
- **hooks(run-setup.sh / run-teardown.sh)** — run の前後に走らせるスクリプトです。ワークスペースの `scripts/` に置き、`run-setup.sh` はサービスの起動完了を待ってから、`run-teardown.sh` は run の後に走ります。死んだ run が残した後始末は `fleetest hooks reap` が行います。 詳しくは [アプリが依存するサービス(compose.yaml)](../reference/writing/services_ja.md)。
- **フリート** — テストを実行するデバイス(仮想デバイスと実機)の集まりです。ローカルとリモートの Mac のデバイスを足して増強できます。マシンと実行プロファイルの組を並べた「フリート定義」(`profiles/fleets/<名前>.json`)を `--fleet` で指定することもできます。 詳しくは [フリートの考え方](../fleet/concepts_ja.md)。
- **ブリッジ** — fleetest とデバイスをつなぐ、デバイス側の常駐部分です。iOS は XCUITest のランナーと、アプリの中に注入する in-app の2種類、Android はデバイス上の常駐サーバです。`fleetest bridge up` / `down` / `status` で扱います。 詳しくは [CLI リファレンス](../reference/tools/cli_ja.md)。
- **保持容量** — 録画・レポート・ログなどがカテゴリごとに溜まる量の上限です。使用量が上限の 90% に達したカテゴリを、古いものから 90% まで削除します。結果の JSON は削除されません。上限はこの Mac の設定で、`fleetest clean` でも掃除できます。 詳しくは [長く使うためのメンテナンス](../in_action/maintenance_ja.md)。
- **マシン設定** — この Mac の `~/.config/fleetest/config.json` に書く設定です。サンドボックスの許可・サービスのランタイム・保持容量のように、その Mac を使う人が決めるものを置きます。プロジェクトや実行プロファイルからは緩められません。 詳しくは [マシン設定(config.json)](../reference/project/machine_settings_ja.md)。
- **マシン名** — ランナー機に手元で付ける名前(例: `M1Max`)です。プロファイルにはホスト名や IP アドレスではなくこの名前を書きます。手元の Mac は `local` です。`fleetest remote machines add` で登録します。 詳しくは [Mac を追加する](../fleet/adding_mac_ja.md)。
- **ライブ操作** — デバイスモニターのタブの1つで、デバイスの画面をマウスで直接操作します(クリックでタップ・ドラッグでスワイプ)。AIアシスタントを使わずにシナリオを作る入口にもなります。 詳しくは [VSCode で見る](../tutorial/watching_in_vscode_ja.md)。
- **run** — `fleetest run` などで行う、シナリオをまとめて実行する1回の実行です。runID が付き、結果が `results/` に記録されます。 詳しくは [シナリオの実行](../reference/running/running_scenarios_ja.md)。
- **ランナー機** — テストを実行させる別の Mac です。手元の Mac から SSH でログインできれば、同じ LAN になくても構いません。ログインしたままにしておきます。 詳しくは [フリートの考え方](../fleet/concepts_ja.md)。
- **レスポンス計測** — 実機で既存のシナリオを回しながら、画面を動かす操作ごとに「最初のフレームまで」(入力を注入してからアプリが最初のフレームを出すまで)と「操作可能まで」(注入から、次に操作する要素が見つかる・有効・覆われていない・止まっている状態になるまで)を測る機能です。実行プロファイルの `responseMeasurement: true` で有効になります。 詳しくは [レスポンス計測](../reference/running/response_measurement_ja.md)。
- **レポート** — シナリオ実行ごとに成否を問わず `reports/scenario-*.md` へ出る Markdown です。`scene → condition/action/expectation → ステップ` の階層、失敗時の要素一覧とスクリーンショット、セレクタの修正提案を含みます。 詳しくは [テスト結果ファイル](../reference/testclass/test_result_files_ja.md)。
- **レーン** — run の中で、実行プロファイルのデバイス1台ぶんに当たる実行の流れです(ワーカーと同じ単位)。 詳しくは [並列実行](../reference/running/parallel_execution_ja.md)。
- **ワーカー** — run の中でシナリオを受け持つ単位です。実行プロファイルの各デバイスが1ワーカーになり、シナリオはその間で分配されます。並列数はワーカーの数(解決後のデバイス数)です。 詳しくは [並列実行](../reference/running/parallel_execution_ja.md)。

## コマンドのオプション

[CLI リファレンス](../reference/tools/cli_ja.md)のうち、実行の送り先や分配に関わるものです。

- **`--fleet`** — フリート定義(マシンと実行プロファイルの組の一覧)を指定して、複数のマシンへ送って同時に実行します。`--split` を付けると、同じシナリオを全マシンで回す代わりに振り分けます。 詳しくは [リモート実行](../fleet/remote_runners_ja.md)。
- **`--broadcast`** — 選んだシナリオを分配せずに、実行プロファイルの全デバイスで1回ずつ実行します(ウォームアップなどの用途)。`--profile` が必須です。 詳しくは [並列実行](../reference/running/parallel_execution_ja.md)。
- **`--runner`** — `fleetest run` の実行を、登録したマシン名(または `user@host`)のランナー機へ送って実行します。実行プロファイルが必要です。 詳しくは [リモート実行](../fleet/remote_runners_ja.md)。

### Link
- [index](../index_ja.md)
