// update.sh 5.8(コピー配置のスキルの写し直し)の契約。
//
// `fleetest init` は全受け手に `.claude/skills/fleetest-setup` を作るので、`.claude/skills/` の
// 存在では「コピー配置の受け手」を判定できない。存在で判定していた頃は、プラグイン経由の
// 受け手の初回 /fleetest-update で正典5本が隣に写され(`fleetest-update` と
// `fleetest:fleetest-update` の二重掲載)、以後スキルが変わるたび「エージェントを再起動」を
// 迫っていた。判定は install-skill.sh が置く印 `.claude/skills/.fleetest-copied`。
//
// 検証する契約:
//   1. 印が無い置き場(プラグイン経由・fleetest-setup だけ)には何も足さない
//   2. 印がある置き場には増えたスキルを置き、変わった写しを写し直し、印にも名前を足す
//   3. 印が無くても既にある写し(シンボリックリンクでない)は写し直す。ただし足さない
//   4. fleetest-setup は印があっても写さない / シンボリックリンクは触らない
//   5. install-skill.sh は印を書く(curl を差し替えて実行)・印の名前は両スクリプトで一致
//
// update.sh の関数本体を抜き出してそのまま実行する(実装の写しを置かない —
// 写すと本体だけ直したときにテストが古い実装を守り続ける)。

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const UPDATE_SH = path.join(ROOT, "Scripts/update.sh");
const INSTALL_SKILL_SH = path.join(ROOT, "Scripts/install-skill.sh");
const MARKER = ".fleetest-copied";

/** update.sh の `COPIED_SKILLS_MARKER=` 〜 `refresh_copied_skills` 関数の閉じ `}` までを取り出す。 */
function refreshSnippet() {
  const source = readFileSync(UPDATE_SH, "utf8");
  const begin = source.indexOf("\nCOPIED_SKILLS_MARKER=");
  assert.ok(begin > 0, "update.sh に COPIED_SKILLS_MARKER= が無い(5.8 の印の定義が消えた?)");
  const fnStart = source.indexOf("refresh_copied_skills() {", begin);
  assert.ok(fnStart > begin, "update.sh に refresh_copied_skills() が無い");
  const end = source.indexOf("\n}\n", fnStart);
  assert.ok(end > fnStart, "refresh_copied_skills() の閉じ括弧が見つからない");
  return source.slice(begin + 1, end + 3);
}

const CANONICAL = ["fleetest-setup", "fleetest-update", "fleetest-profiles", "fleetest-scenario"];

function makeToolRoot(base, contents = {}) {
  const toolRoot = path.join(base, "foundation-tester");
  for (const name of CANONICAL) {
    const dir = path.join(toolRoot, ".claude/skills", name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, "SKILL.md"), contents[name] ?? `---\nname: ${name}\n---\ncanonical ${name}\n`);
  }
  return toolRoot;
}

function makeWorkDir(base, { skills = {}, marker = null, symlinks = [] } = {}) {
  const workDir = path.join(base, "MyApp");
  const skillsDir = path.join(workDir, ".claude/skills");
  mkdirSync(skillsDir, { recursive: true });
  for (const [name, body] of Object.entries(skills)) {
    mkdirSync(path.join(skillsDir, name), { recursive: true });
    writeFileSync(path.join(skillsDir, name, "SKILL.md"), body);
  }
  for (const [name, target] of symlinks) symlinkSync(target, path.join(skillsDir, name));
  if (marker !== null) writeFileSync(path.join(skillsDir, MARKER), marker);
  return { workDir, skillsDir };
}

/** 抜き出した関数を bash で1回流し、写した本数と置き場の状態を返す。 */
function runRefresh(toolRoot, skillsDir) {
  const script = path.join(path.dirname(toolRoot), "refresh.sh");
  writeFileSync(
    script,
    `set -uo pipefail\nTOOL_ROOT="$1"\n${refreshSnippet()}\nrefresh_copied_skills "$2"\necho "REFRESHED=$SKILLS_REFRESHED"\n`,
  );
  const out = execFileSync("bash", [script, toolRoot, skillsDir], { encoding: "utf8" });
  const m = out.match(/REFRESHED=(\d+)/);
  assert.ok(m, `出力に REFRESHED= が無い: ${out}`);
  const skill = (name) => {
    const p = path.join(skillsDir, name, "SKILL.md");
    return existsSync(p) ? readFileSync(p, "utf8") : null;
  };
  const markerPath = path.join(skillsDir, MARKER);
  return {
    refreshed: Number(m[1]),
    skill,
    marker: existsSync(markerPath) ? readFileSync(markerPath, "utf8") : null,
  };
}

