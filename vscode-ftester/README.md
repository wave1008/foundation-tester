# vscode-ftester

ftester(Swift 製の iOS/Android UI テストツール。リポジトリルートの `README.md` 参照)の
シナリオを VS Code の Test Explorer に表示・実行・デバッグするための拡張です。

## 機能

- ftester CLI (`ftester api ...`) の spawn・NDJSON/JSON パース・実行キュー(`src/cli.ts`)
- シナリオツリー(folder → class → @Test メソッド)の表示・再読込(`src/testTree.ts`)
- `Projects/*/Scenarios/**/*.swift` のファイル監視による自動再読込(`src/watcher.ts`)
- Test Explorer の Run プロファイル「実行」「実行 (dry-run)」によるシナリオ実行と
  結果反映(`src/runHandler.ts` / `src/runReducer.ts`)
- Test Explorer の Debug プロファイル「デバッグ」・DAP(Debug Adapter Protocol)アダプタによる
  ブレークポイント・一時停止・ステップ実行(`src/debugAdapter.ts` / `src/debugConfig.ts`)
- 読み取り専用の「ステップ一覧」TreeView(`src/stepsView.ts` / `src/stepsModel.ts`)。
  Test Explorer のビューコンテナに `ftester ステップ` ビューとして表示され、
  アクティブエディタのカーソル位置に追従してシナリオの scene/ステップを一覧表示する
- `ftester.profile` 設定による実行プロファイル(`Projects/<project>/profiles/runs/<name>.json`)
  実行。実行・デバッグ実行の両方に対応し、デバイス供給・自動インストールを CLI 側(`ftester api
  run --profile`)に任せられる(詳細は下記「実行プロファイル(`ftester.profile`)について」)。
  プロファイル実行(非dry-run・非デバッグ)は CLI 側が並列実行になり、`src/runEventBus.ts` 経由で
  実行イベントがデバイスモニターのログレーンにも配信される(詳細は下記「並列実行とログレーン」)
- デバイスモニター(`src/monitorPanel.ts` / `src/monitorModel.ts`)。コマンド
  **「ftester: デバイスモニターを表示」**で開く Webview パネルで、`ftester api monitor` を
  ポーリングして接続中のデバイス一覧・状態を取得し、各デバイスの画面は既定でヘッドレス映像
  ストリーミング(`ftester-simstream`/`ftester-androidstream`)で表示する(設定でポーリングの静止画にも切替可)
  (詳細は下記「デバイスモニター」)。並列実行中は同じパネル下部にワーカー(デバイス)別の
  ログレーンを表示する(詳細は下記「並列実行とログレーン」)。各タイルは右クリックメニューから
  `ftester api device-up`/`ftester api device-down` でそのデバイス1台だけを起動/停止できる
- ライブ操作(`src/monitorLiveController.ts` / `src/liveModel.ts`)。デバイスモニターと同じ
  Webview パネルの「ライブ操作」タブで、画像上のタップ/ドラッグ(スワイプ)/長押し・要素一覧タップ・
  テキスト入力・ホーム/タスク切替の操作と、操作を記録して Swift シナリオを生成するレコーディングを、
  `ftester api list-devices`(デバイス一覧のみワンショット)と `ftester api live serve`(常駐プロセス。
  選択デバイスごとに1つ spawn し、NDJSON でコマンド送信・観測イベント受信を行う)経由で行う。
  コマンド **「ftester: ライブ操作を表示」**(`ftester.showLiveControl`)を実行するとパネルが開き
  (または前面に出て)このタブへ切り替わる(詳細は下記「ライブ操作」)
- FM探索(`src/exploreCommand.ts` / `src/exploreModel.ts`)。コマンド
  **「ftester: FM探索でシナリオを生成」**(`ftester.explore`)で、macOS GUI 版(`ftester-gui`)の
  「FM探索」タブに相当する FM エージェントによるアプリ探索 → Swift シナリオ生成
  (`ftester api explore`)を実行する(詳細は下記「FM探索」)
- 自己修復(`ftester.heal` 設定)と、修復候補の確認・確定(`src/healModel.ts` /
  `src/healReviewPanel.ts`)。`--heal` 付きの実行で修復候補(`fixSuggestion`)が見つかると、
  実行終了後に確認パネルが自動的に開き、承認するとシナリオソースへ反映される
  (詳細は下記「自己修復(heal)と修復候補の確定」)
- 実行プロファイルの編集支援(`src/profileModel.ts` / `src/profileDiagnostics.ts`)。
  コマンド **「ftester: 実行プロファイルを選択」**(`ftester.selectProfile`)による
  `ftester.profile` 設定の切り替え、プロファイルJSON保存時の自動検証+
  コマンド **「ftester: プロファイルを検証」**(`ftester.validateProfiles`)による
  問題パネル(Diagnostics)への反映、`profiles/{apps,machines,runs}/*.json` の
  補完・型チェック用 JSON スキーマ(`schemas/*.schema.json`)を提供する
  (詳細は下記「実行プロファイルの編集支援」)

## 前提

この拡張は `ftester` CLI(Swift 製)を spawn して動きます。CLI とシナリオ資産は
`foundation-tester` リポジトリのワークスペースから来るため、**拡張を入れた VS Code で
そのリポジトリのルートを開いている**ことが前提です(拡張は `Package.swift` を含むフォルダで
起動し、`Projects/*/Scenarios/**/*.swift` を読みます)。

**使う(配布された .vsix を入れて動かす)ために必要なもの:**

- macOS(iOS ならさらに Xcode / `simctl`、Android ならさらに Android SDK / `adb`)
- `foundation-tester` リポジトリを clone 済みで、VS Code でそのルートを開けること
- リポジトリルートでビルド済みの `ftester` バイナリ(`swift build --product ftester`。
  下記クイックスタート参照)

**拡張自体をビルド/開発するために追加で必要なもの(使うだけなら不要):**

- Node.js v24 系 / npm v11 系(推奨。それ以外のバージョンでも概ね動作するはずです)

## クイックスタート(配布された .vsix を受け取った場合)

`.vsix` ファイルだけを受け取った人はこの手順で動かせます(拡張のソースやビルド環境は不要)。

1. `foundation-tester` リポジトリを clone し、リポジトリルートで `ftester` CLI をビルドします。

   ```bash
   git clone https://github.com/wave1008/foundation-tester.git
   cd foundation-tester
   swift build --product ftester   # → .build/debug/ftester
   ```

2. `.vsix` を VS Code に入れます。「拡張機能」ビュー右上の `...` メニュー →
   `VSIX からのインストール...` で選ぶか、以下を実行します。

   ```bash
   code --install-extension vscode-ftester-<version>.vsix
   ```

   publisher 未検証(marketplace 未公開)による警告が出ることがありますが、ローカル
   インストールでは無視して問題ありません。

3. VS Code で **この `foundation-tester` リポジトリのルート**(`Package.swift` があるフォルダ)を
   開きます。`ftester.binaryPath` の既定 `.build/debug/ftester` が手順1のバイナリを指すので、
   そのまま Test Explorer にシナリオが表示されます。別の場所にビルドした場合のみ
   `.vscode/settings.json` で `ftester.binaryPath` を上書きしてください。

## セットアップ(拡張を開発する)

### 開発(F5 で Extension Development Host を起動)

1. リポジトリルートで ftester CLI をビルドします。

   ```bash
   cd ..   # リポジトリルート(foundation-tester/)へ
   swift build --product ftester
   ```

   既定では `ftester.binaryPath` 設定が `.build/debug/ftester`(ワークスペースルート基準の
   相対パス)を指すので、上記の debug ビルドで動作します。別の場所にビルドした場合は
   `.vscode/settings.json` などで `ftester.binaryPath` を上書きしてください。

2. この拡張の依存関係をインストールします。

   ```bash
   cd vscode-ftester
   npm ci
   ```

3. ビルド(esbuild バンドル + 型チェック)します。

   ```bash
   npm run compile
   ```

   ソース変更を監視しながらビルドし続けたい場合は `npm run watch` を使ってください。

4. VS Code でこの `vscode-ftester/` フォルダを開き、**F5** で
   「Extension Development Host」を起動します(`.vscode/launch.json` が無い場合は
   VS Code の既定の「拡張機能の開発」構成が使えます。`Run Extension` が無ければ
   `Extension Development Host` を選択してください)。

5. 起動した Extension Development Host 側で、この `foundation-tester` リポジトリの
   ルートフォルダ(`Package.swift` があるフォルダ)を開きます。

### パッケージ化して .vsix をインストールする

F5 の開発ホストを使わず、通常の VS Code に拡張として入れたい場合は `.vsix` を作って
インストールします。

```bash
cd vscode-ftester
npm ci
npm run package        # vsce package → vscode-ftester-<version>.vsix
```

- publisher 未検証(marketplace 未公開)による警告は出ますが、ローカルインストール目的では
  無視して問題ありません。
- 生成された `.vsix` はリポジトリにコミットしないでください(`.gitignore` に `*.vsix` 済み)。

生成した `.vsix` は VS Code の「拡張機能」ビュー右上の `...` メニュー →
`VSIX からのインストール...` で選択するか、以下のコマンドでインストールします。

```bash
code --install-extension vscode-ftester-<version>.vsix
```

インストール後は Extension Development Host のときと同様、`foundation-tester` リポジトリの
ルートフォルダを開けば動作します。

## 設定一覧(`ftester.*`)

`.vscode/settings.json`(ワークスペース設定)または VS Code の設定 UI から変更できます。

