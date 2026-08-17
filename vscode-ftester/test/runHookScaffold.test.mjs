// runHookScaffold.test.mjs
// 「スクリプトの雛形を作成する」の置き場所計算と書き出し(src/runHookScaffold.ts)。
// 実行規則の正は Sources/FTCore/RunHooks.swift 側(こちらは置き場所と中身だけ)。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { after, test } from "node:test";
import {
  hookScriptTemplates,
  resolveWorkspaceDir,
  writeHookScriptTemplates,
} from "../src/runHookScaffold.ts";
import { hookScaffoldStrings } from "../src/i18n/strings/hookScaffold.ts";

const tempRoots = [];
function tempDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ftester-hook-scaffold-"));
  tempRoots.push(dir);
  return dir;
}
after(() => {
  for (const dir of tempRoots) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("雛形の中身は locale に追従する(日本語モードなら日本語コメント)", () => {
  // 既定 locale は "ja"(initI18n を呼ばないテストの前提。src/i18n/index.ts)
  const templates = hookScriptTemplates();
  assert.match(templates.get("setup.sh"), /テスト実行の前に/);
  assert.match(templates.get("teardown.sh"), /テスト実行の後に/);
  // en 側は locale を切り替えず辞書を直接見る(locale の差し替え口を production に足さない)
  assert.match(hookScaffoldStrings["hookScaffold.setupTemplate"].en, /Runs before the scenarios/);
  assert.match(hookScaffoldStrings["hookScaffold.teardownTemplate"].en, /Runs after the scenarios/);
});

test("resolveWorkspaceDir: 未指定なら TestProjects/<project>/workspace(透かしと同じ既定)", () => {
  assert.equal(
    resolveWorkspaceDir("/repo", "sut-ec-mobile", ""),
    path.join("/repo", "TestProjects", "sut-ec-mobile", "workspace"),
  );
  assert.equal(
    resolveWorkspaceDir("/repo", "sut-ec-mobile", "   "),
    path.join("/repo", "TestProjects", "sut-ec-mobile", "workspace"),
  );
});

test("resolveWorkspaceDir: 相対はリポジトリルート基準、絶対はそのまま", () => {
  assert.equal(resolveWorkspaceDir("/repo", "p", "../shared-ws"), "/shared-ws");
  assert.equal(resolveWorkspaceDir("/repo", "p", "  ws  "), "/repo/ws");
  assert.equal(resolveWorkspaceDir("/repo", "p", "/Volumes/shared/ws"), "/Volumes/shared/ws");
});

test("writeHookScriptTemplates: scripts/ を作って2本を実行権付きで書く", () => {
  const workspace = path.join(tempDir(), "workspace");
  const result = writeHookScriptTemplates(workspace);

  assert.deepEqual([...result.created].sort(), ["setup.sh", "teardown.sh"]);
  assert.deepEqual(result.skipped, []);
  assert.equal(result.scriptsDir, path.join(workspace, "scripts"));
  for (const name of ["setup.sh", "teardown.sh"]) {
    const file = path.join(result.scriptsDir, name);
    const content = fs.readFileSync(file, "utf8");
    assert.match(content, /^#!\/bin\/sh\n/);
    // 使い方(環境変数と実行規則)がファイル内に書かれていること
    assert.match(content, /FT_WORKSPACE/);
    assert.match(content, /FT_HOOK/);
    // 実行権(雛形は shebang 付きなので直接実行できる形で置く)
    assert.equal(fs.statSync(file).mode & 0o111, 0o111);
  }
  // 例のコマンドは言語に依らず同じ(文言だけが locale で変わる)
  assert.match(fs.readFileSync(path.join(result.scriptsDir, "setup.sh"), "utf8"), /docker compose/);
  assert.match(fs.readFileSync(path.join(result.scriptsDir, "teardown.sh"), "utf8"), /set -u/);
});

test("雛形は ja/en どちらも sh として構文が通る(コメントの書き足しで壊さない)", () => {
  const dir = tempDir();
  for (const [key, entry] of Object.entries(hookScaffoldStrings)) {
    for (const [locale, body] of Object.entries(entry)) {
      const file = path.join(dir, `${key}.${locale}.sh`);
      fs.writeFileSync(file, body, "utf8");
      // -n = 実行せず構文検査だけ。落ちれば非0で throw する
      execFileSync("/bin/sh", ["-n", file]);
    }
  }
});

test("writeHookScriptTemplates: 既にあるファイルは1バイトも触らない", () => {
  const workspace = path.join(tempDir(), "workspace");
  const scriptsDir = path.join(workspace, "scripts");
  fs.mkdirSync(scriptsDir, { recursive: true });
  const mine = "#!/bin/sh\necho mine\n";
  fs.writeFileSync(path.join(scriptsDir, "setup.sh"), mine, "utf8");

  const result = writeHookScriptTemplates(workspace);

  assert.deepEqual(result.skipped, ["setup.sh"]);
  assert.deepEqual(result.created, ["teardown.sh"]);
  // 利用者が書いた片付け手順を雛形で潰すと、次の run が古い環境を掴んだまま走る
  assert.equal(fs.readFileSync(path.join(scriptsDir, "setup.sh"), "utf8"), mine);
});

test("hookScriptTemplates: ファイル名は FTCore.RunHook.Kind.script と同じ2本だけ", () => {
  assert.deepEqual([...hookScriptTemplates().keys()], ["setup.sh", "teardown.sh"]);
});
