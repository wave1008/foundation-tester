// install.sh ステップ7.8(スキルを作業フォルダへコピーする)の契約。
//
// `fleetest init` は全受け手に `.claude/skills/fleetest-setup` を作るので、`.claude/skills/` の
// 存在では「こちらが写したもの」を判定できない。所有の印は `.claude/skills/.fleetest-copied`。
//
// 検証する契約:
//   1. fleetest-setup だけが居る作業フォルダには、他を置いて印を作る(fleetest-setup は不変)
//   2. 印にある写しは正典に追随して更新し、印に無い既存は受け手のものとして触らない
//   3. シンボリックリンクは触らない
//   4. 正典から消えた名前は印にあるものだけ片付けて印から外す
//   5. fleetest-setup は書かない・印にも入れない(旧い印に載っていても外す)
//   6. skip 条件: --skip-skills / クローン構成 / 置き先がクローンの内側
//   7. 2周目は何も変えない(冪等)
//
// install.sh の関数本体を抜き出してそのまま実行する(実装の写しを置かない —
// 写すと本体だけ直したときにテストが古い実装を守り続ける)。

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
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
const INSTALL_SH = path.join(ROOT, "Scripts/install.sh");
const MARKER = ".fleetest-copied";

/** install.sh の `SKILLS_MARKER_NAME=` 〜 `place_skills` 関数の閉じ `}` までを取り出す。 */
function placeSnippet() {
  const source = readFileSync(INSTALL_SH, "utf8");
  const begin = source.indexOf("\nSKILLS_MARKER_NAME=");
  assert.ok(begin > 0, "install.sh に SKILLS_MARKER_NAME= が無い(ステップ7.8 の印の定義が消えた?)");
  const fnStart = source.indexOf("place_skills() {", begin);
  assert.ok(fnStart > begin, "install.sh に place_skills() が無い");
  const end = source.indexOf("\n}\n", fnStart);
  assert.ok(end > fnStart, "place_skills() の閉じ括弧が見つからない");
  return source.slice(begin + 1, end + 3);
}

const CANONICAL = ["fleetest-setup", "fleetest-update", "fleetest-profiles", "fleetest-scenario"];

