# foundation-tester

## 読者の分岐(最初に判定する)

- **このツールを「使う」だけ**(自分のアプリのシナリオを書いて実行したい。ツール本体は改造しない):
  `/ftester-setup` スキルに従ってセットアップする。手順の全体像は docs/getting-started.md。
  **以下の保守者向けルール(委譲方針・コメント規約・i18n・ソース分割等)は適用しない。**
- **このツール本体を「改造する」保守者**: 以下すべてが適用対象。

## ドキュメント

- 受け手向けの導入(事前準備・インストール・更新・アンインストールだけ。使い方は README とスキル): docs/getting-started.md
- 受け手の状態判定: `Scripts/preflight.sh`(引数なし・読み取りのみ。カレントを見て
  ready=0 / installed=2 / blocked=1 を返す。SKILL.md ステップ0・0.5 と 1:1)
- 受け手の一括導入: `Scripts/install.sh`(clone〜検証ゲートを冪等に実行)。**各手順は
  `.claude/skills/ftester-setup/SKILL.md` のステップ番号と 1:1**(失敗時に「→ SKILL.md ステップ N」を
  出してエージェントを手作業手順へ戻す設計)。**片方だけ変えない** — 手順の追加・番号の変更は両方に入れる。
  **スキルからは curl 形で呼ぶ**(クローン側の Scripts/ は pull されるまで古く、新しい引数は
  「不明なオプション」で落ちる)。全出力は `<WORK_DIR>/.ftester/install-<日時>.log` に残る。
  **画面は各ステップ1行(逐次)+ 集計だけ・生ログはファイルへ**(`--verbose` で従来。54KB 出すと
  エージェント側で切られ、結果を探す grep が承認を増やす)。**逐次表示は人のためのもの** ——
  数分の無音は「止まった」と誤解され中断される。最後の再掲は warn/fail だけ(全行だと表が2つ並ぶ)。**外部構成ではクローンのローカル変更を自動破棄**
  (reset --hard + `clean -fd`。`-x` は付けない = .build/ を消さない。`--keep-local` で従来)。
  **毎回 `ftester api ensure-settings` で Bash 許可リストを補修する**(init 経由だけだと
  `--skip-project` の更新で既存の受け手に永久に届かない)
- 受け手の更新: `Scripts/update.sh`(install.sh を再実行 + project sync + プラグイン更新と版照合。
  `.claude/skills/ftester-update/SKILL.md` と 1:1)。**先に update-check.sh を呼び up-to-date なら
  即終了**(全工程は更新が無くても約30秒。入れ直しは `--force`)。**ログの場所は最後の
  「次にやること」にも出す**(install.sh には `--no-next-steps` を渡すため、こちらで案内しないと
  人が後から詳細を確認できない)。doctor は既定で出さない
  (`--doctor`。結果表と情報が重複し8秒かかる)。**スキルのステップ0は `.ftester/state.json` の
  Read で TOOL_ROOT を採る**(コマンドを打たない = 承認が要らない。無ければ preflight に落ちる)
- 更新の有無だけ判定: `Scripts/update-check.sh`(読み取りのみ。**fetch せず `git ls-remote`** で
  upstream と比較し up-to-date=0 / update-available=3 / pinned=0 / unknown=1。取り込みはしない)。
  VSCode 拡張が起動時に1日1回呼ぶ(`src/updateCheck.ts`・設定 `ftester.updateCheck`)。
  **手動コマンド `ftester.checkForUpdate` は間隔・却下・設定 off を無視して必ず結果を返す**
  (自動は更新があるときだけ喋る。明示操作で黙るのは誤動作に見えるため。両者の差はここだけ)。
  **`reason=` は ja/en どちらでも英語**(拡張の通知に素通しするため。枠だけ訳す)。
  **TOOL_ROOT の解決規則は preflight.sh / update.sh / `src/toolRootResolve.ts` と同じ**(4箇所。片方だけ変えない)
