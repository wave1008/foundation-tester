// 信頼していないフォルダで拡張を動かさないことの固定。
//
// 塞いでいる穴: `fleetest.binaryPath` は受け手のセットアップ(FTCore の ProjectScaffold /
// InitCommand)が `.vscode/settings.json` へ書くため **window スコープのままにするしかない**。
// つまり開いたフォルダが実行ファイルの場所を決められ、activate 直後の checkFleetestCompat
// (src/extension.ts)がそれを spawn する。境界は VSCode の Workspace Trust しかないので、
// 宣言を暗黙の既定に委ねず package.json に明示し、消えたらここで落とす。
//
// **scope を "machine" にして直そうとしないこと** —— 受け手の `.vscode/settings.json` が
// 無視され、セットアップ直後の拡張が CLI を見つけられなくなる。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = process.cwd();
const pkg = JSON.parse(readFileSync(path.join(ROOT, "package.json"), "utf8"));

test("Workspace Trust: 信頼していないフォルダでは動かないことを宣言している", () => {
  const declared = pkg.capabilities?.untrustedWorkspaces;
  assert.ok(declared, "package.json の capabilities.untrustedWorkspaces が無い");
  assert.equal(declared.supported, false);
  assert.match(declared.description ?? "", /^%[\w.]+%$/, "説明は package.nls 参照で持つ");
});

test("fleetest.binaryPath は window スコープのまま(受け手のワークスペース設定が効く必要がある)", () => {
  const binaryPath = pkg.contributes.configuration.properties["fleetest.binaryPath"];
  assert.ok(binaryPath, "fleetest.binaryPath の宣言が無い");
  assert.equal(
    binaryPath.scope,
    undefined,
    "machine にすると受け手の .vscode/settings.json が無視される(ファイル冒頭の注記を読むこと)",
  );
});
