// マシンの健全性の「OCR 注記」「Vision 注記」列が数える注記の集合を、Swift の集計(MachineHealthNotes)と
// webview(machineHealth.js の OCR_NOTES / VISION_NOTES)で突き合わせる。JSON の notes のキーは StepNote の
// rawValue("ocr-budget-exhausted")で case 名ではない —— case 名で書いた表はテストごと緑のまま常に 0 を出した。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..", "..");
const read = (rel) => readFileSync(path.join(repo, rel), "utf8");

function stepNoteRawValues() {
  const source = read("Sources/FTCore/StepNote.swift");
  const map = new Map();
  for (const m of source.matchAll(/case\s+(\w+)\s*=\s*"([^"]+)"/g)) {
    map.set(m[1], m[2]);
  }
  return map;
}

function swiftGroup(name) {
  const source = read("Sources/FTCore/RunResultsQuery+MachineHealth.swift");
  const m = source.match(new RegExp(`static let ${name}: Set<StepNote> = \\[([^\\]]*)\\]`));
  assert.ok(m, `MachineHealthNotes.${name} が見つからない`);
  const raw = stepNoteRawValues();
  return [...m[1].matchAll(/\.(\w+)/g)].map((c) => {
    assert.ok(raw.has(c[1]), `StepNote.${c[1]} の rawValue が見つからない`);
    return raw.get(c[1]);
  }).sort();
}

function jsGroup(name) {
  const source = read("vscode-fleetest/src/webview/dashboard/machineHealth.js");
  const m = source.match(new RegExp(`const ${name} = \\{([^}]*)\\}`));
  assert.ok(m, `${name} が見つからない`);
  return [...m[1].matchAll(/^\s*'([^']+)':/gm)].map((c) => c[1]).sort();
}

test("OCR 注記の集合が Swift と webview で一致する(rawValue で)", () => {
  const swift = swiftGroup("ocr");
  assert.ok(swift.length > 0);
  assert.deepEqual(jsGroup("OCR_NOTES"), swift);
});

test("Vision 注記の集合が Swift と webview で一致する(rawValue で)", () => {
  const swift = swiftGroup("vision");
  assert.ok(swift.length > 0);
  assert.deepEqual(jsGroup("VISION_NOTES"), swift);
});
