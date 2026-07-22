# foundation-tester

## 読者の分岐(最初に判定する)

- **このツールを「使う」だけ**(自分のアプリのシナリオを書いて実行したい。ツール本体は改造しない):
  `/ftester-setup` スキルに従ってセットアップする。手順の全体像は docs/getting-started.md。
  **以下の保守者向けルール(委譲方針・コメント規約・常駐プロセス掃除・ソース分割等)は適用しない。**
- **このツール本体を「改造する」保守者**: 以下すべてが適用対象。

## ドキュメント

- 使い方(クローン→ビルド→自分のアプリを登録→実行。受け手向け): docs/getting-started.md
- リリース(git タグ発行と版ピンの関係。配布はソースビルド前提): docs/releasing.md(`Scripts/release.sh`)
- 設計書(アーキテクチャ・Swift DSL 仕様・セレクタ記法・プロファイル): docs/design.md
- 性能チューニング(調整ノブ・不採用施策と再検討条件・計測手順): docs/performance-tuning.md
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

- 拡張: `cd vscode-ftester && npm run compile`(esbuild+tsc)/ `npm test`
- Swift: `swift build --build-tests` / `swift test`
- 拡張の挙動を変えたら: package.json の version を上げて `npm run install-local`(パッケージ+インストール+到達確認まで一括。code CLI は PATH に無い)。反映には VSCode の Reload Window+パネル開き直しが必要。コメント整理など挙動不変の変更では vsix 更新不要
- 再ビルド後の検証前に旧バイナリの常駐プロセス(monitor/host-metrics)を kill(生き残って検証を汚す。docs/performance-tuning.md §7)
- 実行ファイルを差し替えるビルドは `swift build --product <名>`。`--target` はコンパイルのみでリンクしない(旧バイナリをそのまま実行する事故が実際に起きた)
- ビルドの合否は exit code で確認する。`npm run compile 2>&1 | grep ... && 次コマンド` のようにパイプすると grep の exit code が使われ、tsc の失敗を握りつぶして次へ進んでしまう(実際に起きかけた)
- macOS ベータを更新したら Xcode も同じベータへ揃えてフルリビルド。FoundationModels の ABI 不整合で全バイナリが dyld クラッシュする(swift build は SDKROOT/--sdk を無視するため Xcode 側を揃えるしかない)
- Xcode(beta)単体の更新でも同様: iOS ランタイム導入(`xcodebuild -downloadPlatform iOS`)+ランナー再ビルドで整合させる。不整合はアプリが数操作で「Application is not running」クラッシュする(`ftester doctor` が DTXcodeBuild 不一致を警告。2026-07-21 実害)
- テストが「Application is not running」で全滅したら、ランナーや自分の変更を疑う前に **SUT のバックエンド死活を確認**(sut-ec-mobile は localhost:8090 の dev サーバ。停止中はアプリが非同期例外でクラッシュする)。apps プロファイルの healthCheckURL が実行開始時に警告を出す
- **次を変えたら `Scripts/e2e.sh` を回す**(ftester 自身の E2E。ユニットテストはデバイス境界のバグを
  1つも捕まえられないため、ここを通さないと「黙って空振りする」類の退行が素通りする):
  - DSL コマンド(`Sources/FTDSL/Commands.swift`)・`StepExecutor`・ドライバ(`Sources/FTBridgeClient/`)
  - ブリッジ(`InAppBridge/`・`Runner/`・`AndroidRunner/`)
  - セレクタ解決・スナップショット・ヒール(`FTAgent`)
- `Scripts/e2e.sh` は **4 SUT 全部**の鮮度を見て必要なら再ビルドし、各プロファイルを順に回す
  (`--rebuild` / `--ios` / `--android` / `--cmp` / `--ios-native` / `--android-native` / `--flutter`)。
  **両OSを1プロファイルにまとめない**: platform 未指定シナリオは既定 platform のキューにしか入らず
  他方のワーカーが空回りする(design.md §11.4)。SUT はネットワーク依存ゼロなのでバックエンド死活の切り分けは不要
- **フレームワーク差の退行は SUT を跨がないと出ない**。ブリッジのスナップショット/型写像
  (`SnapshotBuilder`・`BridgeRouter`)を触ったら SUT を絞らず全部回す。片方だけ通って
  もう片方が黙って空振りする類の退行が実際に出る(Compose の Button は `Cell`、View/XML は `Button` 等)
- `ftester api ...` の JSON/NDJSON 契約を後方非互換に変えたら `Sources/FTCore/ProtocolVersion.swift` と `vscode-ftester/src/protocolVersion.ts` の版を +1(両者一致必須・`protocolVersion.test.mjs` が検出)。拡張は起動時に `ftester api version` で照合し不一致を警告する(`compatCheck.ts`)

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
