// ステップ status 語彙のドリフト検出。Swift 側の真実(Sources/FTCore/ScenarioEvent.swift の
// StepResult.Status.eventStatus が返す文字列)と、拡張側の StepStatus union が一致することを確認する。
//
// ズレると: Swift に status を足しても拡張は未知の値として素通しし、アイコンも集計も付かないまま
// 「表示されないが失敗もしない」状態になる(NDJSON は前方互換なので落ちない = 気付けない)。
// protocolVersion.test.mjs と同じ方式(Swift はソースを正規表現で読む)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();

/** eventStatus の `return ("<status>", ...)` から status 文字列を集める */
function swiftEventStatuses() {
  const source = readFileSync(
    path.join(ROOT, "..", "Sources", "FTCore", "ScenarioEvent.swift"),
    "utf8",
  );
  const start = source.indexOf("var eventStatus:");
  assert.ok(start >= 0, "ScenarioEvent.swift に eventStatus が見つかりません");
  const body = source.slice(start);
  const found = [...body.matchAll(/return \("([a-zA-Z]+)"/g)].map((m) => m[1]);
  assert.ok(found.length > 0, "eventStatus から status 文字列を抽出できませんでした");
  return new Set(found);
}

/** model.ts の `export type StepStatus = "a" | "b" | ...` を読む */
function typescriptStepStatuses() {
  const source = readFileSync(path.join(ROOT, "src", "model.ts"), "utf8");
  const match = source.match(/export type StepStatus\s*=\s*([^;]+);/);
  assert.ok(match, "model.ts から StepStatus を抽出できませんでした");
  const found = [...match[1].matchAll(/"([a-zA-Z]+)"/g)].map((m) => m[1]);
  assert.ok(found.length > 0, "StepStatus の値を抽出できませんでした");
  return new Set(found);
}

test("step status 語彙: Swift の eventStatus と拡張の StepStatus が一致する", () => {
  const swift = swiftEventStatuses();
  const typescript = typescriptStepStatuses();

  const missingInTS = [...swift].filter((s) => !typescript.has(s)).sort();
  const missingInSwift = [...typescript].filter((s) => !swift.has(s)).sort();

  assert.deepEqual(
    { missingInTS, missingInSwift },
    { missingInTS: [], missingInSwift: [] },
    "ステップ status の語彙がズレています" +
      `(拡張に無い: ${missingInTS.join(", ") || "なし"} /` +
      ` Swift に無い: ${missingInSwift.join(", ") || "なし"})。` +
      "Sources/FTCore/ScenarioEvent.swift の eventStatus と vscode-ftester/src/model.ts の" +
      " StepStatus を同時に更新してください(拡張側はアイコン・集計の分岐も要追加)。",
  );
});
