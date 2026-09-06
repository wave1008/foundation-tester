// install.sh の `git pull` 失敗の仕分け契約。
//
// 事故の形(2026-09-07 に受け手の外部構成で実測): `origin/main` が force-push で作り直された
// 後のクローンは非 fast-forward になり、pull 失敗が warn 止まりで続行していた。旧コードを
// 建て直し、旧拡張を入れ直し、`✅ 8 件 / exit 2` で「The CLI and MCP still work」と締める ——
// **受け手には更新できていないことが伝わらない**。405 遅れ / 109 進みのクローンが
// ブリッジ版 79 のまま「更新成功」に見えた。
//
// 守る契約は3つ。**分岐だけを特別扱いする**(他の2つを巻き込むと運用が壊れる):
//   オフライン(fetch 不通) … warn のまま。手元のクローンでの作業を止めない
//   ローカルが先行のみ     … 失敗ではない。保守者が手元にコミットを持つ通常の状態
//   分岐(遅れ かつ 進み)   … 外部構成は上流へ reset して復旧 / それ以外は die(続行しない)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const INSTALL_SH = path.join(process.cwd(), "..", "Scripts/install.sh");

/** `pull --ff-only` の if から、対応する `fi` までを取り出す(実装の写しを置かない)。 */
function pullBlock() {
  const source = readFileSync(INSTALL_SH, "utf8");
  const start = source.indexOf('if git -C "$TOOL_ROOT" pull --ff-only');
  assert.ok(start > 0, "install.sh に pull --ff-only の分岐が無い(走査の前提が崩れた)");
  const end = source.indexOf("\n    fi", start);
  assert.ok(end > start, "pull --ff-only の分岐の終端が見つからない");
  return source.slice(start, end);
}

test("分岐したクローンは warn で素通ししない(die か reset で必ず決着する)", () => {
  const block = pullBlock();
  assert.ok(
    !/diverged[^\n]*soft_fail|soft_fail[^\n]*diverged/.test(block),
    "分岐を soft_fail で流している(旧コードを建て直して『更新成功』に見える)",
  );
  assert.match(block, /reset --hard "origin\/\$branch"/, "外部構成での復旧が無い");
  assert.match(block, /die "clone"/, "復旧できない構成での中止が無い");
});

test("オフライン(fetch 不通)は warn のまま — 手元での作業を止めない", () => {
  const block = pullBlock();
  assert.match(block, /! git -C "\$TOOL_ROOT" fetch origin "\$branch"/, "fetch で切り分けていない");
  const offline = block.slice(block.indexOf("fetch origin"), block.indexOf("else\n"));
  assert.match(offline, /soft_fail "clone"/, "オフラインを warn より重く扱っている");
});

test("ローカルが先行しているだけなら失敗にしない(保守者の運用を壊さない)", () => {
  const block = pullBlock();
  assert.match(block, /behind=/, "遅れの件数を見ていない");
  assert.match(block, /ahead=/, "進みの件数を見ていない");
  assert.match(
    block,
    /if \[ "\$behind" = "0" \]; then\s*\n\s*record "clone" skip/,
    "behind=0(先行のみ)を失敗にしている",
  );
});

test("ローカル変更の破棄と分岐からの復旧は同じ条件を使う(片方だけ緩めない)", () => {
  const source = readFileSync(INSTALL_SH, "utf8");
  assert.match(source, /clone_is_disposable\(\) \{/, "条件が関数に括り出されていない");
  const uses = source.match(/clone_is_disposable\b/g) ?? [];
  // 定義 1 + settle_local_changes 1 + 分岐からの復旧 1
  assert.equal(uses.length, 3, `clone_is_disposable の参照数が想定と違う: ${uses.length}`);
  assert.ok(
    !/\[ "\$WORK_DIR" != "\$TOOL_ROOT" \] && \[ "\$KEEP_LOCAL" = "0" \]\s*\n?\s*&&/.test(source),
    "条件の直書きが残っている(clone_is_disposable を通すこと)",
  );
});