| 設定キー | 型 | 既定値 | 説明 |
|---|---|---|---|
| `ftester.binaryPath` | string | `.build/debug/ftester` | ftester CLI バイナリのパス。相対パスはワークスペースルート基準で解決される。**存在しなければ PATH から `ftester` を探す**(mint 導入・Tier 2 で `~/.mint/bin` を PATH に入れた場合など) |
| `ftester.project` | string | `""` | 対象のテストプロジェクト名(`Projects/<name>` の `<name>`)。空なら自動判定(`Projects/` 直下が1つならそれを使用。複数あれば選択を促す) |
| `ftester.profile` | string | `""` | 使用する実行プロファイル名(`Projects/<project>/profiles/runs/<name>.json` の `<name>`)。空なら未指定。非空なら実行・デバッグ実行の両方で `platform`/`port`/`serial` の代わりにこちらが使われる |
| `ftester.platform` | `"ios"` \| `"android"` | `"ios"` | 対象プラットフォーム。`ftester.profile` が空のときだけ使われる |
| `ftester.port` | number | `0` | ブリッジ接続ポート。`0` は未指定(CLI 既定値を使用)。`ftester.profile` が空のときだけ使われる |
| `ftester.serial` | string | `""` | Android デバイスのシリアル番号。空は未指定。`ftester.profile` が空のときだけ使われる |
| `ftester.buildBeforeRun` | boolean | `true` | CLI 呼び出し前に Swift ビルドを行うかどうか。`false` なら CLI 呼び出しに `--skip-build` を付与する |
| `ftester.heal` | boolean | `false` | 実行時に FM によるロケータ自己修復(`--heal`)を有効にする。実行完了後、修復候補があれば確認パネルが開き、承認するとソースに反映される(詳細は下記「自己修復(heal)と修復候補の確定」) |
| `ftester.monitorInterval` | number | `2` | デバイスモニターの更新間隔(秒)。`0.5` 未満は `0.5` として扱われる |
| `ftester.monitorMaxWidth` | number | `960` | デバイスモニターのフレーム画像の長辺px(240〜1600)。大きいほど鮮明だが転送量が増える |
| `ftester.liveFps` | number | `12` | ライブ操作の自動フレーム更新レート上限(fps、3〜30)。大きいほど滑らかだがホスト負荷が増える |
| `ftester.iosStreamEnabled` | boolean | `true` | iOS の画面更新に映像ストリーミング(`ftester-simstream`)を使う。無効・ヘルパー未ビルド時はポーリングにフォールバック |
| `ftester.androidStreamEnabled` | boolean | `true` | Android の画面更新に映像ストリーミング(`ftester-androidstream`)を使う。無効・ヘルパー未ビルド・adb 未検出時はポーリングにフォールバック |

## 実行プロファイル(`ftester.profile`)について

`ftester.profile` にプロファイル名(`Projects/<project>/profiles/runs/` にある `.json` の
拡張子抜きファイル名)を設定すると、Test Explorer の「実行」「実行 (dry-run)」「デバッグ」の
いずれも `ftester api run --profile <name>` / `ftester api run --debug --profile <name>` で
呼び出されるようになります(`ftester.platform`/`ftester.port`/`ftester.serial` は無視されます)。

- プロファイルはデバイス(シミュレータ/実機/エミュレータ)の自動プロビジョニングと
  アプリの自動インストールを行います。**実デバイスでの実行(dry-run 以外)は、対象デバイスが
  あらかじめ起動済みであることが前提です。** iOS シミュレータ・Android エミュレータの起動には
  リポジトリルートで `ftester devices up`(または `ftester bridge up`)を先に実行してください。
- 「実行 (dry-run)」はデバイス不要です(`--dry-run --profile` はワーカー構築自体を省略し、
  プロファイルの解決検証と `heal`/`reportDir`/`defaultTimeout` の反映だけ行います)。
- シナリオの `platform`(`@TestClass` の指定)に対応するデバイスがプロファイルに無い場合、
  そのシナリオは「担当ワーカーがありません」という理由で失敗として扱われます
  (他のシナリオの実行は継続されます)。
- プロファイルの詳細(`apps/`/`machines`/`runs/` の構成)はリポジトリルートの `README.md` を
  参照してください。

## 実行プロファイルの編集支援

`Projects/<project>/profiles/{apps,machines,runs}/*.json` の作成・編集を助ける機能です。
プロファイルの構造の正は `Sources/FTCore/RunProfile.swift`(`AppProfile`/`MachineProfile`/
`RunProfileDocument`/`DeviceSpec` 等)です。

### プロファイル選択(`ftester.selectProfile`)

コマンドパレットから **「ftester: 実行プロファイルを選択」** を実行すると、対象プロジェクトの
`profiles/runs/*.json` の名前一覧(先頭に「(プロファイルなし)」)が QuickPick で表示されます。
現在の `ftester.profile` 設定値には `$(check)` アイコンと「現在の設定」という説明が付きます。
選択すると `ftester.profile`(ワークスペース設定)が更新され(「(プロファイルなし)」を選ぶと
空文字列になる)、完了を通知するメッセージが表示されます。

### プロファイル検証 → 問題パネル(Diagnostics)

CLI `ftester api validate-profile --project <p> [--kind apps|machines|runs] [--name <n>]`
(`Sources/ftester/ApiValidateProfileCommand.swift`)の結果を、問題パネル(Problems)の
`ftester-profile` という DiagnosticCollection に反映します(`src/profileDiagnostics.ts`。
JSON→Diagnostic への変換ロジック自体は vscode 非依存の `src/profileModel.ts` に切り出してあります)。
検証エラー(`errors`)は Error、未知キー等の警告(`warnings`)は Warning として表示されます
(位置情報は無いため、いずれも対象ファイルの先頭行に付きます)。

- **保存時の自動検証**: `Projects/<project>/profiles/{apps,machines,runs}/*.json` を保存すると、
  そのファイル1件だけを `--kind`/`--name` で絞り込んで検証し、該当ファイルの診断を更新します
  (エラー・警告が無くなれば問題パネルからも消えます)。
- **コマンド「ftester: プロファイルを検証」**(`ftester.validateProfiles`): 対象プロジェクトの
  全プロファイルファイルを一括検証して問題パネルを丸ごと入れ替え、
  「エラー N件・警告 N件・問題なし N件」を通知します。

### JSON スキーマ(補完・ホバー・構文レベルの検証)

`package.json` の `contributes.jsonValidation` により、`profiles/{apps,machines,runs}/*.json` を
開くと `schemas/*.schema.json`(`app-profile.schema.json`/`machine-profile.schema.json`/
`run-profile.schema.json`)が自動的に適用され、VS Code 標準の JSON 言語機能(補完・ホバー・
必須キー/型不一致の構文レベルの警告)が効くようになります。

- 未知のキーは(タイポ検出目的の)エラーにはしません(`additionalProperties: true`)。
  未知キーの検出は上記の CLI 検証(問題パネル)側の役割です(二重報告を避けるため)。
- `runs/*.json` は `app`(文字列)と `devices`(1件以上。各要素は `{"name": "..."}` 形式。
  文字列だけの指定は不可)を必須とします。これは `ProfileResolver.validate` がエラーとして
  扱う項目と一致させています。

## デバイスモニター

コマンドパレットから **「ftester: デバイスモニターを表示」**(`ftester.showDeviceMonitor`)を
実行すると、エディタの横(`ViewColumn.Beside`)に Webview パネルが開きます。既に開いている
場合は既存のパネルを前面に出すだけです(1ワークスペースにつき1枚のシングルトン)。

- パネルを開くと `ftester api monitor --project <project> --interval <秒> --max-width 480` を
  裏で起動し、その NDJSON 出力(デバイス一覧・各デバイスの画面(JPEG)・エラー)をタイル表示に
  反映します。**各デバイスの画面は既定でヘッドレス映像ストリーミング**(`ftester-simstream`(iOS)/
  `ftester-androidstream`(Android)が変化駆動で JPEG フレームを配信)で、SCK(ScreenCaptureKit)を
  使わずシミュレータ/エミュレータの画面をほぼリアルタイムに更新します。デバイス一覧・状態の取得は
  引き続き `ftester api monitor` のポーリング(`ftester.monitorInterval` 秒間隔、既定2秒・最小0.5秒)に
  よります。**パネルの設定タブのトグル、または `ftester.iosStreamEnabled`/`ftester.androidStreamEnabled`
  を無効にするとポーリング方式**(`ftester.monitorInterval` 秒間隔で画面の静止画を取得)に切り替わります。
  ヘルパー未ビルド(iOS)・adb 未検出(Android)時は自動でポーリングにフォールバックします。
- 各タイルには、デバイス名・プラットフォームバッジ(iOS/Android)・状態バッジ・最新の画面
  (フレーム未受信時はプレースホルダー枠。文言はデバイス状態に応じて「未起動」/「起動中」)・
  最終更新時刻が表示されます。状態バッジの意味:
  - **接続済み**(緑): ブリッジ接続済みで画面取得・操作が可能な状態
  - **起動中**(黄): デバイス自体は起動しているがブリッジがまだ接続されていない状態
  - **未起動**(灰): デバイスが起動していない状態(画面は表示されずプレースホルダー枠になります)
- **タイルの右クリックメニューによる個別起動/停止**: 各タイルを右クリックすると、その場に
  1項目だけのコンテキストメニュー(webview 内の自作メニュー。VS Code の Webview は OS の
  ネイティブメニューを表示できないため)が開きます。「未起動」のタイルには**「起動」**
  (`ftester api device-up --name <論理名>`。iOS はブリッジ供給も行います)、「接続済み」
  「起動中」のタイルには**「停止」**(`ftester api device-down --name <論理名>`)
  が表示されます。メニュー外クリック・Esc・スクロールで閉じます。右クリックしてもタイル自体の
  選択(レーン絞り込み)には影響しません。実行中はそのデバイスのタイル画像左上に
  「起動中...」/「停止中...」の小さなバッジが表示され、メニューの項目も同じ文言で無効化されます。
  完了するとモニターの次回ポーリングで状態バッジが自動的に更新されます。失敗した場合
  (`finished` イベントが `ok:false`、またはプロセスの異常終了)は、パネル上部のエラーバナーに
  デバイス名とエラー内容が表示され、出力パネル「ftester」にも
  `[ftester] device-up(<デバイス名>)が失敗しました: <エラー内容>` の形式で必ず記録されます。
  ログ(`log` イベント)も出力パネル「ftester」に出力されます。
