// Claude Code プラグイン配布メタデータの整合検証。
// 契約: プラグインの skills は複製せず正典 .claude/skills/ を参照する
// (plugin.json の "skills" パス。source が marketplace ルートのとき既定 skills/ を置換する仕様)。
// スキルの呼び出し名は SKILL.md frontmatter の name から決まるため、ディレクトリ名との一致も見る。
//
// process.cwd() は npm test 実行時に vscode-ftester ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
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
