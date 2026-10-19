// CLI の英語エラー文言の日本語訳(src/i18n/cliMessageTranslation.ts)。
// 辞書の en は照合の型そのものなので、Swift 側の文言が変わると訳が黙って付かなくなる ——
// 最後のテストが Sources/FTBridgeClient の Swift と突き合わせて止める。

import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { translateCliMessage } from "../src/i18n/cliMessageTranslation";
import { cliMessagesStrings } from "../src/i18n/strings/cliMessages";

test("入れ子の文言(ブリッジの準備 → ポートの占有 → 占有者)を全段訳す", () => {
  const original =
    "iPhone 17 Pro(iOS 27.0)-05: the bridge did not become ready in time (port 8129): port 8129 is in use by another process (another device's in-app bridge (udid 26FB5C4F-28B3-42D0-BB3A-A7B4D63917FF))";
  assert.equal(
    translateCliMessage(original),
    "iPhone 17 Pro(iOS 27.0)-05: ブリッジが時間内に準備完了になりませんでした (ポート 8129): ポート 8129 は別のプロセスによって使用されています (別のデバイスのアプリ内ブリッジ (udid 26FB5C4F-28B3-42D0-BB3A-A7B4D63917FF))",
  );
});

test("辞書に無い文言は null(訳を付けない)", () => {
  assert.equal(translateCliMessage("something unexpected happened"), null);
  assert.equal(translateCliMessage("ブリッジを起動できませんでした"), null);
});

test("同じ名前のプレースホルダは同じ値のときだけ当たる", () => {
  assert.equal(
    translateCliMessage("the bridge is not running (no .fleetest/bridge-8129.pid and no .fleetest/bridge-8129.inapp)"),
    "ブリッジは起動していません (.fleetest/bridge-8129.pid も .fleetest/bridge-8129.inapp もありません)",
  );
  assert.equal(
    translateCliMessage("the bridge is not running (no .fleetest/bridge-8129.pid and no .fleetest/bridge-8130.inapp)"),
    null,
  );
});

test("型の末尾のプレースホルダは行末まで取る", () => {
  assert.equal(
    translateCliMessage("bridge start-up timed out (last error: connection refused (61)). Log: /tmp/a b.log"),
    "ブリッジの起動がタイムアウトしました (最後のエラー: connection refused (61))。ログ: /tmp/a b.log",
  );
});

/** Swift の連結(`"..." + "..."`)をつないで `\"` を戻した本文。補間 `\(...)` は残す */
function swiftText() {
  const dir = path.resolve("../Sources/FTBridgeClient");
  return readdirSync(dir)
    .filter((name) => name.endsWith(".swift"))
    .map((name) => readFileSync(path.join(dir, name), "utf8"))
    .join("\n")
    .replace(/"\s*\n\s*\+\s*"/g, "")
    .replace(/\\"/g, '"');
}

test("辞書の en はどれも Sources/FTBridgeClient の Swift の文言と一致する", () => {
  const source = swiftText();
  const interpolation = String.raw`\\\((?:[^()]|\([^()]*\))*\)`;
  const missing = [];
  for (const [key, { en }] of Object.entries(cliMessagesStrings)) {
    const pattern = en
      .split(/\{\w+\}/)
      .map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
      .join(interpolation);
    if (!new RegExp(pattern).test(source)) {
      missing.push(key);
    }
  }
  assert.deepEqual(missing, []);
});
