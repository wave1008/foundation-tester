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
  ポーリングして接続中のデバイス一覧と各デバイスの画面(静止画)をタイル表示する
  (詳細は下記「デバイスモニター」)。並列実行中は同じパネル下部にワーカー(デバイス)別の
  ログレーンを表示する(詳細は下記「並列実行とログレーン」)

## 前提

- Node.js v24 系 / npm v11 系(推奨。それ以外のバージョンでも概ね動作するはずです)
- ftester 本体(リポジトリルート)がビルド済みであること

## セットアップ

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
npm run package        # vsce package --allow-missing-repository → vscode-ftester-<version>.vsix
```

- `LICENSE` ファイル未配置・publisher 未検証(marketplace 未公開)による警告は出ますが、
  ローカルインストール目的では無視して問題ありません。
- 生成された `.vsix` はリポジトリにコミットしないでください(`.gitignore` に `*.vsix` 済み)。

生成した `.vsix` は VS Code の「拡張機能」ビュー右上の `...` メニュー →
`VSIX からのインストール...` で選択するか、以下のコマンドでインストールします。

```bash
code --install-extension vscode-ftester-0.0.1.vsix
```

インストール後は Extension Development Host のときと同様、`foundation-tester` リポジトリの
ルートフォルダを開けば動作します。

## 設定一覧(`ftester.*`)

`.vscode/settings.json`(ワークスペース設定)または VS Code の設定 UI から変更できます。

| 設定キー | 型 | 既定値 | 説明 |
|---|---|---|---|
| `ftester.binaryPath` | string | `.build/debug/ftester` | ftester CLI バイナリのパス。相対パスはワークスペースルート基準で解決される |
| `ftester.project` | string | `""` | 対象のテストプロジェクト名(`Projects/<name>` の `<name>`)。空なら自動判定(`Projects/` 直下が1つならそれを使用。複数あれば選択を促す) |
| `ftester.profile` | string | `""` | 使用する実行プロファイル名(`Projects/<project>/profiles/runs/<name>.json` の `<name>`)。空なら未指定。非空なら実行・デバッグ実行の両方で `platform`/`port`/`serial` の代わりにこちらが使われる |
| `ftester.platform` | `"ios"` \| `"android"` | `"ios"` | 対象プラットフォーム。`ftester.profile` が空のときだけ使われる |
| `ftester.port` | number | `0` | ブリッジ接続ポート。`0` は未指定(CLI 既定値を使用)。`ftester.profile` が空のときだけ使われる |
| `ftester.serial` | string | `""` | Android デバイスのシリアル番号。空は未指定。`ftester.profile` が空のときだけ使われる |
| `ftester.buildBeforeRun` | boolean | `true` | CLI 呼び出し前に Swift ビルドを行うかどうか。`false` なら CLI 呼び出しに `--skip-build` を付与する |
| `ftester.monitorInterval` | number | `2` | デバイスモニターの更新間隔(秒)。`0.5` 未満は `0.5` として扱われる |
| `ftester.monitorMaxWidth` | number | `960` | デバイスモニターのフレーム画像の長辺px(240〜1600)。大きいほど鮮明だが転送量が増える |

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

## デバイスモニター

コマンドパレットから **「ftester: デバイスモニターを表示」**(`ftester.showDeviceMonitor`)を
実行すると、エディタの横(`ViewColumn.Beside`)に Webview パネルが開きます。既に開いている
場合は既存のパネルを前面に出すだけです(1ワークスペースにつき1枚のシングルトン)。

- パネルを開くと `ftester api monitor --project <project> --interval <秒> --max-width 480` を
  裏で起動し、その NDJSON 出力(デバイス一覧・各デバイスの画面(JPEG)・エラー)をタイル表示に
  反映します。**SCK(ScreenCaptureKit)等によるリアルタイム映像ではなく、`ftester.monitorInterval`
  秒(既定2秒、最小0.5秒)間隔でのポーリングによる静止画更新です。** 更新間隔は
  `.vscode/settings.json` の `ftester.monitorInterval` で変更できます。
- 各タイルには、デバイス名・プラットフォームバッジ(iOS/Android)・状態バッジ・最新の画面
  (未受信時はプレースホルダー枠)・最終更新時刻が表示されます。状態バッジの意味:
  - **接続済み**(緑): ブリッジ接続済みで画面取得・操作が可能な状態
  - **起動中(ブリッジ未接続)**(黄): デバイス自体は起動しているがブリッジがまだ接続されていない状態
  - **未起動**(灰): デバイスが起動していない状態(画面は表示されずプレースホルダー枠になります)
- 上部ツールバーのボタン:
  - **「デバイスを全て起動」**: `ftester devices up` を実行します(マシンプロファイルに定義された
    デバイスを段階的に起動)。
  - **「全て終了」**: `ftester devices down` を実行します(ブリッジ停止+シミュレータ/エミュレータ
    の全終了)。
  - **「モニター再起動」**: `ftester api monitor` プロセスを再起動します(設定変更後や、
    モニタープロセスが異常終了した場合の再接続に使用します)。
  - 起動/終了の実行中は多重起動を防ぐため両ボタンが無効化されます(完了すると自動的に
    再度有効になります)。
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

### ステップ一覧

13. `Projects/<project>/Scenarios/` 配下の `.swift` ファイルをエディタで開き、`@Test` メソッド
    (シナリオ)の本体内にカーソルを置く。サイドバーの「テスト」(Testing)ビューに
    `ftester ステップ` というビューが表示され、カーソルが乗っているシナリオの scene グループ
    (`scene N: <シーンタイトル>`)とステップ(`<番号>. <コマンド>`)一覧が表示されることを
    確認する。カーソルを別のシナリオ(または別ファイルのシナリオ)へ移動すると、表示が
    追従して切り替わることを確認する。ビューのタイトル部分にシナリオIDが表示されることも
    合わせて確認する。
14. テストビューで任意のシナリオを右クリックし、コンテキストメニューから
    **「ftester: ステップ一覧を表示」** を実行すると、`ftester ステップ` ビューにそのシナリオの
    ステップ一覧が表示されることを確認する。
15. `ftester ステップ` ビューでステップ1件をクリックすると、対応するソースファイルの該当行に
    ジャンプし、その行が選択状態になることを確認する。
16. `ftester ステップ` ビューでシナリオを表示した状態のまま、対象シナリオのコマンド行
    (コメントや引数)を編集・保存する。800ms 程度のデバウンス後、ビューの内容が自動的に
    再取得されて更新されることを確認する(ツールバーの更新ボタン(`ftester.refreshSteps`)
    でも同様にキャッシュを破棄して再取得できることを確認する)。

### デバイスモニター

17. コマンドパレットから **「ftester: デバイスモニターを表示」** を実行し、エディタの横に
    Webview パネルが開くことを確認する。もう一度実行しても新しいパネルが増えず、既存の
    パネルが前面に出る(reveal される)ことを確認する。
18. デバイスが1台も起動していない状態では、`ftester.monitorInterval` 秒間隔でタイルが
    「未起動」(灰バッジ)として表示され、画面部分がプレースホルダー枠になっていることを
    確認する。
19. **「デバイスを全て起動」** ボタンを押すと、実行中は「デバイスを全て起動」「全て終了」の
    両ボタンが無効化され、出力パネル「ftester」に `ftester devices up` の出力(段階的な
    起動ログ)が流れることを確認する。完了後にボタンが再度有効になることを確認する。
20. デバイスが起動しブリッジ接続まで完了すると、対象タイルが「接続済み」(緑バッジ)に変わり、
    `ftester.monitorInterval` 秒程度の間隔で画面のスクリーンショットが更新されていくことを
    確認する(SCK 等によるリアルタイム映像ではなく、静止画のポーリング更新であることを
    体感で確認する)。ブリッジ未接続の間は「起動中(ブリッジ未接続)」(黄バッジ)になることも
    確認する。
21. **「モニター再起動」** ボタンを押すと、一旦タイルがクリアされ、`ftester api monitor`
    プロセスが再起動されて最新のデバイス一覧が再表示されることを確認する。
22. **「全て終了」** ボタンを押すと `ftester devices down` が実行され、シミュレータ/
    エミュレータが終了して各タイルが「未起動」に戻ることを確認する。
23. `ftester.binaryPath` を不正なパスに変更する、または `.build/debug/ftester` を一時的に
    リネームするなどしてモニタープロセスを異常終了させると、パネル上部にエラーバナー
    (マシンプロファイル未設定等の案内)が表示されることを確認する。

### 並列実行とログレーン

24. `ftester.profile` に複数デバイスを含むプロファイルを設定し、対象デバイスを起動した状態で
    複数シナリオを選択して「実行」する。デバイスモニターパネルを開いていると、下部に
    ワーカー数分のログレーンが横並びで表示され、各レーンにそのワーカーが担当するシナリオの
    進行(`▶`/`✅`/`❌` 等)が逐次追加されていくことを確認する。実行中は対応するデバイスタイルに
    「実行中」バッジが表示され、シナリオ完了後に消えることを確認する。
25. ログレーン表示中にデバイスタイルを1枚クリックすると、そのタイルが枠線でハイライトされ、
    表示されるレーンがそのデバイスのものだけに絞り込まれることを確認する。複数タイルを
    選択すると選択数分のレーンが表示され、ヘッダーの表示が「全ワーカー」から「選択中N台を
    表示」に変わることを確認する。タイルが無い空きエリアをクリックすると選択が全解除され、
    全ワーカー表示に戻ることを確認する。
26. `ftester.profile` を設定せずに(または dry-run で)「実行」すると、ワーカー別ではなく
    「全体」という1本のレーンにまとめて実行ログが表示されることを確認する。

## npm scripts

| コマンド | 内容 |
|---|---|
| `npm run compile` | `esbuild.mjs` で `src/extension.ts` を `dist/extension.js` にバンドルし、`tsc --noEmit` で型チェックする |
| `npm run watch` | 上記のバンドルをウォッチモードで実行する |
| `npm test` | `esbuild.mjs --tests` で `test/*.test.mjs` を `out-test/` にバンドルし、`node --test out-test/*.test.mjs` で実行する(NDJSON パーサ・実行結果 reducer(並列実行ケース含む)・ログレーン変換・DAP アダプタ・デバイスモニターの変換/検証のユニットテスト。E2E テストは `FTESTER_E2E` 未設定時は自動的に skip される) |
| `npm run package` | `vsce package --allow-missing-repository` で `.vsix` を生成する(marketplace 未公開/LICENSE 未配置の警告は無視してよい) |

### E2E テスト(実バイナリを使ったデバッグアダプタの疎通確認)

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

## ディレクトリ構成

```
vscode-ftester/
├── package.json      # 拡張マニフェスト(コマンド・設定・デバッガ宣言を含む)
├── tsconfig.json      # strict 設定(型チェック専用。出力は esbuild が担う)
├── esbuild.mjs         # ビルドスクリプト(拡張本体 / テストバンドルの2用途)
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
│   └── monitorPanel.ts          # デバイスモニターの WebviewPanel(ftesterMonitor)。monitor プロセスの spawn/中継・devices up/down・ログレーンUI
└── test/
    ├── ndjson.test.mjs          # NdjsonParser のユニットテスト(node:test)
    ├── runReducer.test.mjs      # runReducer のユニットテスト(並列実行ケース含む) + mock-runner を使った統合テスト
    ├── runLaneModel.test.mjs    # runLaneModel のユニットテスト(レーン構成/500行キャップ等) + mock-runner(--pattern parallel)を使った統合テスト
    ├── dap.test.mjs             # FtesterDebugSession のプロトコルテスト(mock-runner --debug 相手)
    ├── stepsModel.test.mjs      # buildStepTree のユニットテスト(node:test)
    ├── monitorModel.test.mjs    # monitorModel のユニットテスト + mock-monitor を使った統合テスト
    ├── e2e-dryrun-debug.test.mjs  # 実バイナリを使った E2E テスト(FTESTER_E2E=1 のときだけ実行)
    └── fixtures/
        ├── mock-runner.mjs      # `ftester api run` を模したダミー NDJSON エミッタ(--debug 対応、--pattern parallel で並列実行の契約を模す)
        ├── mock-monitor.mjs     # `ftester api monitor` を模したダミー NDJSON エミッタ
        └── dapDriver.mjs        # FtesterDebugSession を直接駆動するテストヘルパー(dap/e2e で共用)
```

## 後続フェーズが実装する予定のもの

- デバッグアダプタの `stackTraceRequest` は直近の `paused` イベントから1フレームだけを
  組み立てる簡易実装です(`scopesRequest` は常に空)。変数表示・複数フレーム表示等は
  未対応です。
- デバイスモニターは `ftester api monitor` サブコマンド(CLI 側の実装)を前提としています。
  `test/monitorModel.test.mjs` は `test/fixtures/mock-monitor.mjs`(ダミーの NDJSON エミッタ)を
  相手にした変換・検証テストのみで、実バイナリを使った E2E テストは未整備です。CLI 側の
  実装が揃い次第、`test/e2e-dryrun-debug.test.mjs` に倣った E2E テストの追加を検討してください。