- DSL コマンドリファレンス(全コマンドの引数・挙動。利用者向け): docs/commands.md
- リリース(git タグ発行と版ピンの関係。配布はソースビルド前提): docs/releasing.md(`Scripts/release.sh`)
- 設計書(アーキテクチャ・Swift DSL 仕様・セレクタ記法・プロファイル): docs/design.md
- 性能チューニング(調整ノブ・不採用施策と再検討条件・計測手順): docs/performance-tuning.md
- 検証の詳細(flake/性能の判定規律・ベータ整合・全滅時の切り分け・e2e.sh のオプション): docs/verification.md
- ftester 自身の E2E: **UI フレームワークごとに SUT が4つ**ある(画面・`#id`・ラベルは全 SUT 共通契約):

  | SUT | 実装 | プロジェクト | 対象 OS |
  |---|---|---|---|
  | `E2EApp/` | Compose Multiplatform | Projects/E2E | ios + android |
  | `E2EAppIOS/` | SwiftUI + 一部 UIKit | Projects/E2E-iOS | ios |
  | `E2EAppAndroid/` | View/XML + 一部 Compose | Projects/E2E-Android | android |
  | `E2EAppFlutter/` | Flutter | Projects/E2E-Flutter | ios + android |

  **要素の testTag/`#id`/ラベルの唯一の正は `E2EApp/docs/ui-contract.md`**(全 SUT とシナリオがこれを参照。
  片方だけ変えない)。**型語彙・OS/フレームワーク固有の罠だけ**は各 SUT の `<SUT>/docs/ui-contract.md` に置く
  (同じ `#id` でも型は SUT ごとに違う。例: ボタンは CMP/Android で `Cell`、View/XML なら `Button`)

## ビルド・検証

**検証の詳細な罠と判定規律(flake/性能の判定・macOS/Xcode ベータ整合・常駐プロセス掃除・
「Application is not running」全滅時の切り分け・`Scripts/e2e.sh` の各オプション)は docs/verification.md**。
以下は毎回効く最重要ゲートだけ。

- 拡張: `cd vscode-ftester && npm run compile`(esbuild+tsc)/ `npm test`。挙動を変えたら
  **`npm version --no-git-tag-version <新版>` で版を上げて** `npm run install-local`
  (反映は VSCode の Reload Window **+パネル開き直し**。Reload だけでは効かないことがある。code CLI は PATH に無い)。
  **package.json だけ手で書き換えない** — lock も version を内包しており、放置すると受け手の
  `npm install` が lock を書き換えてクローンが dirty になり、**次の更新が pull ガードで止まる**
  (実害。`packageLockSync.test.mjs` が検出。既にズレたら `npm install --package-lock-only`)
- Swift: `swift build --build-tests` / `swift test`。**合否は exit code で見る**(パイプすると grep 等の exit code に化けて失敗を握りつぶす実害)
- 実行ファイル差し替えは `swift build --product <名>`。`--target` はリンクせず旧バイナリを実行する(事故実績)
- **DSL コマンド・`StepExecutor`・ドライバ・ブリッジ(`InAppBridge`/`Runner`/`AndroidRunner`)・
  セレクタ/スナップショット/ヒール(`FTAgent`)を変えたら `Scripts/e2e.sh`**(ユニットテストはデバイス
  境界のバグを1つも捕まえない)。**ブリッジのスナップショット/型写像と、StepExecutor の
  操作合成(タップ/ドラッグ/スクロール探索の終端処理)を触ったら SUT を絞らず全部**回す
  (フレームワーク差の退行は SUT を跨がないと出ない。実害: 探索終端の空打ちドラッグは CMP では
  無害・SwiftUI ではタブバーが反応し、E2E-iOS を回すまで 5/5 の回帰に気付けなかった)。
  **入力・キー・IME 系を触ったら `--ios-inapp` も回す**(既定の e2e.sh は iOS を xcuitest でしか
  回さないが、**利用者の既定エンジンは hybrid = in-app 優先**。実害: pressEnter のバグ2件が
  既定スイートでは最後まで表面化しなかった)。詳細は docs/verification.md
- **flake の修正は1回グリーンで判定しない・単発の観測で性能を断じない**(反復+負荷で叩く。実害と
  手順は docs/verification.md)
