// defaultProject.test.mjs
// 起動時の既定プロジェクト用意(src/defaultProject.ts)。判定(present/missing)と、無いときだけ
// CLI(`project create default`)を叩く配線。相手は test/fixtures/mock-project-create.mjs
// (cli.test.mjs と同じく node <fixture> として spawn する)。
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { FleetestCli } from "../src/cli";
import { defaultProjectState, ensureDefaultProject } from "../src/defaultProject";

const MOCK = path.resolve(process.cwd(), "test", "fixtures", "mock-project-create.mjs");

function makeWorkspace() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-default-project-"));
  fs.mkdirSync(path.join(root, "TestProjects"));
  return root;
}

/** binaryPath=node・args 先頭にフィクスチャを置くため invoke をラップする(cli.ts の契約は変えない)。 */
function makeCli(lines, env) {
  const cli = new FleetestCli({ appendLine: (line) => lines.push(line) });
  return {
    invocations: [],
    invoke(binaryPath, cwd, invocation) {
      this.invocations.push(invocation.args);
      const saved = process.env.MOCK_PROJECT_CREATE_FAIL;
      if (env?.fail) {
        process.env.MOCK_PROJECT_CREATE_FAIL = "1";
      }
      try {
        return cli.invoke(process.execPath, cwd, { ...invocation, args: [MOCK, ...invocation.args] });
      } finally {
        if (saved === undefined) {
          delete process.env.MOCK_PROJECT_CREATE_FAIL;
        } else {
          process.env.MOCK_PROJECT_CREATE_FAIL = saved;
        }
      }
    },
  };
}

test("defaultProjectState: 無い・空・.DS_Store だけ = missing / 中身があれば present", (t) => {
  const root = makeWorkspace();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const dir = path.join(root, "TestProjects", "default");
  assert.equal(defaultProjectState(root), "missing");
  fs.mkdirSync(dir);
  assert.equal(defaultProjectState(root), "missing");
  fs.writeFileSync(path.join(dir, ".DS_Store"), "");
  assert.equal(defaultProjectState(root), "missing");
  fs.mkdirSync(path.join(dir, "scenarios"));
  assert.equal(defaultProjectState(root), "present");
});

test("ensureDefaultProject: 無ければ project create default を叩き、雛形ができれば created", async (t) => {
  const root = makeWorkspace();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const lines = [];
  const logged = [];
  const cli = makeCli(lines);
  const outcome = await ensureDefaultProject({
    workspaceRoot: root, binaryPath: "unused", cli, log: (line) => logged.push(line),
  });
  assert.deepEqual(outcome, { kind: "created" });
  assert.deepEqual(cli.invocations, [["project", "create", "default"]]);
  assert.ok(fs.existsSync(path.join(root, "TestProjects", "default", "scenarios", "_Main.swift")));
  assert.ok(logged.some((line) => line.includes("Created the project")), "stdout の文が log へ流れる");
  assert.ok(!lines.some((line) => line.includes("JSON")), "JSON.parse 失敗の行を出力パネルに残さない");
});

test("ensureDefaultProject: 既にあれば spawn しない", async (t) => {
  const root = makeWorkspace();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, "TestProjects", "default", "scenarios"), { recursive: true });
  const cli = makeCli([]);
  const outcome = await ensureDefaultProject({
    workspaceRoot: root, binaryPath: "unused", cli, log: () => undefined,
  });
  assert.deepEqual(outcome, { kind: "present" });
  assert.deepEqual(cli.invocations, []);
});

test("ensureDefaultProject: CLI が非 0 で終われば failed に stderr の末尾を載せる", async (t) => {
  const root = makeWorkspace();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const cli = makeCli([], { fail: true });
  const outcome = await ensureDefaultProject({
    workspaceRoot: root, binaryPath: "unused", cli, log: () => undefined,
  });
  assert.equal(outcome.kind, "failed");
  assert.match(outcome.detail, /already exists/);
  assert.equal(defaultProjectState(root), "missing");
});
