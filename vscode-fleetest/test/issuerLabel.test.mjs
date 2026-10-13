// issuerLabel.test.mjs
// 占有の持ち主の表示名(src/issuerLabel.ts)。`USER@hostname` の hostname をマシン名へ読み替える。

import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { issuerDisplayName, readIssuerAliases } from "../src/issuerLabel";

test("hostname がマシン名の付いた機械なら USER@マシン名(大小と .local は揃えて照合)", () => {
  const aliases = new Map([["ldipc95", "M1Ultra"]]);
  assert.equal(issuerDisplayName("wave1008@ldipc95.local", aliases), "wave1008@M1Ultra");
  assert.equal(issuerDisplayName("wave1008@LDIPC95", aliases), "wave1008@M1Ultra");
});

test("表に無い hostname・@ を持たない明示の issuerId はそのまま", () => {
  const aliases = new Map([["ldipc95", "M1Ultra"]]);
  assert.equal(issuerDisplayName("bob@other-mac.local", aliases), "bob@other-mac.local");
  assert.equal(issuerDisplayName("ci-runner", aliases), "ci-runner");
  assert.equal(issuerDisplayName("trailing@", aliases), "trailing@");
});

test("remote-hosts の host / machineAlias から表を作る(同じ機械は local を優先・壊れたファイルは飛ばす)", (t) => {
  const root = mkdtempSync(path.join(tmpdir(), "issuer-label-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const dir = path.join(root, ".fleetest", "remote-hosts");
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, "192.168.20.95.json"), JSON.stringify({ host: "LDIPC95", machineAlias: "M1Ultra" }));
  writeFileSync(path.join(dir, "a.json"), JSON.stringify({ host: "LDIPC96", machineAlias: "other" }));
  writeFileSync(path.join(dir, "b.json"), JSON.stringify({ host: "LDIPC96", machineAlias: "local" }));
  writeFileSync(path.join(dir, "broken.json"), "{");
  writeFileSync(path.join(dir, "noalias.json"), JSON.stringify({ host: "X" }));
  const aliases = readIssuerAliases(root);
  assert.deepEqual([...aliases].sort(), [["ldipc95", "M1Ultra"], ["ldipc96", "local"]]);
  assert.equal(readIssuerAliases(path.join(root, "missing")).size, 0, "ディレクトリが無ければ空");
});