- **デバイス操作は1件ずつ順番に実行されます**: 「デバイスを全て起動/終了」とタイル個別の
  起動/停止は、内部で単一の直列キューを共有しており、常に1件ずつ実行されます(ブリッジ供給・
  simctl・adb が競合しないようにするためで、並行実行するとブリッジの起動待ち
  (`waitUntilReady`)が失敗しやすくなります)。複数のタイルを立て続けに右クリックして起動/停止を
  指示した場合や、個別操作の実行中に「デバイスを全て起動/終了」を押した場合も、指示した順番で
  1件ずつ処理されます。自分の番が来ていないタイルは画像左上に**「待機中...」**バッジが表示され、
  右クリックメニューの項目も同じ文言で無効化されます。キューに何か(実行中含む)積まれている間は
  上部ツールバーの「デバイスを全て起動」「全て終了」ボタンも無効化されます。
- **「全て終了」「停止」実行中はモニターのポーリングを一時停止します**: `ftester api monitor`
  は独立にデバイスを定期ポーリングしているため、そのままだと「全て終了」やタイル右クリックの
  「停止」で片付け中のデバイスへスクリーンショット取得に行ってしまい、接続失敗の警告が数サイクル分
  出ることがあります。これを避けるため、down 系の操作(bulk down / device-down)の実行直前に
  拡張側からモニタープロセスへ一時停止を指示し、操作の完了後(成功・失敗を問わず)に再開を
  指示します。再開時はモニター側の状態判定の記憶もクリアされるため、再開直後の1回で
  すぐに「未起動」へ反映されます(up 系の起動操作では一時停止しません。起動の進行状況を
  タイルで見られるようにするためです)。
- 上部ツールバーのボタン:
  - **「デバイスを全て起動」**: `ftester devices up` を実行します(マシンプロファイルに定義された
    デバイスを段階的に起動)。
  - **「全て終了」**: `ftester devices down` を実行します(ブリッジ停止+シミュレータ/エミュレータ
    の全終了)。
  - **「モニター再起動」**: `ftester api monitor` プロセスを再起動します(設定変更後や、
    モニタープロセスが異常終了した場合の再接続に使用します)。
  - 起動/終了の実行中(タイル個別操作を含む直列キューが空でない間)は多重起動を防ぐため両ボタンが
    無効化されます(キューが空になると自動的に再度有効になります)。
- `ftester api monitor` プロセスが異常終了した場合(マシンプロファイル未設定等)は、パネル上部に
  エラーバナーで案内が表示されます。`ftester machine set` の実行や
  `Projects/<project>/profiles/machines/` の内容を確認してください。
- CLI 呼び出しの stdout/stderr の詳細ログは出力パネル「ftester」に出力されます。

## 並列実行とログレーン

`ftester.profile` を設定した状態で「実行」「実行 (dry-run)」を行うと(dry-run 以外は対象
デバイスが起動済みである必要があります。詳細は上記「実行プロファイル」参照)、CLI 側
(`ftester api run --profile <name>`)が並列実行になり、プロファイルに定義された各デバイス
(ワーカー)が同時にシナリオを実行します。デバイスモニターパネルを開いていると、下部に
ワーカー別の**ログレーン**が表示されます。

- 実行イベントは `src/runEventBus.ts`(拡張内の小さな pub/sub)経由で Test Explorer への反映
  (`src/runHandler.ts` / `src/runReducer.ts`)とログレーン表示(`src/monitorPanel.ts` /
  `src/runLaneModel.ts`)の両方へ同時に配信されます。Test Explorer の出力パネルにも、並列実行時は
  各行の先頭に `[デバイス名]` のプレフィックスが付きます。
- ログレーンはデバイスモニターパネル下部に、実行が始まると表示されます。**タイルを何も
  選択していない状態では全ワーカーのレーンが横並びで表示されます。** デバイスタイルを
  クリックすると、そのタイルが枠線でハイライトされ、選択したデバイスのレーンだけに
  絞り込まれます(複数選択可。もう一度クリックすると選択解除、タイルが無い空きエリアを
  クリックすると全解除)。レーンセクションのヘッダーに「選択中N台を表示」「全ワーカー」の
  どちらの状態かが表示されます。
- 各レーンの本文には、そのワーカーが担当したシナリオ/シーン/ステップが
  `▶`/`✅`/`❌`/`⚠️`/`🔧`/`💡` 等のアイコン付きで逐次追加されます(Test Explorer の出力と
  同じアイコン)。レーンは最下部に自動スクロールしますが、ユーザーが手動で上へスクロール
  している間は自動追従を止めます(下端に戻すと自動追従が再開します)。各レーンは最大500行
  保持し、超えた分は古い行から破棄されます。
- 並列実行中は、実行中のワーカーに対応するデバイスタイルに「実行中」バッジが表示されます
  (そのワーカーの `scenarioStarted`〜`scenarioFinished` の間)。
- 逐次実行(`ftester.profile` 未設定、または dry-run/デバッグ実行)では worker 情報を伴わない
  ため、「全体」という1本のレーンにまとめて表示されます。

## 自己修復(heal)と修復候補の確定

macOS GUI 版(`ftester-gui`)の「自己修復トグル + 修復候補の確認シート」に相当する機能です。

### 設定と実行

- `ftester.heal` を `true` にすると、Test Explorer の**「実行」**(dry-run を除く)と
  **「デバッグ」**の CLI 呼び出しに `--heal` が付与され、FM によるロケータ自己修復が有効になります。
  **「実行 (dry-run)」**には付与されません(dry-run はデバイス不要の検証実行で、自己修復の対象になる
  実機動作が発生しないため)。
- `ftester.profile` を使ったプロファイル実行では、プロファイル(`profiles/runs/<name>.json`)側にも
  `heal` を設定できます。`ftester.heal` が `true` のときだけプロファイル側の設定より優先されます
  (`ftester.heal` が `false`(既定)のときは何も付与せず、プロファイル側の `heal` 設定がそのまま
  使われます)。
- 確認パネルは `ftester.heal` 設定に関わらず、実行中に `fixSuggestion` イベントが1件以上届けば
  自動的に開きます(プロファイル側の `heal` 設定だけが有効な場合でも確認できるようにするため)。

### 確認パネル

実行が終了すると(dry-run では発生しません)、修復候補があれば **「ftester 自己修復の確認」**
Webview パネルが自動的に開きます。各候補について以下を確認・編集できます。

- チェックボックス(既定 ON。ただしソースが変更されていて適用できない候補は既定 OFF・操作不可)
- シナリオ ID・`file:line`
- 「変更前」セレクタ(読み取り専用)
- 「変更後」セレクタ(テキスト入力で編集可。空・`"` を含む・改行を含む場合は警告してチェックが
  強制的に外れます)
- 「説明」(対象行の行末 `//` コメントをプリフィル。改行を含む場合のみ警告してチェックが外れます。
  空にするとコメント削除の指示になります)
- diff プレビュー(拡張がパネルを開く時点でソース行を1回読み、`-` 変更前行(赤)/`+` 変更後行
  (緑)を表示します。変更後行はセレクタ・説明の編集にライブ追従します)
- 対象行に変更前セレクタが引用符付きでちょうど1回出現しない場合は
  **「適用できません(ソースが変更されています)」**と表示され、チェックは無効化されます

「選択した N 件を適用」を押すと、拡張が `ftester api apply-heal --project <project>` を
stdin 経由の JSON(`{"fixes":[...]}`)で呼び出し、シナリオソースへ確定反映します。適用に成功した
候補はパネルから消え、失敗した候補は理由とともに残ります。**失敗が0件になったときだけ**パネルが
自動的に閉じます。「閉じる」を押すと何も反映せずパネルを閉じます(ヒールキャッシュはそのまま
残るため、次回 `--heal` 付きで実行すると同じ候補が再度提案されます)。

適用後のシナリオツリー再読込は `watcher`(ファイル変更検知)が拾うため、拡張側で明示的な
リフレッシュは行いません。

### GUI 版との差分

- GUI 版は説明の初期提案に FM(自然言語生成)を使いますが、拡張ホストからは FM を呼び出せないため、
  VSCode 版の説明欄は既存の行末コメントのみをプリフィルします(コメントが無い行は空欄から編集を
  始めます)。
- パネルを開いた状態でさらに `--heal` 付き実行を行った場合、GUI 版と異なりパネルは閉じずに
  新しい候補(重複しない ID のみ)を追記します。

## ライブ操作

デバイスモニターパネル(`src/monitorPanel.ts`)の「ライブ操作」タブ(`src/monitorLiveController.ts` +
webview 資産 `src/webview/monitor/liveTab.js`)。macOS GUI 版(`ftester-gui`)の「ライブ操作」タブ
(`Sources/ftester-gui/LiveView.swift` + `AppModel.swift` の `refreshLive`/`liveAction`)に相当する
機能です。コマンドパレットから **「ftester: ライブ操作を表示」**(`ftester.showLiveControl`)を
実行するか、デバイスモニタータブでタイルを右クリックして**「ライブ操作」**を選ぶと、パネルが開き
(既に開いている場合は前面に出るだけ。デバイスモニターと同じシングルトン)「ライブ操作」タブへ
切り替わります(タイル右クリック経由はさらにそのデバイスを選択し、接続済みなら画面も取得します)。