function withTemp(fn) {
  const base = mkdtempSync(path.join(tmpdir(), "ft-copied-skills-"));
  try {
    return fn(base);
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
}

const RECEIVER_SETUP = "---\nname: fleetest-setup\n---\nreceiver-specific setup (written by fleetest init)\n";

test("プラグイン経由の受け手(fleetest-setup だけ・印なし)には何も足さない", () => {
  withTemp((base) => {
    const toolRoot = makeToolRoot(base);
    const { skillsDir } = makeWorkDir(base, { skills: { "fleetest-setup": RECEIVER_SETUP } });
    const r = runRefresh(toolRoot, skillsDir);
    assert.equal(r.refreshed, 0);
    assert.equal(r.skill("fleetest-update"), null, "印の無い置き場に fleetest-update が置かれた");
    assert.equal(r.skill("fleetest-profiles"), null);
    assert.equal(r.skill("fleetest-setup"), RECEIVER_SETUP, "受け手専用の fleetest-setup が上書きされた");
    assert.equal(r.marker, null, "印が勝手に作られた");
  });
});

test("印がある置き場には増えたスキルを置き、変わった写しを写し直し、印にも名前を足す", () => {
  withTemp((base) => {
    const toolRoot = makeToolRoot(base);
    const stale = "---\nname: fleetest-update\n---\nold copy\n";
    const { skillsDir } = makeWorkDir(base, {
      skills: { "fleetest-setup": RECEIVER_SETUP, "fleetest-update": stale },
      marker: "fleetest-setup\nfleetest-update\n",
    });
    const r = runRefresh(toolRoot, skillsDir);
    // fleetest-update(変更)+ fleetest-profiles / fleetest-scenario(新規)= 3
    assert.equal(r.refreshed, 3);
    assert.equal(r.skill("fleetest-update"), readFileSync(path.join(toolRoot, ".claude/skills/fleetest-update/SKILL.md"), "utf8"));
    assert.match(r.skill("fleetest-profiles") ?? "", /canonical fleetest-profiles/);
    assert.match(r.skill("fleetest-scenario") ?? "", /canonical fleetest-scenario/);
    assert.equal(r.skill("fleetest-setup"), RECEIVER_SETUP, "受け手専用の fleetest-setup が上書きされた");
    const names = r.marker.split("\n").filter(Boolean);
    assert.deepEqual(names, ["fleetest-setup", "fleetest-update", "fleetest-profiles", "fleetest-scenario"]);
    // 2周目は何もしない(冪等)・印も増えない
    const again = runRefresh(toolRoot, skillsDir);
    assert.equal(again.refreshed, 0);
    assert.equal(again.marker, r.marker);
  });
});

test("印が無くても既にある写しは写し直す。ただし足さない", () => {
  withTemp((base) => {
    const toolRoot = makeToolRoot(base);
    const { skillsDir } = makeWorkDir(base, {
      skills: {
        "fleetest-setup": RECEIVER_SETUP,
        "fleetest-update": "---\nname: fleetest-update\n---\nold copy\n",
        "fleetest-profiles": "---\nname: fleetest-profiles\n---\ncanonical fleetest-profiles\n", // 一致 = 触らない
      },
    });
    const r = runRefresh(toolRoot, skillsDir);
    assert.equal(r.refreshed, 1);
    assert.match(r.skill("fleetest-update") ?? "", /canonical fleetest-update/);
    assert.equal(r.skill("fleetest-scenario"), null, "印の無い置き場に新しいスキルが足された");
    assert.equal(r.marker, null);
  });
});

test("シンボリックリンクの写しは触らない(印があっても)", () => {
  withTemp((base) => {
    const toolRoot = makeToolRoot(base);
    const { skillsDir } = makeWorkDir(base, {
      skills: { "fleetest-setup": RECEIVER_SETUP },
      symlinks: [["fleetest-update", path.join(toolRoot, ".claude/skills/fleetest-update")]],
      marker: "",
    });
    const r = runRefresh(toolRoot, skillsDir);
    // 新規2本(profiles / scenario)だけ。リンクの fleetest-update は数えない
    assert.equal(r.refreshed, 2);
    const names = r.marker.split("\n").filter(Boolean);
    assert.deepEqual(names, ["fleetest-profiles", "fleetest-scenario"]);
  });
});

test("install-skill.sh は写した置き場に印を書く(curl を差し替えて実行)", () => {
  withTemp((base) => {
    const toolRoot = makeToolRoot(base);
    // curl -fsSL <url> -o <file>: URL 末尾の <name>/SKILL.md をローカル正典から写す
    const bin = path.join(base, "bin");
    mkdirSync(bin);
    const fakeCurl = path.join(bin, "curl");
    writeFileSync(
      fakeCurl,
      `#!/bin/sh
url=""; out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
name="$(basename "$(dirname "$url")")"
cp "${toolRoot}/.claude/skills/$name/SKILL.md" "$out"
`,
    );
    chmodSync(fakeCurl, 0o755);
    const dest = path.join(base, "agent-skills");
    const source = readFileSync(INSTALL_SKILL_SH, "utf8");
    // 本スクリプトの SKILLS はフィクスチャに無い名前を含むので、一覧だけ差し替えて実行する
    const patched = source.replace(/^SKILLS=".*"$/m, `SKILLS="${CANONICAL.join(" ")}"`);
    assert.notEqual(patched, source, "install-skill.sh の SKILLS= 行が見つからない");
    const script = path.join(base, "install-skill.sh");
    writeFileSync(script, patched);
    execFileSync("sh", [script, "--dir", dest], {
      encoding: "utf8",
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
    });
    const marker = readFileSync(path.join(dest, MARKER), "utf8");
    assert.deepEqual(marker.split("\n").filter(Boolean), CANONICAL);
    for (const name of CANONICAL) assert.ok(existsSync(path.join(dest, name, "SKILL.md")), `${name} が置かれていない`);
  });
});

test("印のファイル名は install-skill.sh と update.sh で一致する", () => {
  const re = /^COPIED_SKILLS_MARKER="([^"]+)"$/m;
  const inUpdate = readFileSync(UPDATE_SH, "utf8").match(re);
  const inInstall = readFileSync(INSTALL_SKILL_SH, "utf8").match(re);
  assert.ok(inUpdate, "update.sh に COPIED_SKILLS_MARKER= が無い");
  assert.ok(inInstall, "install-skill.sh に COPIED_SKILLS_MARKER= が無い");
  assert.equal(inUpdate[1], inInstall[1]);
  assert.equal(inUpdate[1], MARKER, "テストの MARKER 定数がスクリプトとずれている");
});
