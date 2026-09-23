// デバイス切り替え(serve の再バインド)中に届いたコマンドを、新しい常駐プロセスが立つまで
// 待たせることのソース走査。
//
// 待たないと、利用者が**たった今選んだデバイス**に対して「ライブ操作の常駐プロセスが起動して
// いません。デバイスを選び直してください」が数秒だけ出て、その後そのまま画面が出る。旧 serve は
// SIGTERM を無視するので停止に最大2秒掛かり、デバイスを選んだ直後の snapshot は必ずこの窓に入る。
// 案内どおり選び直しても同じ再バインドなので同じ文言が出る = 対処のしようが無い誤報だった。
//
// MonitorLiveController は vscode.ExtensionContext 等が要りスタブでは作れないため、
// liveSnapshotCacheRebind.test.mjs と同じく host 側の配線を走査で守る。

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

test("serve へ送る2経路とも再バインドの完了を待ってから不在を判定する", () => {
  const source = controllerSource();
  for (const marker of [
    "private async sendServeCommandNow(",
    "private async sendServeFrameNow(",
  ]) {
    const fn = body(source, marker);
    assert.match(
      fn,
      /await this\.awaitServeRebind\(\)[\s\S]*serveProcess/,
      `${marker} は serveProcess を見る前に再バインドを待つこと`,
    );
  }
});

test("待つのは再バインド中だけ・上限を置く", () => {
  const source = controllerSource();
  const fn = body(source, "private awaitServeRebind(): Promise<void> {");
  assert.match(
    fn,
    /if \(!this\.serveRestartPending\) \{\s*return Promise\.resolve\(\);/,
    "再バインド中でなければ待たないこと(本当に居ないときは従来どおり即座に断る)",
  );
  assert.match(fn, /setTimeout\(wake, SERVE_REBIND_WAIT_MS\)/, "待ちに上限を置くこと");
  assert.match(fn, /this\.serveReadyWaiters\.push\(wake\)/, "再バインド完了で起こされること");
});

test("再バインドは起動の成否に関わらず待ち手を解放する", () => {
  const source = controllerSource();
  const fn = body(source, "private rebindServeProcess(device: LiveDeviceRef): void {");
  assert.match(
    fn,
    /startServeProcess\(target\);\s*\}\s*this\.wakeServeReadyWaiters\(\);/,
    "startLatest の終端で待ち手を起こすこと(起動しなかった回を待たせ続けない)",
  );
});