- **上部のデバイスセレクタ**: タブを初めて表示すると `ftester api list-devices --project <project>`
  を実行し、マシンプロファイルの全デバイスと現在状態(接続済み/起動中/未起動)を取得してプルダウンに
  表示します。**「デバイス一覧を更新」**ボタンで再取得できます。`connected` 以外のデバイスも選択
  自体はできますが、選択中に「⚠ 接続されていません」という注意表示が出ます。`list-devices` が
  失敗した場合(マシンプロファイル未設定、対象プロジェクト未解決等)は、`ftester.platform`/
  `ftester.port`/`ftester.serial` 設定から作った「設定のデバイス」1件にフォールバックし、上部に
  エラーバナーで理由を表示します。デバイスを選択すると、そのデバイス向けの `ftester api live serve`
  常駐プロセスが起動し、画面の供給元(ストリーミング/自動フレーム)も切り替わります(詳細は下記
  「常駐プロセス」「画面の自動更新」)。
- **画面の自動更新(ストリーミング/自動フレーム)**: 選択デバイスの画面は既定でヘッドレス映像
  ストリーミング(iOS: `ftester-simstream` / Android: `ftester-androidstream`。デバイスモニターと
  共通の仕組み。詳細は上記「デバイスモニター」)により自動更新されます。ストリーミング条件(ライブ
  タブ表示中・`ftester.iosStreamEnabled`/`ftester.androidStreamEnabled` が有効・helper が解決できる・
  設定タブの「ポーリングモードを使用する」が OFF)を満たさない場合、または helper が継続不能になった
  場合は、`api live serve` へ `{"cmd":"frame"}` を `ftester.liveFps`(既定12)fps を上限に送り続ける
  自動フレーム(画像のみ)にフォールバックします。いずれの経路でも要素一覧・タップ座標変換に必要な
  `screen`/`elements` は含まれないため、**「更新」ボタン**でフルの snapshot(`{"cmd":"refresh"}`)を
  取り直す必要があります(タブを初めて表示したときは自動的に1回だけ実行されます)。
- **左: スクリーンショット**: 画像をクリックするとその位置をタップし(`{"cmd":"tap","x":..,"y":..}`)、
  ドラッグするとその軌跡でスワイプし(`{"cmd":"drag",...}`。方向は始点終点の差分から自動判定)、
  ほぼ動かさず500ms以上長押ししてから離すと長押しを送ります(`{"cmd":"press","x":..,"y":..,
  "duration":..}`)。クリック位置→デバイス座標の変換は下記「座標変換について」参照。画像直下に
  **「ホーム」**(`{"cmd":"home"}`)・**「タスク切替」**(`{"cmd":"appSwitcher"}`)ボタンがあります。
  未取得時はプレースホルダーが表示されます。
- **右: 操作パネル**: **「更新」**ボタン(snapshot 再取得)・**テキスト入力欄 + 「入力」**
  (`{"cmd":"type","text":..,"ref":..}`。要素一覧でタップした要素があれば `ref` を付けて送信し、
  未選択、または snapshot を再取得すると選択状態はクリアされてフォーカス中の要素に入力されます)・
  **要素一覧**(`[ref] type「label」id=identifier =value` 形式。空フィールドは省く。**クリックで
  その要素をタップ**(`{"cmd":"tap","ref":..}`)、行にマウスを乗せると画像上に該当要素の `frame` を
  枠オーバーレイ表示)。要素一覧の下には後述の**「操作記録」**欄が並び、間のスプリッタをドラッグして
  両者の高さ配分を調整できます(配分は `vscode.setState` に保存されます)。
- **操作記録**: ライブ操作で実行した操作(タップ/スワイプ/長押し/入力/ホーム/タスク切替)を時刻付きで
  1 行ずつ追記する表示専用のログです(**下記「レコーディングとシナリオ生成」とは別機能**で、シナリオ
  生成には一切関与しません)。各行は「時刻 + 短いラベル」(タップ対象は label > `#id` > type の順、
  要素外のタップ/長押しは座標、入力は先頭20字)で、失敗した操作は `✗` を付けて強調します。最大 200 行
  (超えたら古い行から破棄)で最新行が見えるよう自動スクロールし、**「クリア」**ボタンで消去できます。
- **アプリプロファイル・レコーディング**: 上部の「アプリプロファイル」セレクタ・
  **「レコーディング開始」/「レコーディング終了」**ボタン(画像を右クリックした同じ操作のメニューからも
  実行可)で操作を録画できます。録画開始時は対象アプリを常に再インストールしてから起動します
  (アプリプロファイルに appPath がある場合。以前の「自動インストール」チェックボックスは廃止)。
  詳細は下記「レコーディングとシナリオ生成」。
- **エラー表示欄**: 直近の失敗(`actionResult` の `ok:false`、または snapshot 取得失敗)のエラー
  メッセージを表示します。
- **操作後の反映**: タップ/ドラッグ/長押し/入力/ホーム/タスク切替が成功すると、serve が操作直後に
  返す観測イベント(snapshot)をそのまま画面へ反映します(ブリッジの操作応答時点で UI が整定済みの
  ため追加待ちは不要)。失敗時は画面を再取得せず、エラー表示欄にエラーを出すだけです。操作中は全ての
  操作ボタン・デバイスセレクタが無効化され、「処理中...」と表示されます。

### レコーディングとシナリオ生成

操作を記録して Swift シナリオを自動生成する機能です(`src/monitorLiveController.ts` の
startRecord/stopRecord/generateScenario、`src/liveModel.ts` の `RecordedStep`/`locatorChainForElement`、
Swift 側 `ftester api gen-scenario`(`Sources/ftester/ApiGenScenarioCommand.swift`))。

- **開始**: アプリプロファイルを選び「レコーディング開始」を押すと、「自動インストール」が ON かつ
  プロファイルにアプリパスがあれば `{"cmd":"install"}` → `{"cmd":"launch"}` を実行し(install 直後の
  観測失敗は無視する)、OFF なら `launch` のみ実行します。起動に失敗すると録画は開始されません。
- **記録中**: 以降のタップ/長押し/ドラッグ(スワイプ)/テキスト入力/ホーム/タスク切替の操作が成功
  するたびに `RecordedStep` として記録されます。ロケータは identifier > label > (同 type 内の)
  index の優先度で組み立て(`locatorChainForElement`)、タップ/長押しは当たった要素が無ければ記録
  しません(操作自体は実行されます)。ドラッグ・入力・ホーム・タスク切替はロケータ不要のため常に
  記録されます。
- **終了**: 「レコーディング終了」を押すと記録済みステップを一時 JSON(`os.tmpdir()`)に書き出し、
  `ftester api gen-scenario --project <project> --steps <path>`(FtesterCli の直列キュー経由。生成
  コードのビルド検証(`swift build`)を伴うため `api run`/`api explore` と同じキューに乗せる)を
  実行してテストコードを生成します。成功すると生成ファイルを自動的に開きシナリオツリーを更新します。
  失敗時(ビルド検証失敗を含む)はエラーメッセージがレコーディング状態欄に表示されるだけで、ファイル
  は開きません。一時 JSON は完了後にベストエフォートで削除されます。操作を1件も記録しないまま終了
  すると、CLI を呼ばずに「操作が記録されていません」と表示します。

### 常駐プロセス(`api live serve`)について

選択デバイスごとに `ftester api live serve` を常駐 spawn します。ドライバは serve プロセス起動時に
1回だけ生成され、以降の全操作で使い回されます。

- コマンドは stdin へ NDJSON で1行ずつ送ります: `{"cmd":"tap","ref":<Int>}` /
  `{"cmd":"tap","x":..,"y":..}` / `{"cmd":"type","text":..,"ref":..|null}` /
  `{"cmd":"drag","fromX":..,"fromY":..,"toX":..,"toY":..,"press":..,"duration":..}` /
  `{"cmd":"press","x":..,"y":..,"duration":..}` / `{"cmd":"launch","bundle":..}` /
  `{"cmd":"install","path":..}` / `{"cmd":"home"}` / `{"cmd":"appSwitcher"}` / `{"cmd":"refresh"}`
  (観測のみ。screen+要素一覧付きの snapshot) / `{"cmd":"frame"}`(観測のみ。画像のみ)。
  `{"cmd":"terminate"}` もプロトコル上定義されていますが、この UI からは現状呼ばれていません。
- 応答は stdout から NDJSON で届きます。`refresh`/`frame` 以外はまず
  `{"kind":"actionResult","ok":true|false,"error":..|null}` を出し、続けて(操作の成否を問わず)
  観測イベントを出します: `refresh` を含む操作系は `{"kind":"snapshot","ok":true,"platform":..,
  "screen":..,"image":..,"elements":..}`(失敗時は `{"kind":"snapshot","ok":false,"error":..}`)、
  `frame` は `{"kind":"frame","ok":true,"image":..}` です。拡張側は `actionResult` が `ok:false` の
  とき、続く観測イベントは画面へ反映しません(直前の表示を保持したままエラーを表示する)。
- プロセス管理は `src/monitorPanel.ts` の host-metrics プロセス管理パターンを踏襲しています: stdin
  パイプ保持(EOF が終了指示)・SIGTERM 送信後2秒で SIGKILL・予期しない終了は5秒後に自動再起動・
  起動10秒未満の異常終了が3連続したら諦めます。応答タイムアウト(20秒)時は wedge した serve を
  kill→respawn し、これが3連続したら諦めて「常駐プロセスが起動していません」を表示します。
  host-metrics と違い serve はデバイスごとの状態を持つプロセスなので、デバイス選択が変わるたびに
  明示的に再バインド(停止→新デバイスで起動)し、その際は諦め状態もリセットします。専用の「再起動」
  ボタンは無く、デバイスを選び直す(または一覧を再取得する)操作そのものが復帰の手段になります。

### 座標変換について

