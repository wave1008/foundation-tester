// panelRelocalizeSourceContract.test.mjs
// Monitor/Live の relocalize() の「開いていれば html を再構築し(ライブ配信を張り直)す」
// 契約をソース走査で検証する。実行時に構成して検証できない理由は panelRelocalize.test.mjs 冒頭
// コメントの通り(renderHtml/renderLiveHtml が vscode.Uri.joinPath(...) を呼び、Monitor は
// コンストラクタ自体が vscode.workspace.createFileSystemWatcher(...) を呼ぶため、esbuild の
// vscodeStubPlugin 下ではどちらも実行できない)。.ts をモジュールとして import せず生テキストとして
// 読むだけなので、esbuild の TS 変換を経由しない(vscode スタブの制約を受けない)。
// 「結果ダッシュボード」は単独パネルを廃止しモニターパネルのタブへ統合済み(旧 dashboardPanel.ts)。
// ダッシュボードタブの再描画は Monitor の relocalize()(html 全体の再構築)に含まれるため、
// 専用の契約テストは無い。
//
// この形の走査は jsdomTeardown.test.mjs や argumentHelpLiteral.test.mjs と同じ、
// 「コンパイル/実行してからでないと踏めない誤りを秒未満で落とす」ためのもの(CLAUDE.md 該当節参照)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

/** name(): void { ... } の本体テキストを波括弧の対応で切り出す。 */
function extractVoidMethodBody(source, name) {
  const marker = `${name}(): void {`;
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, `メソッド ${name}(): void が見つからない`);
  let i = start + marker.length;
  let depth = 1;
  const bodyStart = i;
  while (depth > 0) {
    assert.ok(i < source.length, `${name} の波括弧が閉じていない`);
    if (source[i] === "{") depth += 1;
    else if (source[i] === "}") depth -= 1;
    i += 1;
  }
  return source.slice(bodyStart, i - 1);
}

const monitorSrc = readFileSync(new URL("../src/monitorPanel.ts", import.meta.url), "utf8");
const liveSrc = readFileSync(new URL("../src/livePanel.ts", import.meta.url), "utf8");

test("MonitorPanelController.relocalize(): 未生成ガード → html 再構築 → ライブ配信の張り直しの順", () => {
  const body = extractVoidMethodBody(monitorSrc, "relocalize");
  assert.match(body, /if\s*\(!this\.panel\)\s*\{\s*return;\s*\}/, "パネル未生成の早期 return が無い");
  const renderIdx = body.indexOf("renderHtml(this.panel.webview, this.extensionUri)");
  const restartIdx = body.indexOf("this.deviceStream.restartAllStreams()");
  assert.notEqual(renderIdx, -1, "renderHtml での再構築が無い");
  assert.notEqual(restartIdx, -1, "restartAllStreams でのライブ配信の張り直しが無い");
  assert.ok(renderIdx < restartIdx, "restartAllStreams は html 再構築の後に呼ぶこと");
});

test("LivePanelController.relocalize(): 未生成ガード → html 再構築 → ライブ配信の張り直しの順", () => {
  const body = extractVoidMethodBody(liveSrc, "relocalize");
  assert.match(body, /if\s*\(!this\.panel\)\s*\{\s*return;\s*\}/, "パネル未生成の早期 return が無い");
  const renderIdx = body.indexOf("renderLiveHtml(this.panel.webview, this.context.extensionUri)");
  const restartIdx = body.indexOf("this.live.restartStream()");
  assert.notEqual(renderIdx, -1, "renderLiveHtml での再構築が無い");
  assert.notEqual(restartIdx, -1, "restartStream でのライブ配信の張り直しが無い");
  assert.ok(renderIdx < restartIdx, "restartStream は html 再構築の後に呼ぶこと");
});
