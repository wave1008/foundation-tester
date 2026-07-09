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
  run --profile`)に任せられる(詳細は下記「実行プロファイル(`ftester.profile`)について」)

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

## npm scripts

| コマンド | 内容 |
|---|---|
| `npm run compile` | `esbuild.mjs` で `src/extension.ts` を `dist/extension.js` にバンドルし、`tsc --noEmit` で型チェックする |
| `npm run watch` | 上記のバンドルをウォッチモードで実行する |
| `npm test` | `esbuild.mjs --tests` で `test/*.test.mjs` を `out-test/` にバンドルし、`node --test out-test/*.test.mjs` で実行する(NDJSON パーサ・実行結果 reducer・DAP アダプタのユニットテスト。E2E テストは `FTESTER_E2E` 未設定時は自動的に skip される) |
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
│   ├── debugAdapter.ts          # FtesterDebugSession(DAP 本体。@vscode/debugadapter のみに依存)
│   ├── debugConfig.ts           # vscode.debug.* への登録(DescriptorFactory/ConfigurationProvider)
│   ├── stepsModel.ts            # StepRow[] → ステップ一覧ノードモデルへの純粋な変換(vscode 非依存)
│   └── stepsView.ts             # 「ステップ一覧」TreeView(ftesterSteps)。エディタ追従・キャッシュ管理
└── test/
    ├── ndjson.test.mjs          # NdjsonParser のユニットテスト(node:test)
    ├── runReducer.test.mjs      # runReducer のユニットテスト + mock-runner を使った統合テスト
    ├── dap.test.mjs             # FtesterDebugSession のプロトコルテスト(mock-runner --debug 相手)
    ├── stepsModel.test.mjs      # buildStepTree のユニットテスト(node:test)
    ├── e2e-dryrun-debug.test.mjs  # 実バイナリを使った E2E テスト(FTESTER_E2E=1 のときだけ実行)
    └── fixtures/
        ├── mock-runner.mjs      # `ftester api run` を模したダミー NDJSON エミッタ(--debug 対応)
        └── dapDriver.mjs        # FtesterDebugSession を直接駆動するテストヘルパー(dap/e2e で共用)
```

## 後続フェーズが実装する予定のもの

- デバッグアダプタの `stackTraceRequest` は直近の `paused` イベントから1フレームだけを
  組み立てる簡易実装です(`scopesRequest` は常に空)。変数表示・複数フレーム表示等は
  未対応です。