`api live serve` の観測イベント(snapshot)の `screen`(デバイス全体のサイズ)と各要素の `frame` は
いずれも**ポイント座標**です。スクリーンショット画像は screen のアスペクト比のままレターボックス無く
表示される前提で、画像の表示px位置からポイント座標への変換は
`click / 表示px × screen`(GUI 版 `ScreenshotView` の `SpatialTapGesture` と同じ比例変換)で行い、
結果は screen の範囲にクランプします。この変換とその逆変換(要素の `frame` → 表示px。ホバー枠の
オーバーレイ表示に使用)は `src/liveModel.ts`(vscode 非依存)の `pointFromClick`/
`frameToDisplayRect` に実装されており、`test/liveModel.test.mjs` で単体テストしています。
クリック位置→タップ座標への変換自体は拡張ホスト側(`src/monitorLiveController.ts`)で行い、webview は
クリック位置(画像内の表示px)と表示サイズだけを postMessage で送ります。ホバー時の枠オーバーレイは
即応性のため webview 内で完結させる必要があり、CSP により `liveModel.ts` を import できないため、
`frameToDisplayRect` と同じ小さな計算式だけを webview 内の素の JS(`src/webview/monitor/liveTab.js`)に
複製しています(`healReviewPanel.ts` が `healModel.ts` の一部ロジックを複製しているのと同じ方針)。

### CLI 呼び出しについて(FtesterCli のキューを使わない理由)

`ftester api list-devices`/`ftester api live serve` は、Test Explorer の「実行」等が使う
`src/cli.ts`(`FtesterCli`)の直列実行キューには乗せず、`src/monitorLiveController.ts` が専用に
spawn します(`list-devices` は `src/oneShotCli.ts` の `runOneShot`、`live serve` は個別の常駐
spawn)。`FtesterCli` のキューは `ftester api run`(シナリオ実行。内部で `swift build` を伴い得るため、
SPM のビルドロック対策として同時に2プロセス走らせない設計)と共有されているため、もしライブ操作も
同じキューに乗せると、実行中(数分かかることもある)はライブ操作タブの全ての操作がその実行完了まで
待たされて固まってしまいます。ライブ操作は「今の画面を見ながらすぐ触る」ためのものなのでこれは
受け入れられません。一方 `api live serve`/`api list-devices` はいずれもドライバ直叩きの操作で
`swift build` を一切行わないため、専用 spawn にしても実行中の `swift build` と競合する心配は
ありません(`src/monitorPanel.ts` が `devicesUp`/`devicesDown`/host-metrics を専用 spawn している
のと同じ方針)。例外として `ftester api gen-scenario`(レコーディング終了時の生成)は `api explore`
と同様に生成コードのビルド検証(`swift build`)を伴うため、あえて `FtesterCli` の直列キュー経由で
実行します(詳細は上記「レコーディングとシナリオ生成」)。

## FM探索

macOS GUI 版(`ftester-gui`)の「FM探索」タブに相当する機能です。コマンドパレットから
**「ftester: FM探索でシナリオを生成」**(`ftester.explore`)を実行すると、FM エージェントが
実機/シミュレータ上でアプリを自律的に操作しながらテストの目標を達成しようとし、その過程を
Swift シナリオとして生成します(`ftester api explore`)。

### 手順

1. **デバイス選択**(QuickPick): `ftester api list-devices --project <project>` の結果を
   `src/liveModel.ts` の既存ヘルパー(`devicesToOptions`/`buildDeviceArgs`)で変換した一覧から、
   探索対象のデバイスを選びます。`connected`(接続済み)以外のデバイスは選択肢の詳細に
   「⚠ 接続されていません。探索が失敗する可能性があります。」という注意書きが表示されますが、
   選択自体は可能です。
2. **bundle ID / パッケージ名の入力**(InputBox): 前回入力した値が `workspaceState` に記憶され、
   次回はプリフィルされます。
3. **テストの目標の入力**(InputBox): 自然言語でテストしたい内容を記述します
   (例:「ログインしてホーム画面が表示されることを確認する」)。
4. **最大ステップ数の入力**(InputBox): 既定値25。1〜50の整数のみ受け付けます(範囲外・非整数は
   入力欄にエラーが表示され確定できません)。

いずれかの入力を Esc でキャンセルすると、それ以降の手順に進まずに終了します。

### 実行と進捗表示

`ftester api explore --project <p> --bundle <id> --goal <文> --max-steps <N> --platform <p>
[--port <n>|--serial <s>]` を **`src/cli.ts` の `FtesterCli`(直列実行キュー)経由**で実行します。
`api explore` は生成した Swift コードのビルド検証(`swift build`)を内部で行うため、ライブ操作
(`src/monitorLiveController.ts` の list-devices/live serve)やデバイスモニターの devices up/down
のような専用 spawn ではなく、
`ftester api run` 等と同じキューに乗せることで SPM のビルドロック競合を避けます
(キューは同時に1プロセスしか実行しない設計。詳細は `src/cli.ts` 冒頭のコメント参照)。

実行中は `vscode.window.withProgress`(通知領域・キャンセル可能)で進捗を表示し、
`exploreStep` イベントを受信するたびに「`[n/N] <ステップの説明>`」へ更新します
(1ステップに数十秒かかることがあります)。通知の「キャンセル」を押すと実行中の CLI プロセスに
SIGTERM を送ります(2秒後も終了しなければ SIGKILL。`FtesterCli.cancelCurrent()` と同じ挙動)。
受信した全イベント(および stderr)は出力パネル「ftester」にも逐次出力されます。

### 完了時の通知

`exploreFinished` イベントの内容に応じて、以下のいずれかの通知が表示されます
(いずれも生成されたファイルがあれば「ファイルを開く」ボタン付き。押すとエディタで開きます)。
シナリオツリーは `watcher`(ファイル変更検知)が拾うため、拡張側でも念のため明示的に再読込します。

- **完了**(`outcome: "completed"`、`quarantined: false`): 情報メッセージ
  「探索完了(N ステップ)」
- **未完了だがシナリオは生成**(`outcome: "gaveUp"` または `"stepLimitReached"`、
  `quarantined: false`): 警告メッセージ「探索は未完了ですがシナリオを生成しました
  (TODOコメント付き)。」
- **ビルド検証失敗による隔離**(`quarantined: true`。`outcome` に関わらず優先表示):
  警告メッセージ「ビルド検証に失敗したため `_disabled/` に隔離されました。」
  (`Scenarios/_disabled/` に生成される。`file` は隔離先パス)

FM 利用不可・ドライバ接続不可等の致命的な失敗(`error` イベント、exit code 1)の場合は
エラーメッセージが表示されます。

## 手動確認チェックリスト

F5 で Extension Development Host を起動した状態(またはパッケージ版をインストールした状態)で、
以下を一通り確認します。

### ツリー表示

1. サイドバーの「テスト」(Testing)ビューを開く。`ftester` というテストコントローラーの下に、
   `Projects/<project>/Scenarios/` の構成に対応した folder → class → メソッドの3階層ツリーが
   表示されることを確認する(`ftester.project` が未設定で `Projects/` 直下に複数プロジェクトが
   ある場合は警告通知が出るので、「プロジェクトを選択」から対象を選ぶか、`ftester.project`
   設定を明示的に指定する)。表示されない場合はコマンドパレットから
   **「ftester: シナリオを再読込」**(`ftester.refreshScenarios`)を実行するか、
   テストビューの再読込ボタンを押す。
2. `@Deleted` が付いたシナリオ(削除予定としてマークされたメソッド)がツリー上で
   `(削除済み)` という説明付きで表示されることを確認する。
3. `Projects/<project>/Scenarios/` 配下の `.swift` ファイルを編集・保存する(シナリオ名や
   メソッドを追加/変更するなど)。800ms 程度のデバウンス後にツリーが自動的に再読込される
   ことを確認する。
4. 出力パネルのドロップダウンから **「ftester」** チャンネルを選ぶと、CLI 呼び出しの
   stderr ログやエラー診断が確認できる。
5. バイナリが見つからない状態(例えば `ftester.binaryPath` を存在しないパスに変更する)で
   再読込すると、`swift build --product ftester` を促す警告通知が表示されることを確認する。

### Run 実行(`ftester.profile` 未設定 = platform/port/serial 直接指定)

6. テストビューでシナリオ(または class/folder/全体)を選び、「実行」ボタン横の
   ドロップダウン(またはプロファイル選択)から **「実行 (dry-run)」** を選んで実行する
   (デバイス不要)。
   - 対象シナリオが「実行中」→「成功」になり、実行時間が表示されることを確認する。
   - テスト結果パネルの出力(Output)に、シナリオ/シーン/各ステップが
     `▶`/`✅` 等のアイコン付きで逐次表示されることを確認する。
   - 実行中は `Projects/*/Scenarios/**/*.swift` を編集してもツリーが再読込されず
     (watcher が suspend される)、実行完了後に保留していた変更が反映される
     (再読込される)ことを確認する。
   - 実行中に停止(■)ボタンでキャンセルすると、CLI プロセスが終了し
     (出力パネルでプロセス終了を確認できる)、対象シナリオが完了扱いのまま
     残らないことを確認する。
7. 意図的に失敗するシナリオ(または既存シナリオを一時的に壊したもの)を「実行」すると、
   対象シナリオが「失敗」になり、失敗ステップの TestMessage(説明+失敗理由)が
   テスト結果ペインに表示され、クリックすると該当ソース行にジャンプできることを確認する。
8. `(削除済み)` 表示のシナリオを直接選択して実行すると(クラス/folder/全体実行では
   自動的に除外されることも合わせて確認する)、実行できることを確認する
   (CLI の「完全一致指定のときだけ削除済みを実行する」規則)。

### デバッグ実行