- `ftester api` の JSON/NDJSON 契約を後方非互換に変えたら `Sources/FTCore/ProtocolVersion.swift` と `vscode-ftester/src/protocolVersion.ts` の版を +1(両者一致必須・`protocolVersion.test.mjs` が検出。拡張は起動時に照合し不一致を警告)
- **ブリッジの挙動・エンドポイントを変えたら版を上げる**(上げないと**稼働中の旧ブリッジが再利用され、変更が反映されないまま緑になる**。実害2回)。iOS = `Sources/FTCore/BridgeDTO.swift` の `bridgeProtocolVersion`(in-app dylib と XCUITest ランナーの共通定数)/ Android = `AndroidRunner/build.sh` の `VERSION_CODE` と `AndroidBridge.swift` の `expectedBridgeVersionCode` を**同時に**(`AndroidBridgeVersionSyncTests` が不一致を検出。「上げ忘れ」自体は検出できないので人間の規律)

## 受け手フローの設計方針(スキル・スクリプト・CLI の分担)

- **機械作業はスクリプト/CLI に寄せ、スキルには判断だけ残す**。エージェントに JSON を書かせる・
  値を集めさせると、実行のたびに結果が揺れる(machines と runs の名前不一致・指示していない
  プラットフォームの生成・二度聞き)。決まった手順は `Scripts/*.sh` か `ftester` のサブコマンドにする
- **承認回数はコストとして数える**。値の収集は preflight の出力に寄せ、デバイス選定は
  `profile setup --auto-device`、繰り返す実行は `.claude/settings.json` の許可(ftester 由来の
  コマンドのみ。`api ensure-settings` が毎回補修)で吸収する。**出力済みの情報を別コマンドで
  取り直さない**。承認は3方向から増えるので全部潰す:
  **①聞かなくてよい確認**(答えが決まっているならスクリプトが決める。例: 外部構成のクローンの
  ローカル変更 = 受け手の資産ではないので自動破棄)/ **②許可リストに無いコマンド**(スクリプトを
  足したら許可も足す)/ **③巨大な出力**(切られてエージェントが grep を打つ。生ログはファイルへ)
- **人に聞くのは AskUserQuestion(ダイアログ)だけ**。チャットに質問文を書くと見落とされてフローが止まる
- **実機・シミュレータが要る判断は純粋ロジックへ切り出して単体テストで固める**
  (例: `DevicePicker`・`ProfileWriter`・`ToolchainFingerprint`)。実機でしか出ない部分だけを E2E に残す

## 実装の委譲

- 原則、実装タスクは Sonnet サブエージェントに委譲する(メインセッションは計画・プロンプト設計・レビュー・検証を担当)
- ユーザーの指示があればそちらを優先する
- 小さな修正や、レビュー中に見つけた直しなど、直接編集した方が良いと判断できる場合は委譲せず直接編集してよい

## 並列一括作業(サブエージェント委譲)

- 全域一括の機械的変更は、ファイル集合が互いに素になるようバッチ分割して並列委譲する(コメント量・行数で均等化)
- サブエージェントに swift build / npm build を実行させない(SPM ビルドロック・出力の競合)。ビルド・テストはメインで全バッチ完了後に一括実行。軽量な per-file チェック(node --check 等)は各エージェントで可
- 「コメントのみ」「移動のみ」を謳う変更は、diff の全変更行を機械検証(全 +/- 行がコメント/空行か、末尾コメント編集はコード部分が同一か)してからコミットする
- Projects/ 配下のシナリオ(.swift)はユーザー資産(一部は explore 生成)。リポジトリ全域の一括整形・コメント編集の対象に含めない

## ソース分割の方針

保守者は Claude Code。目安: 1ファイル約2,000行以下(一度の Read で収まる)、1タスクで編集するのは1〜2ファイルに収まる構成を保つ。超えたら分割を検討する(人間向け可読性は目的ではない)。

