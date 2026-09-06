// install.sh ステップ7.5(.mcp.json の生成・マージ)と Scripts/mcp-server.sh の起動契約。
//
//   1. 登録は `bash -c "exec <abs>/Scripts/mcp-server.sh"`。**`-l` を付けない** —— ログインシェルは
//      ~/.bash_profile を読むので、そこの `echo` 1 つが JSON-RPC より前に stdout へ混ざり
//      ハンドシェイクが壊れる。
//   2. `-l` が担っていた PATH(swift / xcrun / Homebrew)は mcp-server.sh 自身が、ビルドや exec より
//      前に補う。
//   3. 既存の .mcp.json の他サーバは残す(マージ)。TOOL_ROOT が変わったら REPLACED を報告する。
//
// install.sh の python ヒアドキュメントを抜き出してそのまま実行する(実装の写しを置かない)。

import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const INSTALL_SH = path.join(ROOT, "Scripts/install.sh");
const MCP_SERVER_SH = path.join(ROOT, "Scripts/mcp-server.sh");
const PATH_EXPORT = 'export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"';

function mergeScript() {
  const source = readFileSync(INSTALL_SH, "utf8");
  const begin = source.indexOf("<<'PYCLAUDE'\n");
  assert.ok(begin > 0, "install.sh に PYCLAUDE ヒアドキュメントが無い(ステップ7.5 が消えた?)");
  const body = source.slice(begin + "<<'PYCLAUDE'\n".length);
  const end = body.indexOf("\nPYCLAUDE\n");
  assert.ok(end > 0, "PYCLAUDE ヒアドキュメントの終端が見つからない");
  return body.slice(0, end);
}

/** 初期内容(null = ファイル無し)に対してマージを 1 回流す。 */
function merge(initial, toolRoot) {
  const dir = mkdtempSync(path.join(tmpdir(), "ft-mcp-json-"));
  try {
    const script = path.join(dir, "merge.py");
    writeFileSync(script, mergeScript());
    const target = path.join(dir, ".mcp.json");
    if (initial !== null) writeFileSync(target, initial);
    const out = execFileSync("python3", [script, target, toolRoot], { encoding: "utf8" });
    return { out, json: existsSync(target) ? JSON.parse(readFileSync(target, "utf8")) : null };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test(".mcp.json は bash -c(ログインシェルでない)で mcp-server.sh を絶対パスで exec する", () => {
  const root = "/Users/someone/dev/foundation-tester";
  const { out, json } = merge(null, root);
  assert.equal(out, "OK");
  const entry = json.mcpServers.fleetest;
  assert.equal(entry.command, "bash");
  assert.deepEqual(entry.args, ["-c", `exec "${root}/Scripts/mcp-server.sh"`]);
  assert.ok(!entry.args.some((a) => /^-\w*l/.test(a)), `-l(ログインシェル)が混ざっている: ${entry.args}`);
  assert.deepEqual(entry.env, { FT_TOOL_ROOT: root });
});

test("既存の他サーバは残し、TOOL_ROOT の差し替えは REPLACED で報告する", () => {
  const initial = JSON.stringify({
    mcpServers: {
      other: { command: "node", args: ["x.js"] },
      fleetest: { command: "bash", args: ["-lc", 'exec "/old/root/Scripts/mcp-server.sh"'], env: { FT_TOOL_ROOT: "/old/root" } },
    },
  });
  const { out, json } = merge(initial, "/new/root");
  assert.equal(out, "REPLACED /old/root");
  assert.deepEqual(json.mcpServers.other, { command: "node", args: ["x.js"] });
  assert.deepEqual(json.mcpServers.fleetest.args, ["-c", 'exec "/new/root/Scripts/mcp-server.sh"']);
});

test("mcp-server.sh は PATH の補正をビルド・exec より前に置く(-l を外した代わり)", () => {
  const lines = readFileSync(MCP_SERVER_SH, "utf8").split("\n");
  const code = (re) => lines.findIndex((l) => !l.trim().startsWith("#") && re.test(l));
  const exportAt = code(/^\s*export PATH=/);
  assert.ok(exportAt >= 0, `mcp-server.sh に ${PATH_EXPORT} が無い`);
  assert.equal(lines[exportAt].trim(), PATH_EXPORT, "PATH の補正は RemoteDispatch の非対話 ssh と同じ形にする");
  const buildAt = code(/swift build/);
  const execAt = code(/^\s*exec "\$BIN"/);
  assert.ok(buildAt > exportAt, "swift build が PATH の補正より前にある");
  assert.ok(execAt > exportAt, 'exec "$BIN" が PATH の補正より前にある');
});

test("生成した args で起動すると ~/.bash_profile の出力が stdout に混ざらない(-lc なら混ざる)", () => {
  const dir = mkdtempSync(path.join(tmpdir(), "ft-mcp-launch-"));
  try {
    const home = path.join(dir, "home");
    mkdirSync(home);
    writeFileSync(path.join(home, ".bash_profile"), "echo PROFILE-NOISE\n");
    const root = path.join(dir, "tool-root");
    mkdirSync(path.join(root, "Scripts"), { recursive: true });
    const stub = path.join(root, "Scripts/mcp-server.sh");
    writeFileSync(stub, "#!/bin/bash\necho SERVER-STDOUT\n");
    execFileSync("chmod", ["+x", stub]);
    const { json } = merge(null, root);
    const env = { ...process.env, HOME: home };
    const real = spawnSync(json.mcpServers.fleetest.command, json.mcpServers.fleetest.args, { encoding: "utf8", env });
    assert.equal(real.stdout, "SERVER-STDOUT\n", `stdout に JSON-RPC 以外が混ざる: ${JSON.stringify(real.stdout)}`);
    // 陽性対照: -lc なら同じ環境で確かに混ざる(この witness が差を出せることの確認)
    const login = spawnSync("bash", ["-lc", json.mcpServers.fleetest.args[1]], { encoding: "utf8", env });
    assert.match(login.stdout, /PROFILE-NOISE/, "-lc でも混ざらない = この witness は差を出せていない");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