9. 以下の手順でブレークポイント・ステップ実行・続行・停止を一通り確認する。
   1. `Projects/<project>/Scenarios/` 配下の `.swift` ファイルをエディタで開き、
      `action { }` 内のコマンド呼び出し行(例: `tap(...)`)の行番号ガター(行番号の左側)を
      クリックしてブレークポイント(赤丸)を設定する。
   2. テストビューで対象シナリオを選び、「実行」ボタン横のドロップダウンから
      **「デバッグ」** を選ぶ(または該当シナリオにカーソルを置いて **F5**)。
   3. 設定したブレークポイントの行でエディタの該当行がハイライトされ、
      実行が一時停止することを確認する(デバッグツールバーが表示される)。
   4. デバッグツールバーの「ステップオーバー」でシナリオが1ステップずつ進み、
      停止行のハイライトが次のコマンド呼び出し行へ移ることを確認する。
   5. 「続行」で次のブレークポイント(無ければ最後)まで進むことを確認する。
   6. 「停止」(切断/終了)で実行が中断され、対象シナリオがテスト結果パネルで
      「失敗」(または「エラー」)として反映されることを確認する。
   7. ブレークポイントを設定せずに「デバッグ」を実行すると、途中で止まらずに
      最後まで実行され、成功/失敗がテスト結果パネルに正しく反映されることを確認する。
   8. デバッグ実行中は `Projects/*/Scenarios/**/*.swift` を編集してもツリーが
      再読込されない(watcher が suspend される)ことを確認する。
   9. 出力パネル「ftester」またはデバッグコンソールに、シナリオ/シーン/各ステップの
      ログ(`▶`/`✅` 等のアイコン付き)が逐次表示されることを確認する。

### 実行プロファイル(`ftester.profile`)

10. `.vscode/settings.json` に `"ftester.profile": "<Projects/<project>/profiles/runs/ にある名前>"`
    を設定し、「実行 (dry-run)」を実行する。出力パネルに `--profile` 経由で実行されている旨の
    ログ(プロファイル解決やワーカー構築のログは出さず NullDriver で流れる)が出て、
    dry-run 同様に成功することを確認する(デバイス不要)。
11. iOS シミュレータ・Android エミュレータを `ftester devices up` 等で起動した状態で、
    `ftester.profile` を設定したまま(dry-run を外して)「実行」または「デバッグ」を行うと、
    プロファイルに定義されたデバイスへ自動的にアプリがインストールされてシナリオが
    実行されることを確認する。
12. `ftester.profile` に、対象シナリオの `platform` に合うデバイスが定義されていない
    プロファイル名を設定して実行すると、そのシナリオが「担当ワーカーがありません」という
    理由で失敗として扱われることを確認する。

### 実行プロファイルの編集支援

13. コマンドパレットから **「ftester: 実行プロファイルを選択」** を実行すると、対象プロジェクトの
    `profiles/runs/*.json` の名前一覧(先頭に「(プロファイルなし)」)が QuickPick で表示され、
    現在の `ftester.profile` 設定値に `$(check)` アイコンと「現在の設定」という説明が付くことを
    確認する。いずれかを選択すると `ftester.profile` 設定が更新され(「(プロファイルなし)」は
    空文字列になる)、完了を通知するメッセージが表示されることを確認する。
14. `Projects/<project>/profiles/runs/<name>.json` を開き、`"devices"` を削除するなど検証エラーに
    なる編集をして保存すると、数秒以内に問題パネル(Problems)にそのファイルのエラーが表示される
    ことを確認する(該当行はファイル先頭行になる)。エラーを直してから保存し直すと、問題パネルから
    該当エラーが消えることを確認する。
15. コマンドパレットから **「ftester: プロファイルを検証」** を実行すると、対象プロジェクトの
    `profiles/{apps,machines,runs}/*.json` が一括検証され、「エラー N件・警告 N件・問題なし N件」
    という通知が表示されることを確認する(問題パネルにも各ファイルの結果が反映される)。
16. `Projects/<project>/profiles/runs/<name>.json` をエディタで開き、既存キーの外側(オブジェクトの
    トップレベル)で補完(Ctrl+Space / Cmd+Space)を呼び出すと、`app`/`devices`/`heal`/`reportDir`/
    `defaultTimeout` が説明付きで候補に出ることを確認する。`"heal"` に文字列を入力するなど型を
    誤ると、エディタ上に構文レベルの警告(波線)が表示されることも確認する
    (`profiles/apps/*.json`・`profiles/machines/*.json` でも同様にスキーマが効くことを合わせて
    確認する)。

### ステップ一覧

17. `Projects/<project>/Scenarios/` 配下の `.swift` ファイルをエディタで開き、`@Test` メソッド
    (シナリオ)の本体内にカーソルを置く。サイドバーの「テスト」(Testing)ビューに
    `ftester ステップ` というビューが表示され、カーソルが乗っているシナリオの scene グループ
    (`scene N: <シーンタイトル>`)とステップ(`<番号>. <コマンド>`)一覧が表示されることを
    確認する。カーソルを別のシナリオ(または別ファイルのシナリオ)へ移動すると、表示が
    追従して切り替わることを確認する。ビューのタイトル部分にシナリオIDが表示されることも
    合わせて確認する。
18. テストビューで任意のシナリオを右クリックし、コンテキストメニューから
    **「ftester: ステップ一覧を表示」** を実行すると、`ftester ステップ` ビューにそのシナリオの
    ステップ一覧が表示されることを確認する。
19. `ftester ステップ` ビューでステップ1件をクリックすると、対応するソースファイルの該当行に
    ジャンプし、その行が選択状態になることを確認する。
20. `ftester ステップ` ビューでシナリオを表示した状態のまま、対象シナリオのコマンド行
    (コメントや引数)を編集・保存する。800ms 程度のデバウンス後、ビューの内容が自動的に
    再取得されて更新されることを確認する(ツールバーの更新ボタン(`ftester.refreshSteps`)
    でも同様にキャッシュを破棄して再取得できることを確認する)。

### デバイスモニター

21. コマンドパレットから **「ftester: デバイスモニターを表示」** を実行し、エディタの横に
    Webview パネルが開くことを確認する。もう一度実行しても新しいパネルが増えず、既存の
    パネルが前面に出る(reveal される)ことを確認する。
22. デバイスが1台も起動していない状態では、`ftester.monitorInterval` 秒間隔でタイルが
    「未起動」(灰バッジ)として表示され、画面部分がプレースホルダー枠になっていることを
    確認する。
23. **「デバイスを全て起動」** ボタンを押すと、実行中は「デバイスを全て起動」「全て終了」の
    両ボタンが無効化され、出力パネル「ftester」に `ftester devices up` の出力(段階的な
    起動ログ)が流れることを確認する。完了後にボタンが再度有効になることを確認する。
24. デバイスが起動しブリッジ接続まで完了すると、対象タイルが「接続済み」(緑バッジ)に変わり、
    画面が既定のヘッドレス映像ストリーミングでほぼリアルタイムに更新されることを確認する
    (設定タブのトグルでポーリング方式に切り替えると、`ftester.monitorInterval` 秒間隔の静止画
    更新に変わることも確認する)。ブリッジ未接続の間は「起動中」(黄バッジ)になることも
    確認する。
25. **「モニター再起動」** ボタンを押すと、一旦タイルがクリアされ、`ftester api monitor`
    プロセスが再起動されて最新のデバイス一覧が再表示されることを確認する。
26. **「全て終了」** ボタンを押すと `ftester devices down` が実行され、シミュレータ/
    エミュレータが終了して各タイルが「未起動」に戻ることを確認する。
27. `ftester.binaryPath` を不正なパスに変更する、または `.build/debug/ftester` を一時的に
    リネームするなどしてモニタープロセスを異常終了させると、パネル上部にエラーバナー
    (マシンプロファイル未設定等の案内)が表示されることを確認する。

### 並列実行とログレーン

28. `ftester.profile` に複数デバイスを含むプロファイルを設定し、対象デバイスを起動した状態で
    複数シナリオを選択して「実行」する。デバイスモニターパネルを開いていると、下部に
    ワーカー数分のログレーンが横並びで表示され、各レーンにそのワーカーが担当するシナリオの
    進行(`▶`/`✅`/`❌` 等)が逐次追加されていくことを確認する。実行中は対応するデバイスタイルに
    「実行中」バッジが表示され、シナリオ完了後に消えることを確認する。
29. ログレーン表示中にデバイスタイルを1枚クリックすると、そのタイルが枠線でハイライトされ、
    表示されるレーンがそのデバイスのものだけに絞り込まれることを確認する。複数タイルを
    選択すると選択数分のレーンが表示され、ヘッダーの表示が「全ワーカー」から「選択中N台を
    表示」に変わることを確認する。タイルが無い空きエリアをクリックすると選択が全解除され、
    全ワーカー表示に戻ることを確認する。
30. `ftester.profile` を設定せずに(または dry-run で)「実行」すると、ワーカー別ではなく
    「全体」という1本のレーンにまとめて実行ログが表示されることを確認する。

### 自己修復(heal)

31. `.vscode/settings.json` に `"ftester.heal": true` を設定し、ロケータが一致しなくなる
    シナリオ(あらかじめ対象要素のセレクタをソース側だけ変えておく等)を「実行」する。
    実行完了後、**「ftester 自己修復の確認」** パネルが自動的に開くことを確認する
    (「実行 (dry-run)」では `--heal` が付与されずパネルも開かないことを合わせて確認する)。
32. パネル上で「変更後」セレクタと「説明」を編集し、diff プレビュー(`-`/`+` の行)が
    ライブに追従することを確認する。変更後セレクタを空にする・`"` を含める・改行を含めると
    警告が表示されチェックが自動的に外れることを確認する。
33. 1件以上チェックした状態で「選択した N 件を適用」を押すと、対象の `.swift` ファイルの
    該当行のセレクタ(および編集した場合は行末コメント)が書き換わることを確認する。
    適用に成功した候補がパネルから消え、失敗が無ければパネルが自動的に閉じることを確認する。
34. 「閉じる」を押すとソースが変更されずパネルが閉じることを確認する。この状態で再度
    `--heal` 付きで同じシナリオを実行すると、同じ候補が再度提案されることを確認する
    (ヒールキャッシュが残っているため)。

### ライブ操作

