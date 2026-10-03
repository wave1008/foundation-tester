// install.sh ステップ7(拡張の表示言語 fleetest.language を OS の言語から決める)の契約。
//
//   1. OS が ja 系なら ja、それ以外・不明なら en
//   2. settings.json が無ければ作る
//   3. JSONC(コメント・末尾カンマ)の書式を保って差し込む。空の {} にはカンマを付けない
//   4. キーが既にあれば1バイトも書かない(受け手の選択を update.sh で上書きしない)
//   5. 値やコメントに同じ文字列があってもキーとは数えない
//   6. 2周目は何も変えない(冪等)
//
// install.sh の関数本体を抜き出してそのまま実行する(実装の写しを置かない)。

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const INSTALL_SH = readFileSync(path.join(ROOT, "Scripts/install.sh"), "utf8");

function snippet() {
  const begin = INSTALL_SH.indexOf("apply_extension_language() {");
  assert.ok(begin > 0, "install.sh に apply_extension_language() がありません");
  const end = INSTALL_SH.indexOf("\n}\n", begin);
  return INSTALL_SH.slice(begin, end + 3);
}

function run(settings, osLang) {
  const out = execFileSync("bash", ["-c", `${snippet()}\napply_extension_language "$1" "$2"`, "x", settings, osLang], {
    encoding: "utf8",
  });
  return out.trim();
}

function withDir(fn) {
  const dir = mkdtempSync(path.join(tmpdir(), "ft-ext-lang-"));
  try {
    fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/** VSCode の settings.json と同じく JSONC として読む(コメントと末尾カンマを落としてから JSON.parse) */
function parseJsonc(text) {
  const noComments = text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|\s)\/\/[^\n]*/g, "$1");
  return JSON.parse(noComments.replace(/,(\s*[}\]])/g, "$1"));
}

test("OS が ja 系なら ja・それ以外と不明は en。無ければ作る", () => {
  for (const [osLang, want] of [["ja-JP", "ja"], ["ja", "ja"], ["en-US", "en"], ["fr-FR", "en"], ["", "en"]]) {
    withDir((dir) => {
      const settings = path.join(dir, "User/settings.json");
      const out = run(settings, osLang);
      assert.ok(out.startsWith("ok|"), out);
      assert.equal(parseJsonc(readFileSync(settings, "utf8"))["fleetest.language"], want, osLang);
    });
  }
});

test("JSONC の書式を保って差し込む・空の {} にはカンマを付けない", () => {
  withDir((dir) => {
    const settings = path.join(dir, "settings.json");
    const original = '// my settings {\n{\n  /* keep */\n  "editor.fontSize": 14, // trailing\n  "x": "fleetest.language",\n}\n';
    writeFileSync(settings, original);
    assert.ok(run(settings, "ja-JP").startsWith("ok|"));
    const after = readFileSync(settings, "utf8");
    assert.equal(after.replace('\n    "fleetest.language": "ja",', ""), original, "元の内容が変わった");
    const parsed = parseJsonc(after);
    assert.equal(parsed["fleetest.language"], "ja");
    assert.equal(parsed["editor.fontSize"], 14);

    writeFileSync(settings, "{}\n");
    run(settings, "en-US");
    assert.equal(readFileSync(settings, "utf8"), '{\n    "fleetest.language": "en"}\n');
  });
});

test("キーが既にあれば書かない(2周目も含む)", () => {
  withDir((dir) => {
    const settings = path.join(dir, "settings.json");
    const original = '{\n  "fleetest.language" : "auto"\n}\n';
    writeFileSync(settings, original);
    assert.ok(run(settings, "ja-JP").startsWith("skip|"));
    assert.equal(readFileSync(settings, "utf8"), original);

    rmSync(settings);
    run(settings, "ja-JP");
    const first = readFileSync(settings, "utf8");
    assert.ok(run(settings, "en-US").startsWith("skip|"));
    assert.equal(readFileSync(settings, "utf8"), first);
  });
});

test("読めない形なら書かずに warn", () => {
  withDir((dir) => {
    const settings = path.join(dir, "settings.json");
    writeFileSync(settings, "[1]\n");
    assert.ok(run(settings, "ja-JP").startsWith("warn|"));
    assert.equal(readFileSync(settings, "utf8"), "[1]\n");
    assert.ok(existsSync(settings));
  });
});

test("AppleLanguages の第一言語を取り出せる", () => {
  const line = INSTALL_SH.split("\n").find((l) => l.includes("defaults read -g AppleLanguages"));
  assert.ok(line, "install.sh が AppleLanguages を読んでいません");
  const sed = line.match(/\| (sed .*?) \| awk 'NR==1'\)/)[1];
  for (const [input, want] of [['(\n    "ja-JP",\n    "en-US"\n)\n', "ja-JP"], ["(\n    en,\n    ja\n)\n", "en"]]) {
    const out = execFileSync("bash", ["-c", `${sed} | awk 'NR==1'`], { input, encoding: "utf8" }).trim();
    assert.equal(out, want);
  }
});
