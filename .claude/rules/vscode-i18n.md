---
paths:
  - "vscode-fleetest/package*.json"
  - "vscode-fleetest/src/**"
  - "vscode-fleetest/src/i18n/index.ts"
  - "vscode-fleetest/src/i18n/strings/lane.ts"
  - "vscode-fleetest/test/**"
  - "vscode-fleetest/test/i18n.test.mjs"
---

# VSCode 拡張(ビルド・ソース分割・i18n) の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- `cd vscode-fleetest && npm run compile`(esbuild+tsc)/ `npm test`。挙動を変えたら
  **`npm version --no-git-tag-version <新版>` で版を上げて** `npm run install-local`
  (反映は VSCode の Reload Window **+パネル開き直し**。code CLI は PATH に無い)
- **package.json だけ手で書き換えない** —— lock も version を内包しており、放置すると受け手の
  `npm install` が lock を書き換えてクローンが dirty になり、**次の更新が pull ガードで止まる**
  (`packageLockSync.test.mjs` が検出。既にズレたら `npm install --package-lock-only`)
- **jsdom を使う webview テストは `t.after(() => window.close())` で必ず閉じる**
  (`jsdomTeardown.test.mjs` がソース走査で落とし、`npm test` は `--test-force-exit` 付き)
  → maintainer-notes §4.3。**同型: `argumentHelpLiteral.test.mjs`**。
  **一般化: 「コンパイルで落ちる誤り」「テストが終わらない」型はソース走査で秒未満に落とす**
- コントローラ分割は、必要なコールバックだけを束ねた狭い deps インターフェースをコンストラクタ注入し、サブコントローラ同士は直接参照しない(実例: monitorPanel.ts の MonitorPanelDeps)
- 可変状態は書き込み箇所と同じモジュールに置き、他モジュールへは読み取り専用で公開する(実例: src/webview/monitor/ の各モジュール)
- webview 資産(CSS/JS)はテンプレートリテラルに内蔵せず src/webview/ の実ファイル+esbuild バンドル(media/ 出力)にする
- エスケープ文脈が変わる逐語移動(テンプレートリテラル⇔実ファイル)では二重エスケープの残存を機械チェックする(`grep '\\\\[dswb]'` 等。過去に `\\d` が検証不能バグとして実害化)
- 辞書は `src/i18n/strings/<namespace>.ts` に `{ "ns.key": { ja, en } } satisfies MessageDict`。**ja は表示文字列と byte 一致**(未初期化時の既定 locale が "ja"・既存テストが日本語をアサートするため)。プレースホルダは名前付き `{name}` で ja/en 同集合。namespace とファイルは1対1。
- 拡張側: `import { t } from "./i18n"`(`MessageKey` 型で typo を tsc 検出)。activate 冒頭で `initI18n()`。webview 側: `import { t } from '../i18n.js'`(locale は `<html lang>` 経由)。静的 HTML(monitorHtml.ts 等)は拡張側 `t()` で描画する。
- **罠**: 拡張と webview の**両バンドルに入る .ts**(runReducer.ts/runLaneModel.ts 等。webview の import 連鎖で混入)は、vscode を引き込む `i18n/index.ts` を import できない(webview ビルドが壊れる)。vscode 非依存の別ランタイム `src/i18n/strings/lane.ts`(`tLane`/`setLaneLocale`、locale は両バンドルが注入)を使う。両バンドル共有の文字列を新たに i18n 化するときも同じ制約。
- **module-level の表示 const 禁止**(import 時=initI18n 前に "ja" で固定される)。関数化する。
- package.json の contributes(コマンド名・設定説明)だけは別系統: `%key%` + `package.nls.json`(英)/`package.nls.ja.json`(日)で **VSCode 表示言語連動**(fleetest.language ではない)。両 nls はキー集合一致。
- 検証は `test/i18n.test.mjs`(辞書パリティ・**残存日本語の AST 走査**[HTML コメントは除外]・webview/lane キー存在・nls 整合)。正当に日本語を残す文字列(非表示の内部 throw 等)は同ファイルの `RESIDUAL_ALLOWLIST` に登録。
- `fleetest.language` 変更は各 webview パネル(Monitor/HealReview。Dashboard・ライブ操作はモニターのタブ)の `relocalize()` が
  `webview.html` を再代入して即時反映する(`extension.ts` が呼ぶ `languageChangeHandler.ts` の
  `handleLanguageChange` が束ねる。vscode 非依存に切り出してあるのはテストのため。パネル未生成時は
  no-op)。Monitor は html 再代入(webview 再読込)でブラウザ側デコーダが失われるため、直後に
  `restartAllStreams()`(タイル)と `LiveTabHost.restartStream()`(ライブ操作タブ)でライブ配信を新キーフレームから張り直す。
  Reload Window が必要なのは package.nls(コマンド名・設定説明。VSCode 表示言語連動で
  `fleetest.language` とは無関係)だけ。