35. デバイス(シミュレータ/エミュレータ)を `ftester devices up` 等で起動した状態で、
    コマンドパレットから **「ftester: ライブ操作を表示」** を実行する。デバイスモニターと
    同じ Webview パネルが開き(前面に出る場合を含む)「ライブ操作」タブへ切り替わって、
    上部のデバイスセレクタに起動済みのデバイスが一覧表示されることを確認する(ブリッジ接続済み
    のデバイスは「接続済み」と表示される)。もう一度実行しても新しいパネルが増えず、既存の
    パネルが前面に出ることを確認する。デバイスモニタータブでタイルを右クリックし
    **「ライブ操作」** を選ぶと、同様にライブ操作タブへ切り替わりそのデバイスが選択されることも
    確認する。
36. マシンプロファイルが見つからない状態(`ftester.project` を存在しないプロジェクト名にする等)
    でタブを開くと、上部にエラーバナーが表示され、デバイスセレクタに
    `ftester.platform`/`ftester.port`/`ftester.serial` 設定から作られた「設定のデバイス」が
    1件だけ表示されることを確認する。
37. 接続済みのデバイスを選択すると、「更新」を押さなくても画面がほぼリアルタイムに自動更新
    される(既定のヘッドレス映像ストリーミング)ことを確認する(設定タブの「ポーリングモードを
    使用する」をチェックすると `ftester.liveFps` 間隔のポーリングに切り替わることも確認する)。
    「更新」ボタンを押すと、右側に要素一覧(`[ref] type「label」...` 形式)が表示されることを
    確認する。
38. 表示された画面をクリックすると、その位置がタップされ、直後に画面が自動的に更新される
    ことを確認する(クリック位置と実際にタップされた位置が対応していることを、ボタン等の
    UI要素を狙ってクリックして反応することで確認する)。
39. 要素一覧の行にマウスを乗せると、画面上にその要素の枠がオーバーレイ表示されることを
    確認する。行をクリックするとその要素がタップされ(枠がハイライトされる)、画面が自動的に
    更新されることを確認する。
40. 画面を押したままドラッグして離すとその軌跡でスワイプされ、ほぼ同じ位置で500ms以上長押し
    してから離すと長押し操作になり、それぞれ画面が自動的に更新されることを確認する。画面直下の
    「ホーム」「タスク切替」ボタンを押すと、それぞれホーム画面/アプリスイッチャーに切り替わり、
    画面が自動的に更新されることを確認する。
41. テキスト入力欄にテキストを入力して「入力」を押すと、直前にタップした要素(テキスト
    フィールド等)にテキストが入力されることを確認する。
42. 操作(タップ/ドラッグ/長押し/入力/ホーム/タスク切替)の実行中は、デバイスセレクタと全ての
    操作ボタンが無効化され、「処理中...」と表示されることを確認する。存在しない要素を狙う等、
    意図的に失敗する操作を行うと、エラー表示欄にエラーメッセージが表示され、画面の自動更新は
    行われない(直前の画面のまま)ことを確認する。
43. アプリプロファイルを選択し「レコーディング開始」(画像を右クリックしたメニューの同項目
    でも可)を押すと、必要に応じて対象アプリがインストール・起動され、レコーディング中の表示に
    変わることを確認する。いくつか操作(タップ・入力・スワイプ等)を行った後「レコーディング
    終了」を押すと、テストコードが生成されて自動的にエディタで開かれ、シナリオツリーにも
    反映されることを確認する。操作を1件も行わずに終了すると、「操作が記録されていません」と
    表示されCLIが呼ばれないことを確認する。
44. シナリオを「実行」している最中(実行に数秒以上かかるもの)に、ライブ操作タブで「更新」や
    タップ等の操作を行うと、実行の完了を待たずに応答が返る(FtesterCli のキューに乗らず
    専用 spawn している)ことを確認する。

### デバイスモニター(タイルの個別起動/停止)

45. デバイスモニターパネルで「未起動」(灰バッジ)のタイルを右クリックすると、その場に
    **「起動」** 1項目だけのメニューが開くことを確認する。「接続済み」「起動中」
    のタイルを右クリックすると **「停止」** 1項目だけのメニューが開くことを確認する。右クリック
    してもタイル自体が選択状態(枠線ハイライト・レーン絞り込み)にならないこと、OS/ブラウザの
    既定のコンテキストメニューが出ないことを確認する。メニュー表示中に画面外クリック・Esc・
    タイル一覧やログレーンのスクロールを行うとメニューが閉じることを確認する。また、画面の端
    (右端・下端)に近いタイルを右クリックしてもメニューが画面外にはみ出さないことを確認する。
46. メニューの **「起動」** をクリックすると、そのタイルの画像左上に「起動中...」バッジが表示され、
    同じタイルを再度右クリックするとメニュー項目も「起動中...」で無効化されていることを確認する。
    出力パネル「ftester」に `ftester api device-up` のログが流れることを確認する。完了すると
    モニターの次回ポーリングでタイルの状態バッジが更新され、右クリックメニューが「停止」に
    切り替わることを確認する(他のタイルの操作や「デバイスを全て起動」ボタンには影響しないことも
    合わせて確認する)。
47. メニューの **「停止」** をクリックすると同様に「停止中...」バッジが表示されて項目が無効化され、
    完了後にタイルが「未起動」に戻り、右クリックメニューが「起動」に切り替わることを確認する。
48. マシンプロファイルに存在しない名前のデバイスを対象にする、または起動/停止に失敗する状況を
    作って操作すると(`finished` イベントが `ok:false`)、パネル上部のエラーバナーにデバイス名と
    エラー内容が表示されることを確認する。

### FM探索

49. コマンドパレットから **「ftester: FM探索でシナリオを生成」** を実行すると、
    `ftester api list-devices` の結果から QuickPick でデバイスを選択できることを確認する。
    `connected` 以外のデバイスには「⚠ 接続されていません。探索が失敗する可能性があります。」
    という注意書きが表示されることを確認する。
50. デバイス選択後、bundle ID / パッケージ名(前回入力値がプリフィルされることを2回目以降の
    実行で確認する)・テストの目標(自然言語)・最大ステップ数(既定25。範囲外(0や51)や
    非整数を入力すると確定できずエラーが表示されることを確認する)の順に入力できることを
    確認する。いずれかの入力を Esc でキャンセルすると、それ以降に進まず何も実行されないことを
    確認する。
51. 実行を開始すると通知領域に進捗(キャンセル可能)が表示され、ステップが進むたびに
    「`[n/N] <説明>`」に更新されることを確認する(1ステップに数十秒かかることがある)。
    出力パネル「ftester」に全イベントが逐次出力されることを確認する。
52. 通知の「キャンセル」を押すと、実行中の CLI プロセスが終了し(出力パネルでプロセス終了を
    確認できる)、それ以上通知が表示されないことを確認する。
53. 探索がテストの目標を達成して完了すると、情報メッセージ「探索完了(N ステップ)」が
    「ファイルを開く」ボタン付きで表示され、押すと生成された Swift シナリオファイルが
    エディタで開くことを確認する。シナリオツリーにも生成されたシナリオが反映されることを
    確認する。
54. 最大ステップ数に到達する、または FM が目標達成を諦めた場合は、警告メッセージ
    「探索は未完了ですがシナリオを生成しました(TODOコメント付き)。」が表示されることを
    確認する(生成されたファイルに TODO コメントが含まれることを合わせて確認する)。
55. 生成コードがビルド検証に失敗する状況(意図的に不正なコードが生成されるよう目標を工夫する等)
    では、警告メッセージ「ビルド検証に失敗したため `_disabled/` に隔離されました。」が表示され、
    「ファイルを開く」を押すと `Scenarios/_disabled/` 配下の隔離されたファイルが開くことを
    確認する。
56. FM が利用できない状態(例: `Doctor` コマンドで FM 利用不可と分かる環境)やドライバへの
    接続に失敗する状況で実行すると、致命的エラーとしてエラーメッセージが表示されることを
    確認する。

## npm scripts

| コマンド | 内容 |
|---|---|
| `npm run compile` | `esbuild.mjs` で `src/extension.ts` を `dist/extension.js` にバンドルし、`tsc --noEmit` で型チェックする |
| `npm run watch` | 上記のバンドルをウォッチモードで実行する |
| `npm test` | `esbuild.mjs --tests` で `test/*.test.mjs` を `out-test/` にバンドルし、`node --test out-test/*.test.mjs` で実行する(NDJSON パーサ・実行結果 reducer(並列実行ケース含む)・ログレーン変換・DAP アダプタ・デバイスモニター(タイル個別起動/停止含む)/ライブ操作/FM探索の変換/検証のユニットテスト。E2E テストは `FTESTER_E2E` 未設定時は自動的に skip される) |
| `npm run package` | `vsce package` で `.vsix` を生成する(marketplace 未公開/publisher 未検証の警告は無視してよい) |

### E2E テスト(実バイナリを使った疎通確認)

実バイナリ(`.build/debug/ftester`)・実リポジトリ(`Projects/SampleApp/`)に依存する E2E テストは
`FTESTER_E2E=1` のときだけ実行され、通常の `npm test` では自動的に skip される
(`node --test` の実行前に `node esbuild.mjs --tests` で `out-test/` を更新しておくこと)。

`test/e2e-dryrun-debug.test.mjs` は `.build/debug/ftester` を実際に spawn し、
`ログインテスト.S0010` を `--debug --dry-run` で動かして
`stopped(entry)` → `next` → `stopped(step)` → `continue` → `stopped(breakpoint)` → `continue` →
`scenarioFinished` → `terminated` の一連の流れを検証する(デバイス/シミュレータ不要)。
通常の `npm test` では skip されるので、明示的に実行する。

```bash
cd ..                        # リポジトリルート(foundation-tester/)へ
swift build --product ftester
cd vscode-ftester
node esbuild.mjs --tests      # out-test/*.test.mjs を更新(npm test の前半と同じ)
FTESTER_E2E=1 node --test out-test/e2e-dryrun-debug.test.mjs
```