- コントローラ分割は、必要なコールバックだけを束ねた狭い deps インターフェースをコンストラクタ注入し、サブコントローラ同士は直接参照しない(実例: monitorPanel.ts の MonitorPanelDeps)
- 可変状態は書き込み箇所と同じモジュールに置き、他モジュールへは読み取り専用で公開する(実例: src/webview/monitor/ の各モジュール)
- webview 資産(CSS/JS)はテンプレートリテラルに内蔵せず src/webview/ の実ファイル+esbuild バンドル(media/ 出力)にする
- エスケープ文脈が変わる逐語移動(テンプレートリテラル⇔実ファイル)では二重エスケープの残存を機械チェックする(`grep '\\\\[dswb]'` 等。過去に `\\d` が検証不能バグとして実害化)

## 国際化(i18n・日英切替)

拡張の UI 文字列は日英切替対応(設定 `ftester.language`: auto/ja/en、auto は VSCode 表示言語に追従。モニター「設定」タブからも変更可)。UI 文字列を追加/変更するとき:

- 辞書は `src/i18n/strings/<namespace>.ts` に `{ "ns.key": { ja, en } } satisfies MessageDict`。**ja は表示文字列と byte 一致**(未初期化時の既定 locale が "ja"・既存テストが日本語をアサートするため)。プレースホルダは名前付き `{name}` で ja/en 同集合。namespace とファイルは1対1。
- 拡張側: `import { t } from "./i18n"`(`MessageKey` 型で typo を tsc 検出)。activate 冒頭で `initI18n()`。webview 側: `import { t } from '../i18n.js'`(locale は `<html lang>` 経由)。静的 HTML(monitorHtml.ts 等)は拡張側 `t()` で描画する。
- **罠**: 拡張と webview の**両バンドルに入る .ts**(runReducer.ts/runLaneModel.ts 等。webview の import 連鎖で混入)は、vscode を引き込む `i18n/index.ts` を import できない(webview ビルドが壊れる)。vscode 非依存の別ランタイム `src/i18n/strings/lane.ts`(`tLane`/`setLaneLocale`、locale は両バンドルが注入)を使う。両バンドル共有の文字列を新たに i18n 化するときも同じ制約。
- **module-level の表示 const 禁止**(import 時=initI18n 前に "ja" で固定される)。関数化する(例 livePanelHtml.ts の `livePanelTitle()`)。
- package.json の contributes(コマンド名・設定説明)だけは別系統: `%key%` + `package.nls.json`(英)/`package.nls.ja.json`(日)で **VSCode 表示言語連動**(ftester.language ではない)。両 nls はキー集合一致。
- 検証は `test/i18n.test.mjs`(辞書パリティ・**残存日本語の AST 走査**[HTML コメントは除外]・webview/lane キー存在・nls 整合)。正当に日本語を残す文字列(非表示の内部 throw 等)は同ファイルの `RESIDUAL_ALLOWLIST` に登録。
- webview パネルの relocalize は未配線。`ftester.language` 変更時の反映はテストツリー再翻訳のみで、パネル・コマンド名・設定説明は Reload Window が必要(extension.ts が案内を出す)。

## コメント規約

コメントの読者は人間ではなく Claude Code。目的は「編集時の事故を防ぐ」「再調査を不要にする」の2つだけ。それに寄与しないコメントはトークンの無駄なので書かない・見つけたら消す。

残す(最小の行数に圧縮して):
- コードから導出できない制約・不変条件・順序依存(例:「acquireVsCodeApi は1回しか呼べない」「stdin EOF が終了指示」)
- ファイル間・言語間で同期が必要な契約(postMessage のメッセージ型、NDJSON プロトコル、ブリッジ HTTP API)と、同期相手のファイルへのポインタ
- 一見単純化・削除できそうに見えるが、すると壊れる箇所の理由(1-2行)
- 数値・チューニング値の意味(単位・上限・根拠)

書かない・削除する:
- 識別子・型・import から分かる「何をするか」の説明
- 設計経緯・履歴(移動元、旧仕様との比較、日付・指示・要件タグ)
- UI・見た目の意図の散文(結果は CSS/コードにある)
- 同じ内容の重複(契約はどちらか1箇所に置き、他方は参照)
- 長い設計解説の散文(要点だけ箇条書きに圧縮)

迷ったら: 契約・制約・罠は残す、説明・散文は削る。
