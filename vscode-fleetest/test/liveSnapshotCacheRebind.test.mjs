// デバイスを切り替えたら、前のデバイスのスナップショット(画面サイズ・要素一覧)を捨てることの
// ソース走査。
//
// 握ったままだと2つとも黙って壊れる:
//   - タップ座標が**前のデバイスの画面サイズ**で換算される(px の Android → pt の iOS では
//     まるごと別の場所を叩く)
//   - 要素一覧の行タップ(tapRef)は**新しいデバイスの木の同じ番号**を叩く。ref は
//     スナップショットごとの採番なので、別の要素に当たっても誰も気付けない
// webview 側の挙動(捨てたあとは無反応 + 次のフレームで撮り直しを自動要求)は
// webviewLiveDrag.test.mjs が実 DOM で見る。ここは host 側の配線
// (MonitorLiveController は vscode.ExtensionContext 等が要りスタブでは作れない)を走査で守る。

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

/** コメント行を落とす(理由書きに関数名が出るので、素で走査すると実装を消しても緑になる) */
function codeOnly(source) {
  return source
    .split("\n")
    .filter((line) => !line.trim().startsWith("//") && !line.trim().startsWith("*") && !line.trim().startsWith("/*"))
    .join("\n");
}

function controllerSource() {
  return codeOnly(fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8"));
}

function body(source, marker) {
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, `${marker} が見つからない`);
  const end = source.indexOf("\n  }", start);
  assert.notEqual(end, -1, `${marker} の本体末尾が見つからない`);
  return source.slice(start, end);
}

test("バインド先のデバイスが変わるときだけスナップショットの控えを捨てる", () => {
  const source = controllerSource();
  const ensure = body(source, "private ensureServeProcess(device: LiveDeviceRef): void {");
  assert.match(ensure, /clearSnapshotCache\(\)/, "デバイスが変わったら控えを捨てること");
  assert.match(
    ensure,
    /!sameLiveDeviceRef\([^)]*\)[\s\S]*clearSnapshotCache\(\)/,
    "同じデバイスへの張り直し(serve の再起動)では捨てないこと",
  );
});

test("デバイス未選択になったときも控えを捨てる", () => {
  const source = controllerSource();
  const ensureForSelection = body(source, "private ensureServeProcessForSelection(): void {");
  assert.match(ensureForSelection, /clearSnapshotCache\(\)/, "選択が外れたら控えを捨てること");
});

test("控えを捨てる経路は webview にも捨てさせる", () => {
  const source = controllerSource();
  const clear = body(source, "private clearSnapshotCache(): void {");
  assert.match(clear, /this\.lastScreen = undefined/);
  assert.match(clear, /this\.lastElements = \[\]/);
  assert.match(clear, /type: "clearSnapshot"/, "webview 側の控えも捨てさせること");
});

// エラーバナーは利用者が消せなければならない。自動で消えるのは接続系の3文言だけ
// (isConnectionClassMessage)で、ブリッジ接続拒否のように serve が返す文言は次の失敗で
// 上書きされるまで残る = 「消す手段がない」状態だった(2026-09-21)。
// 口は2つ: webview の × ボタン(webviewLiveActionErrorDismiss.test.mjs)と、
// 利用者の操作が通ったときの自動クリア(ここ)。
test("利用者の操作が成功したらエラーバナーを消す", () => {
  const source = controllerSource();
  const run = body(source, "private async runAction(");
  assert.match(
    run,
    /type: "actionError", message: ""/,
    "成功経路でバナーを空にすること(自動フレームは runAction を通らない)",
  );
});
