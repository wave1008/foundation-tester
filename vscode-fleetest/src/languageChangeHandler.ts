// languageChangeHandler.ts
// fleetest.language 変更時の反映本体(extension.ts の onDidChangeConfiguration ハンドラから呼ぶ)。
// vscode 依存を引数へ切り出した独立ファイル(vscode を import しない)。extension.ts は
// registerXPanel() 系(profileDiagnostics.ts・testTree.ts を経由)を import しており、それらは
// モジュール読み込み時に vscode.Range/TestTag を呼ぶため、esbuild の vscodeStubPlugin
// (テスト時に vscode を空 Proxy へ差し替える)ではテストから extension.ts を直接 import できない
// (test/languageChangeRelocalize.test.mjs 冒頭コメント参照)。ここを分けることで vscode 抜きに
// 直接テストできる。

export interface LanguageChangeDeps {
  readonly setLocale: () => void;
  readonly isRunActive: () => boolean;
  readonly rebuildTestTree: () => void;
  /** 開いている各パネル(Monitor/Live/Dashboard/HealReview)の relocalize()。パネル未生成分は
   * 各 relocalize() 自身が no-op にする(呼び出し側では判定しない)。 */
  readonly relocalizePanels: readonly (() => void)[];
}

/** locale を切り替え、実行中でなければテストツリーを再翻訳し、開いている各パネルの html を
 * relocalize() で組み直す。案内(Reload Window)は無い — 各パネルの relocalize() で完結するため。 */
export function handleLanguageChange(deps: LanguageChangeDeps): void {
  deps.setLocale();
  if (!deps.isRunActive()) {
    deps.rebuildTestTree();
  }
  for (const relocalize of deps.relocalizePanels) {
    relocalize();
  }
}
