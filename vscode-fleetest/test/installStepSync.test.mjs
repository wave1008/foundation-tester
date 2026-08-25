// Scripts/install.sh と .claude/skills/fleetest-setup/SKILL.md のステップ番号の 1:1 検証。
// 契約(CLAUDE.md): install.sh の各手順は SKILL.md のステップ番号と 1:1。失敗時に
// 「→ SKILL.md ステップ N」を出してエージェントを手作業手順へ戻す設計なので、SKILL.md 側で
// 採番を変えると、この誘導が存在しないステップを指して受け手が迷子になる。
//
// 方向は install.sh ⊆ SKILL.md。install.sh は機械作業だけを担うため、SKILL.md にある
// エージェント/人間専用のステップ(0.7 のインストーラ実行そのもの、6・8・9 など)を持たないのは正常。
//
// 抽出は完全ではない(複数行に跨る die 呼び出しの引数は拾わない)。ドリフト検出が目的なので、
// 取りこぼしがあっても採番変更の大半は検出できる。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const INSTALL_SH = "Scripts/install.sh";
const SKILL_MD = ".claude/skills/fleetest-setup/SKILL.md";

/** SKILL.md の `### 0.5 …` 形式の見出しからステップ番号を集める。 */
function skillSteps(source) {
  return new Set(
    [...source.matchAll(/^#{2,3}\s+(\d+(?:\.\d+)?)[.\s]/gm)].map((m) => m[1]),
  );
}

/** install.sh が参照するステップ番号(見出しコメント・die/soft_fail の第3引数・本文の言及)。 */
function installSteps(source) {
  const steps = new Set();
  // 「SKILL ステップ0.5」「SKILL.md step 7.5」などの明示的な言及(install.sh の出力は英語 = step、コメントは日本語 = ステップ)
  for (const m of source.matchAll(/SKILL(?:\.md)?\s*(?:ステップ|step)\s*(\d+(?:\.\d+)?)/gi)) {
    steps.add(m[1]);
  }
  // die / soft_fail の行末に置かれた第3引数(= ステップ番号)
  for (const line of source.split("\n")) {
    if (!/\b(?:die|soft_fail)\b/.test(line)) continue;
    const m = line.match(/\s(\d+(?:\.\d+)?)\s*;?\s*\}?\s*$/);
    if (m) steps.add(m[1]);
  }
  // 引数変数のプレースホルダ($3)は番号ではないので入らない
  return steps;
}

test("install.sh が参照するステップ番号は SKILL.md に実在する", () => {
  const install = readFileSync(path.join(ROOT, INSTALL_SH), "utf8");
  const skill = readFileSync(path.join(ROOT, SKILL_MD), "utf8");

  const declared = skillSteps(skill);
  assert.ok(declared.size > 0, `${SKILL_MD} からステップ見出しを抽出できません`);

  const referenced = installSteps(install);
  assert.ok(referenced.size > 0, `${INSTALL_SH} からステップ参照を抽出できません`);

  const orphans = [...referenced].filter((s) => !declared.has(s)).sort();
  assert.deepEqual(
    orphans,
    [],
    `${INSTALL_SH} が ${SKILL_MD} に無いステップを指しています: ${orphans.join(", ")}\n` +
      `SKILL.md のステップ: ${[...declared].sort().join(", ")}\n` +
      "手順の追加・番号の変更は install.sh と SKILL.md の両方に入れること" +
      "(失敗時の「→ SKILL.md ステップ N」が存在しない手順を指すと受け手が迷子になる)",
  );
});

test("install.sh の主要ステップが SKILL.md 側にも残っている", () => {
  // 逆方向の全数一致は取れない(SKILL.md にはエージェント/人間専用ステップがある)。
  // ただし install.sh が自動化している中核ステップが SKILL.md から消えるのは採番事故なので見る。
  const skill = readFileSync(path.join(ROOT, SKILL_MD), "utf8");
  const declared = skillSteps(skill);
  for (const core of ["0", "1", "2", "4", "7"]) {
    assert.ok(
      declared.has(core),
      `${SKILL_MD} に中核ステップ ${core} の見出しがありません(install.sh が参照しています)`,
    );
  }
});
