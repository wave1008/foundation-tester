// プロトコル版のドリフト検出。Sources/FTCore/ProtocolVersion.swift(Swift 側の真実)と
// src/protocolVersion.ts(拡張側のミラー)が一致することを確認する。
// 拡張側は i18n.test.mjs と同じ方式(esbuild --tests がバンドルする TS を直接 import)で取得する。
// Swift 側は Swift ソースを持たないため fs + 正規表現で数値を抽出する。
//
// process.cwd() は npm test 実行時に vscode-ftester ルート(i18n.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

import { FTESTER_PROTOCOL_VERSION } from "../src/protocolVersion";

const ROOT = process.cwd();

test("プロトコル版: Sources/FTCore/ProtocolVersion.swift と src/protocolVersion.ts が一致する", () => {
  const swiftPath = path.join(ROOT, "..", "Sources", "FTCore", "ProtocolVersion.swift");
  const swiftSource = readFileSync(swiftPath, "utf8");
  const match = swiftSource.match(/ftesterProtocolVersion\s*=\s*(\d+)/);
  assert.ok(match, `${swiftPath} から ftesterProtocolVersion を抽出できませんでした`);
  const swiftVersion = Number(match[1]);

  assert.equal(
    swiftVersion,
    FTESTER_PROTOCOL_VERSION,
    "Sources/FTCore/ProtocolVersion.swift と vscode-ftester/src/protocolVersion.ts の" +
      ` プロトコル版がズレています(swift: ${swiftVersion}, ts: ${FTESTER_PROTOCOL_VERSION})。` +
      "両方を同じ値に更新してください。",
  );
});