`test/e2e-monitor.test.mjs` は `.build/debug/ftester api monitor --project SampleApp --interval 0.5
--max-width 240` を実際に spawn し、`monitorDevices` イベントが30秒以内に届くこと(デバイス配列が
1件以上で、各要素が `name`/`platform`(`ios`/`android`)/`state`(`monitorModel.ts` が受理する語彙:
`connected`/`booted`/`offline`)を持つこと)・SIGTERM 送信から数秒以内にプロセスが終了すること・
stdout に `monitorDevices`/`monitorFrame`/`monitorError` 以外の行種(パース不能な行を含む)が
混ざっていないことを検証する。**シミュレータ/エミュレータ自体が起動している必要はありません**
(`state: "offline"`(未起動)のままでも成功します。`Projects/SampleApp/profiles/machines/` に
マシンプロファイルが定義されていることだけが前提です)。

```bash
cd ..
swift build --product ftester
cd vscode-ftester
node esbuild.mjs --tests
FTESTER_E2E=1 node --test out-test/e2e-monitor.test.mjs
```

## ディレクトリ構成

```
vscode-ftester/
├── package.json      # 拡張マニフェスト(コマンド・設定・デバッガ宣言を含む)
├── tsconfig.json      # strict 設定(型チェック専用。出力は esbuild が担う)
├── esbuild.mjs         # ビルドスクリプト(拡張本体 / テストバンドルの2用途)
├── schemas/
│   ├── app-profile.schema.json     # profiles/apps/*.json 用 JSON スキーマ(補完・ホバー・型チェック)
│   ├── machine-profile.schema.json # profiles/machines/*.json 用 JSON スキーマ
│   └── run-profile.schema.json     # profiles/runs/*.json 用 JSON スキーマ
├── src/
│   ├── extension.ts           # activate/deactivate。コンポーネント登録の起点
│   ├── config.ts               # ftester.* 設定の読み取り・ワークスペースルート/対象プロジェクトの解決
│   ├── cli.ts                  # FtesterCli: spawn・NDJSON/JSON パース・実行キュー・キャンセル
│   ├── ndjson.ts                # NdjsonParser(vscode 非依存の純粋クラス)
│   ├── model.ts                 # CLI 契約の TypeScript 型定義
│   ├── testTree.ts              # TestController によるシナリオツリー表示
│   ├── watcher.ts               # ファイル監視 + デバウンス
│   ├── runReducer.ts            # RunEvent → RunAction[] の純粋な reducer(vscode 非依存)
│   ├── runHandler.ts            # Run/Debug プロファイル登録・対象解決・RunAction → vscode API 適用
│   ├── runEventBus.ts           # RunEventBus: 実行イベント(生RunEvent)+開始/終了を複数購読者へ配信するpub/sub(vscode非依存)
│   ├── runLaneModel.ts          # RunEvent → ログレーンのアクション(構成/行/実行中状態)への純粋な変換(vscode非依存)
│   ├── debugAdapter.ts          # FtesterDebugSession(DAP 本体。@vscode/debugadapter のみに依存)
│   ├── debugConfig.ts           # vscode.debug.* への登録(DescriptorFactory/ConfigurationProvider)
│   ├── stepsModel.ts            # StepRow[] → ステップ一覧ノードモデルへの純粋な変換(vscode 非依存)
│   ├── stepsView.ts             # 「ステップ一覧」TreeView(ftesterSteps)。エディタ追従・キャッシュ管理
│   ├── monitorModel.ts          # `ftester api monitor` の NDJSON → webview メッセージへの変換・検証(vscode 非依存)
│   ├── monitorPanel.ts          # デバイスモニターの WebviewPanel(ftesterMonitor)。monitor プロセスの spawn/中継・devices up/down・ログレーンUI
│   ├── healModel.ts             # HealFixCollector・検証/diffロジック・apply-heal 契約の変換(vscode 非依存)
│   ├── healReviewPanel.ts       # 自己修復確認の WebviewPanel(ftesterHealReview)。RunEventBus購読・ソース読込・apply-heal 呼び出し
│   ├── profileModel.ts          # `ftester api validate-profile` の出力の検証・変換、プロファイルファイルパスの種別判定(vscode 非依存)
│   ├── profileDiagnostics.ts    # DiagnosticCollection("ftester-profile")。保存時自動検証・ftester.validateProfiles コマンド
│   ├── liveModel.ts             # `ftester api list-devices`/`ftester api live serve`/`ftester api gen-scenario` の検証・NDJSONコマンド組み立て・座標変換・要素行フォーマット・CLI引数組み立て・レコーディング→FlowStep変換・webviewメッセージプロトコル(vscode 非依存)
│   ├── monitorLiveController.ts # デバイスモニターパネル(monitorPanel.ts)の「ライブ操作」タブ担当サブコントローラ。list-devices の専用spawn+live serve の常駐spawn(いずれもFtesterCliのキューを使わない)・座標変換の適用・serveの観測イベント反映・画面ストリーミング/自動フレームの供給元切替・レコーディング→gen-scenario
│   ├── exploreModel.ts          # `ftester api explore` の NDJSON検証・進捗文言・完了通知文言・入力検証・デバイス選択アイテム組み立て(vscode 非依存)
│   ├── exploreCommand.ts        # コマンド ftester.explore(FM探索)。デバイス選択QuickPick・InputBox・FtesterCliのキュー経由の実行・withProgress・完了/エラー通知
│   └── webview/monitor/
│       └── liveTab.js           # 「ライブ操作」タブのwebview資産(デバイス選択・スクリーンショットのタップ/ドラッグ/長押し・要素一覧・レコーディングUI)。対向: liveModel.ts の LiveWebviewEnvelope(他タブの webview 資産は省略)
└── test/
    ├── ndjson.test.mjs          # NdjsonParser のユニットテスト(node:test)
    ├── runReducer.test.mjs      # runReducer のユニットテスト(並列実行ケース含む) + mock-runner を使った統合テスト
    ├── runLaneModel.test.mjs    # runLaneModel のユニットテスト(レーン構成/500行キャップ等) + mock-runner(--pattern parallel)を使った統合テスト
    ├── dap.test.mjs             # FtesterDebugSession のプロトコルテスト(mock-runner --debug 相手)
    ├── stepsModel.test.mjs      # buildStepTree のユニットテスト(node:test)
    ├── monitorModel.test.mjs    # monitorModel のユニットテスト(タイル右クリックメニューの起動/停止項目状態・NDJSON検証含む) + mock-monitor/mock-device-op を使った統合テスト
    ├── healModel.test.mjs       # healModel のユニットテスト + mock-runner(--pattern heal)を使った統合テスト
    ├── cli.test.mjs             # FtesterCli の stdin 対応 spawn のテスト(mock-apply-heal 相手)
    ├── profileModel.test.mjs    # profileModel のユニットテスト + mock-validate-profile を使った統合テスト + 実バイナリ(存在すれば)確認
    ├── profileSchema.test.mjs   # schemas/*.schema.json が実在の Projects/SampleApp/profiles/*.json を受理することの確認(ajv 不使用の最小評価器)
    ├── liveModel.test.mjs       # liveModel のユニットテスト(検証・NDJSONコマンド組み立て/イベント検証・座標変換・要素行フォーマット・CLI引数組み立て・webviewメッセージプロトコル) + mock-live を使った統合テスト + 実バイナリ(存在すれば)確認
    ├── exploreModel.test.mjs    # exploreModel のユニットテスト(NDJSON検証・進捗文言・完了通知文言・入力検証・デバイス選択アイテム) + mock-explore を使った統合テスト
    ├── e2e-dryrun-debug.test.mjs  # 実バイナリ(api run --debug --dry-run)を使った E2E テスト(FTESTER_E2E=1 のときだけ実行)
    ├── e2e-monitor.test.mjs       # 実バイナリ(api monitor)を使った E2E テスト(FTESTER_E2E=1 のときだけ実行)
    └── fixtures/
        ├── mock-runner.mjs      # `ftester api run` を模したダミー NDJSON エミッタ(--debug 対応、--pattern parallel/heal で並列実行/自己修復の契約を模す)
        ├── mock-monitor.mjs     # `ftester api monitor` を模したダミー NDJSON エミッタ
        ├── mock-device-op.mjs   # `ftester api device-up`/`ftester api device-down` を模したダミースクリプト(--fail で ok:false を模せる)
        ├── mock-apply-heal.mjs  # `ftester api apply-heal` を模したダミースクリプト(stdin の JSON をそのまま読んで応答を返す)
        ├── mock-validate-profile.mjs  # `ftester api validate-profile` を模したダミースクリプト(--kind/--name 絞り込みに対応)
        ├── mock-live.mjs         # `ftester api list-devices`(ワンショット)/`ftester api live serve`(常駐・stdin の NDJSON コマンドに応答)を模したダミースクリプト(--fail で ok:false を模せる)
        ├── mock-explore.mjs      # `ftester api explore` を模したダミー NDJSON エミッタ(遅延つきでイベント列を流す。--fail でerrorパターン)
        └── dapDriver.mjs        # FtesterDebugSession を直接駆動するテストヘルパー(dap/e2e で共用)
```

## 後続フェーズが実装する予定のもの

- デバッグアダプタの `stackTraceRequest` は直近の `paused` イベントから1フレームだけを
  組み立てる簡易実装です。`scopesRequest`/`variablesRequest` は、停止中(直近の `paused`
  イベントがある)ときだけスコープ「ステップ」(`expensive: false`)を1つ返し、その変数として
  停止中のステップ情報(`シナリオ`/`ステップ番号`/`コマンド`/`scene`/`区分`/`位置`
  (`file:line`))を表示します(値が無い項目は表示しません)。実行中(未停止)は空配列を返します。
  複数フレーム表示・式評価等は未対応です。
