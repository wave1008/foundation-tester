// エージェント配布アダプタ(Claude Code)の整合検証。
// 契約(docs/design.md §15): **runbook 本体は複製しない**。正典は .claude/skills/ の1箇所で、
// そこへは「規約位置から正典を参照する薄いアダプタ」だけを置く:
//   Claude Code → .claude-plugin/plugin.json + .claude-plugin/marketplace.json
// 他のエージェント(Codex 等)向けの配布アダプタは置かない —— 正典の SKILL.md は
// ツール中立の markdown なので、そのまま読ませる(docs/user-docs/tools/other_agents.md)。
// スキルの呼び出し名は SKILL.md frontmatter の name から決まるため、ディレクトリ名との一致も見る。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, readFileSync, readdirSync, realpathSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");

test("plugin.json / marketplace.json が有効な JSON で相互整合している", () => {
  const plugin = JSON.parse(readFileSync(path.join(ROOT, ".claude-plugin", "plugin.json"), "utf8"));
  const marketplace = JSON.parse(
    readFileSync(path.join(ROOT, ".claude-plugin", "marketplace.json"), "utf8"),
  );

  assert.equal(typeof plugin.name, "string");
  assert.ok(plugin.name.length > 0);
  const entry = marketplace.plugins?.find((p) => p.name === plugin.name);
  assert.ok(entry, `marketplace.json に plugin "${plugin.name}" のエントリがありません`);
  assert.equal(entry.source, "./", "source はリポジトリルート(skills パス置換の前提)");
});

test("plugin.json の skills パスが正典 .claude/skills/ を指し、各スキルが有効", () => {
  const plugin = JSON.parse(readFileSync(path.join(ROOT, ".claude-plugin", "plugin.json"), "utf8"));
  assert.equal(plugin.skills, "./.claude/skills/", "skills は正典 .claude/skills/ の参照(複製禁止)");

  const skillsDir = path.join(ROOT, ".claude", "skills");
  const dirs = readdirSync(skillsDir, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);
  assert.ok(dirs.length >= 4, `スキルが少なすぎます: ${dirs.join(", ")}`);

  for (const dir of dirs) {
    const skillPath = path.join(skillsDir, dir, "SKILL.md");
    assert.ok(existsSync(skillPath), `${dir}/SKILL.md がありません`);
    const src = readFileSync(skillPath, "utf8");
    const name = src.match(/^---\n(?:.*\n)*?name:\s*(\S+)\s*\n/)?.[1];
    assert.equal(
      name,
      dir,
      `${dir}/SKILL.md の frontmatter name がディレクトリ名と不一致(呼び出し名は name から決まる)`,
    );
  }
});

// **repo ルートに `skills` を置いてはいけない**(2026-08-27 に実測して撤去)。
// プラグイン root = repo ルートのとき、Claude Code は `.claude-plugin/plugin.json` の明示パス
// `./.claude/skills/` と**既定の `skills/`** の両方を読む(置換ではなく加算)。ルートに
// `skills → .claude/skills` のリンクを置いていた間は **6本が12本として登録**され、
// 常時コストが倍(~1,270 → ~2,537 tok)になっていた。`claude plugin details` で確認できる。
test("repo ルートに skills を置かない(Claude 側で二重登録になる)", () => {
  assert.ok(
    !existsSync(path.join(ROOT, "skills")),
    "repo ルートの skills は Claude Code の既定スキャンに拾われ、スキルが二重登録される",
  );
});

// 同型の2件目。repo ルートの `.mcp.json` は**プラグインに載って配られ**、中身が
// `$PWD/Scripts/mcp-server.sh` 依存なのでクローンの外では必ず落ちる(2026-08-27 実測:
// `plugin details` に `MCP servers (1)`)。登録は構成を問わず install.sh が絶対パスで
// WORK_DIR へ書く。
test("repo ルートに .mcp.json を置かない(プラグインに載って受け手の MCP が落ちる)", () => {
  assert.ok(
    !execFileSync("git", ["ls-files", ".mcp.json"], { cwd: ROOT, encoding: "utf8" }).trim(),
    "repo ルートの .mcp.json はプラグインに載って配られる($PWD 依存でクローンの外では起動しない)",
  );
});

test("install.sh は構成を問わず .mcp.json を書く(clone 構成を同梱ファイルに頼らない)", () => {
  const sh = readFileSync(path.join(ROOT, "Scripts/install.sh"), "utf8");
  assert.ok(
    !/bundled \.mcp\.json/.test(sh),
    "clone 構成で .mcp.json の生成をスキップしている(同梱ファイルはもう存在しない)",
  );
});

test("install-skill.sh は正典(実体)から取得する — リンク越しに取ると本文が返らない", () => {
  const sh = readFileSync(path.join(ROOT, "Scripts/install-skill.sh"), "utf8");
  // raw.githubusercontent はシンボリックリンクをリンク先の文字列として返すので、
  // 取得元をリンクのディレクトリにすると SKILL.md ではなく1行のパスが降ってくる
  assert.ok(
    sh.includes("/.claude/skills"),
    "install-skill.sh の取得元が正典 .claude/skills/ ではありません",
  );
  // 他のエージェント向けの置き先は --dir で受ける(規約位置を手で持たない)
  assert.match(sh, /--dir\)/, "install-skill.sh に --dir(他エージェント向けの置き先)がありません");
});

test("アダプタがリポジトリを指すシンボリックリンクのループを作らない", () => {
  // **repo 自身を指すリンクを repo の中に置かない**。design.md §15 のとおり
  // `claude plugin marketplace add <ローカルパス>` は**作業ツリーを丸ごとコピー**するので、
  // リンクを辿るコピーが終わらなくなる(実測: cp -RL が5秒で 18 階層・389MB まで掘った)。
  const repo = realpathSync(ROOT);
  const suspects = [];
  const walk = (dir, depth) => {
    if (depth > 3) return;
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === "node_modules" || entry.name === ".build" || entry.name === ".git") continue;
      const full = path.join(dir, entry.name);
      if (entry.isSymbolicLink()) {
        let target;
        try {
          target = realpathSync(full);
        } catch {
          continue; // 壊れたリンクは別テストの担当
        }
        // repo ルート自身、または自分の祖先を指すリンクはループになる
        if (target === repo || full.startsWith(target + path.sep)) {
          suspects.push(path.relative(repo, full));
        }
      } else if (entry.isDirectory()) {
        walk(full, depth + 1);
      }
    }
  };
  walk(ROOT, 0);
  assert.deepEqual(suspects, [], `リポジトリ自身を指すリンク(ループ): ${suspects.join(", ")}`);
});
