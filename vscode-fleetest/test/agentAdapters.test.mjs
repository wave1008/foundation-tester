// エージェント配布アダプタ(Claude Code / Codex)の整合検証。
// 契約(docs/design.md §15): **runbook 本体は複製しない**。正典は .claude/skills/ の1箇所で、
// 各エージェントへは「規約位置から正典を参照する薄いアダプタ」だけを置く:
//   Claude Code → .claude-plugin/plugin.json + .claude-plugin/marketplace.json
//   Codex       → .codex-plugin/plugin.json + .agents/plugins/marketplace.json
//                 + .agents/skills/<name> → ../../.claude/skills/<name>(シンボリックリンク)
// スキルの呼び出し名は SKILL.md frontmatter の name から決まるため、ディレクトリ名との一致も見る。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
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

// --- Codex アダプタ -----------------------------------------------------------

test("codex-plugin/plugin.json が有効な JSON で正典 .claude/skills/ を指す", () => {
  const plugin = JSON.parse(readFileSync(path.join(ROOT, ".codex-plugin", "plugin.json"), "utf8"));
  assert.equal(plugin.name, "fleetest");
  assert.equal(plugin.skills, "./.claude/skills/", "skills は正典 .claude/skills/ の参照(複製禁止)");
});

test("Codex の marketplace.json が .agents/plugins/ にあり plugin と対応する", () => {
  const marketplace = JSON.parse(
    readFileSync(path.join(ROOT, ".agents", "plugins", "marketplace.json"), "utf8"),
  );
  const plugin = JSON.parse(readFileSync(path.join(ROOT, ".codex-plugin", "plugin.json"), "utf8"));
  const entry = marketplace.plugins?.find((p) => p.name === plugin.name);
  assert.ok(entry, `marketplace.json に plugin "${plugin.name}" のエントリがありません`);
  assert.equal(entry.source?.path, "./", "source.path はリポジトリルート(plugin.json の在り処)");
});

test(".agents/skills/ の各スキルが正典へのシンボリックリンクで、実体に届く", () => {
  const canon = path.join(ROOT, ".claude", "skills");
  const agentsSkills = path.join(ROOT, ".agents", "skills");
  const canonDirs = readdirSync(canon, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();
  const linked = readdirSync(agentsSkills).sort();
  assert.deepEqual(linked, canonDirs, ".agents/skills/ と正典のスキル集合が一致していません");

  for (const name of linked) {
    const entry = path.join(agentsSkills, name);
    assert.ok(lstatSync(entry).isSymbolicLink(), `${name} がシンボリックリンクではありません(複製禁止)`);
    // **実体に届くこと**まで見る。リンク先を間違えても存在チェックだけでは気付けない
    assert.equal(
      realpathSync(entry),
      realpathSync(path.join(canon, name)),
      `${name} のリンク先が正典ではありません`,
    );
    assert.ok(existsSync(path.join(entry, "SKILL.md")), `${name}/SKILL.md にリンク越しで届きません`);
  }
});

test("install-skill.sh は正典(実体)から取得する — リンク越しに取ると本文が返らない", () => {
  const sh = readFileSync(path.join(ROOT, "Scripts/install-skill.sh"), "utf8");
  // raw.githubusercontent はシンボリックリンクをリンク先の文字列として返すので、
  // 取得元が .agents/skills/ になっていると SKILL.md ではなく1行のパスが降ってくる
  assert.ok(
    sh.includes("/.claude/skills"),
    "install-skill.sh の取得元が正典 .claude/skills/ ではありません",
  );
  assert.ok(
    !/raw\.githubusercontent[^\n]*\.agents\/skills/.test(sh),
    "install-skill.sh がシンボリックリンク側(.agents/skills/)から取得しようとしています",
  );
  // 置き先としては両方を扱えること
  assert.ok(sh.includes(".agents/skills"), "install-skill.sh が Codex の置き先を持っていません");
});