function makeToolRoot(base, names = CANONICAL) {
  const toolRoot = path.join(base, "foundation-tester");
  mkdirSync(toolRoot, { recursive: true });
  for (const name of names) {
    const dir = path.join(toolRoot, ".claude/skills", name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, "SKILL.md"), `---\nname: ${name}\n---\ncanonical ${name}\n`);
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

/** 抜き出した関数を bash で1回流し、record の出力と置き場の状態を返す。 */
function runPlace(toolRoot, workDir, { skip = false } = {}) {
  const script = path.join(path.dirname(toolRoot), "place.sh");
  writeFileSync(
    script,
    [
      "set -euo pipefail",
      'TOOL_ROOT="$1"; WORK_DIR="$2"; DO_SKILLS="$3"',
      'record() { echo "RECORD|$1|$2|$3"; }',
      'soft_fail() { echo "RECORD|$1|warn|$2"; }',
      placeSnippet(),
      "place_skills",
    ].join("\n"),
  );
  const out = execFileSync("bash", [script, toolRoot, workDir, skip ? "0" : "1"], { encoding: "utf8" });
  const rec = out.match(/^RECORD\|skills\|(\w+)\|(.*)$/m);
  assert.ok(rec, `skills の record が出ていない: ${out}`);
  const skillsDir = path.join(workDir, ".claude/skills");
  const skill = (name) => {
    const p = path.join(skillsDir, name, "SKILL.md");
    return existsSync(p) ? readFileSync(p, "utf8") : null;
  };
  const markerPath = path.join(skillsDir, MARKER);
  return {
    out,
    status: rec[1],
    detail: rec[2],
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
const canonicalBody = (toolRoot, name) =>
  readFileSync(path.join(toolRoot, ".claude/skills", name, "SKILL.md"), "utf8");

test("fleetest-setup だけの作業フォルダには他を置いて印を作る(fleetest-setup は不変)", () => {
  withTemp((base) => {
    const toolRoot = makeToolRoot(base);
    const { workDir } = makeWorkDir(base, { skills: { "fleetest-setup": RECEIVER_SETUP } });
    const r = runPlace(toolRoot, workDir);
    assert.equal(r.status, "ok");
    assert.match(r.detail, /3 placed, 0 refreshed, 0 removed/);
    assert.match(r.out, /Restart your AI assistant/);
    for (const name of ["fleetest-update", "fleetest-profiles", "fleetest-scenario"]) {
      assert.equal(r.skill(name), canonicalBody(toolRoot, name));
    }
    assert.equal(r.skill("fleetest-setup"), RECEIVER_SETUP, "受け手専用の fleetest-setup が上書きされた");
    assert.deepEqual(r.marker.split("\n").filter(Boolean), ["fleetest-profiles", "fleetest-scenario", "fleetest-update"]);
    // 2周目は何もしない(冪等)・印も変わらない
    const again = runPlace(toolRoot, workDir);
    assert.equal(again.status, "skip");
    assert.doesNotMatch(again.out, /Restart your AI assistant/);
    assert.equal(again.marker, r.marker);
  });
});

test("作業フォルダに .claude/skills が無くても置く(最初の配置)", () => {
  withTemp((base) => {
    const toolRoot = makeToolRoot(base);
    const workDir = path.join(base, "MyApp");
    mkdirSync(workDir);
    const r = runPlace(toolRoot, workDir);
    assert.equal(r.status, "ok");
    assert.equal(r.skill("fleetest-scenario"), canonicalBody(toolRoot, "fleetest-scenario"));
    assert.equal(r.skill("fleetest-setup"), null, "fleetest-setup が写された");
  });
});

test("印にある写しは写し直し、印に無い既存は受け手のものとして触らない", () => {
  withTemp((base) => {
    const toolRoot = makeToolRoot(base);
    const own = "---\nname: fleetest-profiles\n---\nthe receiver's own version\n";
    const { workDir } = makeWorkDir(base, {
      skills: {
        "fleetest-setup": RECEIVER_SETUP,
        "fleetest-update": "---\nname: fleetest-update\n---\nold copy\n",
        "fleetest-profiles": own,
      },
      marker: "fleetest-update\n",
    });
    const r = runPlace(toolRoot, workDir);
    assert.match(r.detail, /1 placed, 1 refreshed, 0 removed/);
    assert.equal(r.skill("fleetest-update"), canonicalBody(toolRoot, "fleetest-update"));
    assert.equal(r.skill("fleetest-profiles"), own, "印に無い既存が上書きされた");
    assert.match(r.skill("fleetest-scenario") ?? "", /canonical fleetest-scenario/);
    assert.deepEqual(r.marker.split("\n").filter(Boolean), ["fleetest-update", "fleetest-scenario"]);
  });
});

test("シンボリックリンクは触らない(印にあっても)", () => {
  withTemp((base) => {
    const toolRoot = makeToolRoot(base);
    // リンク先は正典と**中身の違う**別の置き場(受け手が自分で張ったリンク)。正典を指すと
    // 写す差分が無いので、リンクの判定を外しても何も起きずに通ってしまう
    const pinnedDir = path.join(base, "pinned/fleetest-update");
    mkdirSync(pinnedDir, { recursive: true });
    const pinned = "---\nname: fleetest-update\n---\npinned by the receiver\n";
    writeFileSync(path.join(pinnedDir, "SKILL.md"), pinned);
    const { workDir, skillsDir } = makeWorkDir(base, {
      skills: { "fleetest-setup": RECEIVER_SETUP },
      symlinks: [["fleetest-update", pinnedDir]],
      marker: "fleetest-update\n",
    });
    const r = runPlace(toolRoot, workDir);
    assert.match(r.detail, /2 placed, 0 refreshed, 0 removed/);
    assert.ok(lstatSync(path.join(skillsDir, "fleetest-update")).isSymbolicLink(), "リンクが実体に置き換わった");
    assert.equal(readFileSync(path.join(pinnedDir, "SKILL.md"), "utf8"), pinned, "リンク越しに書き換えた");
  });
});

test("正典から消えた名前は、印にあるものだけ片付けて印から外す", () => {
  withTemp((base) => {
    const toolRoot = makeToolRoot(base, ["fleetest-setup", "fleetest-update"]);
    const mine = "---\nname: my-own-skill\n---\nnot ours\n";
    const { workDir } = makeWorkDir(base, {
      skills: {
        "fleetest-setup": RECEIVER_SETUP,
        "fleetest-update": "---\nname: fleetest-update\n---\nold\n",
        "fleetest-gone": "---\nname: fleetest-gone\n---\nremoved from canonical\n",
        "my-own-skill": mine,
      },
      marker: "fleetest-update\nfleetest-gone\n",
    });
    const r = runPlace(toolRoot, workDir);
    assert.match(r.detail, /0 placed, 1 refreshed, 1 removed/);
    assert.equal(r.skill("fleetest-gone"), null, "正典から消えた写しが残っている");
    assert.equal(r.skill("my-own-skill"), mine, "印に無いスキルが消された");
    assert.deepEqual(r.marker.split("\n").filter(Boolean), ["fleetest-update"]);
  });
});

test("正典から消えた名前でも、リンクなら消さない(リンク越しに受け手のファイルを消さない)", () => {
  withTemp((base) => {
    const toolRoot = makeToolRoot(base, ["fleetest-setup", "fleetest-update"]);
    const pinnedDir = path.join(base, "pinned/fleetest-gone");
    mkdirSync(pinnedDir, { recursive: true });
    const pinned = "---\nname: fleetest-gone\n---\nthe receiver's file behind a link\n";
    writeFileSync(path.join(pinnedDir, "SKILL.md"), pinned);
    const { workDir, skillsDir } = makeWorkDir(base, {
      skills: { "fleetest-setup": RECEIVER_SETUP },
      symlinks: [["fleetest-gone", pinnedDir]],
      marker: "fleetest-gone\n",
    });
    runPlace(toolRoot, workDir);
    assert.ok(lstatSync(path.join(skillsDir, "fleetest-gone")).isSymbolicLink(), "リンクが消された");
    assert.equal(readFileSync(path.join(pinnedDir, "SKILL.md"), "utf8"), pinned, "リンク越しに受け手のファイルを消した");
  });
});

test("fleetest-setup は旧い印に載っていても書かず、印から外す", () => {
  withTemp((base) => {
    const toolRoot = makeToolRoot(base);
    const { workDir } = makeWorkDir(base, {
      skills: { "fleetest-setup": RECEIVER_SETUP },
      marker: "fleetest-setup\nfleetest-update\nfleetest-profiles\nfleetest-scenario\n",
    });
    const r = runPlace(toolRoot, workDir);
    assert.equal(r.skill("fleetest-setup"), RECEIVER_SETUP);
    assert.doesNotMatch(r.marker, /fleetest-setup/);
  });
});

test("--skip-skills・クローン構成・クローンの内側の置き先は skip して何も書かない", () => {
  withTemp((base) => {
    const toolRoot = makeToolRoot(base);
    const { workDir } = makeWorkDir(base, { skills: { "fleetest-setup": RECEIVER_SETUP } });
    const skipped = runPlace(toolRoot, workDir, { skip: true });
    assert.equal(skipped.status, "skip");
    assert.equal(skipped.skill("fleetest-update"), null);
    assert.equal(skipped.marker, null);

    const cloneLayout = runPlace(toolRoot, toolRoot);
    assert.equal(cloneLayout.status, "skip");
    assert.match(cloneLayout.detail, /clone layout/);

    // 作業フォルダがクローンの内側(別名のサブディレクトリ)
    const inside = path.join(toolRoot, "TestProjects", "x");
    mkdirSync(inside, { recursive: true });
    const r = runPlace(toolRoot, inside);
    assert.equal(r.status, "skip");
    assert.match(r.detail, /inside the clone/);
    assert.ok(!existsSync(path.join(inside, ".claude")), "クローンの内側に書いた");
  });
});

test("コピーでありリンクではない(作業フォルダは git にコミットされうる)", () => {
  const body = placeSnippet();
  assert.doesNotMatch(body, /\bln\s+-s/, "place_skills がシンボリックリンクを作っている");
  assert.match(body, /\bcp "\$sk_src/, "place_skills がコピーしていない");
});
