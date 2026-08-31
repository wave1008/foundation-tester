// エージェント規約位置の言語跨ぎ整合検証。
//
// 契約: 規約位置(スキルの置き場所・入口ファイル・呼び出し記法)の定義元は
// Sources/FTCore/AgentIntegration.swift ただ1つ。ただし **install.sh / install-skill.sh は
// Swift を呼べない**(clone 前・ビルド前に走る)ので、同じ文字列をシェルにも手で書いている。
// **片方だけ変えると、CLI が書いた場所とインストーラが見る場所が食い違い、しかも
// 「動いているように見える」**(どちらも正しく動作するが、別の場所を触る)。
// ここが両者のドリフトを落とす。
//
// **インストーラが用意するのは Claude Code の規約位置だけ**。他のエージェント(Codex 等)は
// MCP 登録と SKILL.md 直読みで使う(docs/user-docs/tools/other_agents.md)ので、
// その設定ファイル・規約位置へ書く経路が復活していないことも見る。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート。

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, existsSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const SWIFT = readFileSync(path.join(ROOT, "Sources/FTCore/AgentIntegration.swift"), "utf8");
const INSTALL_SH = readFileSync(path.join(ROOT, "Scripts/install.sh"), "utf8");
const INSTALL_SKILL_SH = readFileSync(path.join(ROOT, "Scripts/install-skill.sh"), "utf8");

test("Swift の AgentIntegration が Claude Code の規約位置を持つ", () => {
  for (const value of [".claude/skills", "CLAUDE.md", ".mcp.json"]) {
    assert.ok(SWIFT.includes(`"${value}"`), `AgentIntegration に ${value} がありません`);
  }
  // 呼び出し記法(入口ファイルの本文で使う)
  assert.match(SWIFT, /skillInvocationPrefix/, "呼び出し記法の定義がありません");
});

test("正典スキルディレクトリの定義が Swift とインストーラで一致する", () => {
  const m = SWIFT.match(/canonicalSkillsDirectory\s*=\s*"([^"]+)"/);
  assert.ok(m, "AgentIntegration.canonicalSkillsDirectory がありません");
  assert.equal(m[1], ".claude/skills");
  // install-skill.sh は raw.githubusercontent からこの実体パスを引く(リンク越しは不可)
  assert.ok(
    INSTALL_SKILL_SH.includes(`/${m[1]}`),
    `install-skill.sh の取得元が ${m[1]} ではありません`,
  );
  // update.sh の写し元も正典
  const updateSh = readFileSync(path.join(ROOT, "Scripts/update.sh"), "utf8");
  assert.ok(
    updateSh.includes(`$TOOL_ROOT/${m[1]}/`),
    `update.sh の写し元が ${m[1]} ではありません`,
  );
});

// --- 他のエージェントの設定には触らない ----------------------------------------
// 受け手のグローバル設定(~/.codex/config.toml 等)は**セキュリティ境界**で、書式も
// エージェントごとに違う(TOML はテーブルの重複で全体が無効になる)。インストーラが
// 面倒を見るのは Claude Code の規約位置だけで、他は手順書で案内する。

test("インストーラ一式が他エージェントの規約位置・設定へ書かない", () => {
  const files = ["Scripts/install.sh", "Scripts/install-skill.sh",
                 "Scripts/update.sh", "Scripts/preflight.sh"];
  const forbidden = [/\.codex\//, /AGENTS\.md/, /\.agents\/skills/, /codex plugin/];
  for (const rel of files) {
    const src = readFileSync(path.join(ROOT, rel), "utf8")
      .split("\n")
      .filter((line) => !line.trimStart().startsWith("#"))  // 説明のコメントは対象外
      .join("\n");
    for (const re of forbidden) {
      assert.ok(!re.test(src), `${rel} に他エージェント向けの経路が残っています: ${re}`);
    }
  }
});

// --- ランナー機には入口ファイルを置かない -------------------------------------
// 入口(CLAUDE.md)は**人が開く機械**のためのもので、ランナー機には要らない。
// 抑止フラグを変えると Swift の実引数と docs の記載がドリフトするので、両方を見る。

test("RemoteSetup.installArgs が入口ファイルの生成を抑止する", () => {
  const swift = readFileSync(path.join(ROOT, "Sources/FTRemote/RemoteSetup.swift"), "utf8");
  assert.ok(swift.includes('"--skip-claude-md"'),
    "RemoteSetup.installArgs に入口抑止 --skip-claude-md がありません");
});

test("ランナーの install 引数が docs と一致する(片方だけ変えない)", () => {
  const swift = readFileSync(path.join(ROOT, "Sources/FTRemote/RemoteSetup.swift"), "utf8");
  const body = swift.slice(swift.indexOf("func installArgs"));
  const flags = [...body.slice(0, body.indexOf("\n    }")).matchAll(/"(--[a-z-]+)"/g)]
    .map((m) => m[1])
    .filter((f) => f.startsWith("--skip") || f === "--no-next-steps");
  assert.ok(flags.length >= 3, `installArgs から抑止フラグを抽出できません: ${flags}`);
  for (const doc of ["docs/remote-runner.md", "docs/remote-runner-setup.md"]) {
    const source = readFileSync(path.join(ROOT, doc), "utf8");
    const missing = flags.filter((f) => !source.includes(f));
    // --no-next-steps は setup 手順書には出ないので、そちらだけ緩める
    const required = doc.endsWith("remote-runner.md") ? missing : missing.filter((f) => f !== "--no-next-steps");
    assert.deepEqual(required, [],
      `${doc} が installArgs の抑止フラグを載せていません: ${required.join(", ")}`);
  }
});

test("入口ファイルはクローンの中には書かない(未追跡でも)", () => {
  // 追跡の有無で判定すると、**まだ存在しない入口ファイル**が素通りする。
  // `git status --porcelain` は未追跡も dirty と数えるので、次の更新が pull ガードで止まる。
  // install.sh から write_entry_point を抜き出して実際に走らせる(実装の写しを置かない)。
  const begin = INSTALL_SH.indexOf("write_entry_point() {");
  assert.ok(begin > 0, "install.sh に write_entry_point がありません");
  const end = INSTALL_SH.indexOf("\n}\n", begin);
  const fn = INSTALL_SH.slice(begin, end + 3);

  const dir = mkdtempSync(path.join(tmpdir(), "ft-entry-guard-"));
  try {
    const clone = path.join(dir, "clone");
    const outside = path.join(dir, "work");
    mkdirSync(clone); mkdirSync(outside);
    execFileSync("git", ["init", "-q", clone]);
    const script = path.join(dir, "run.sh");
    // record は結果を1行で出すだけのスタブに差し替える
    writeFileSync(script, [
      "set -eu",
      'record() { echo "$1|$2"; }',
      fn,
      'WORK_DIR="$1"; TOOL_ROOT="$2"',
      "write_entry_point",
    ].join("\n"));

    const inClone = execFileSync("bash", [script, clone, clone], { encoding: "utf8" });
    assert.match(inClone, /CLAUDE\.md\|skip/, `クローンの中に書こうとしています: ${inClone}`);
    assert.ok(!existsSync(path.join(clone, "CLAUDE.md")), "クローンに CLAUDE.md が作られました");

    const outsideClone = execFileSync("bash", [script, outside, clone], { encoding: "utf8" });
    assert.match(outsideClone, /CLAUDE\.md\|ok/, `クローンの外なのに書いていません: ${outsideClone}`);
    assert.ok(existsSync(path.join(outside, "CLAUDE.md")), "クローン外の入口が作られていません");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("スキル一覧は install-skill.sh の1箇所だけが手書きで、正典と一致する", () => {
  // **手で持つ一覧は少ないほどよい**。update.sh は TOOL_ROOT を持つので正典から導出でき、
  // install-skill.sh は clone より前に走るので導出できない —— 残る手書きはこの1つだけ。
  // ここが正典とズレると、curl で入れた受け手に配られるスキルの集合が変わる
  const declared = INSTALL_SKILL_SH.match(/SKILLS="([^"]+)"/);
  assert.ok(declared, "install-skill.sh の SKILLS が見つかりません");
  const canon = readdirSync(path.join(ROOT, ".claude", "skills"), { withFileTypes: true })
    .filter((d) => d.isDirectory()).map((d) => d.name).sort();
  assert.deepEqual(declared[1].split(/\s+/).filter(Boolean).sort(), canon,
    "install-skill.sh の SKILLS と正典が食い違っています");
});

test("update.sh のコピー対象は正典から導出し、fleetest-setup だけ除く", () => {
  // 手で持つと、スキルを増やす/改名するたびに直し忘れてコピー配置の受け手だけ取り残される。
  // fleetest-setup を除くのは、受け手のそれが `fleetest init` の生成物(別内容)だから
  const updateSh = readFileSync(path.join(ROOT, "Scripts/update.sh"), "utf8");
  assert.match(updateSh, /COPIED_SKILLS="\$\(ls "\$TOOL_ROOT\/\.claude\/skills"/,
    "COPIED_SKILLS を正典から導出していません(手書きの一覧が3つ目になります)");
  assert.match(updateSh, /grep -v '\^fleetest-setup\$'/,
    "fleetest-setup を除外していません(受け手のセットアップ手順が上書きされます)");
});

test("FLEETEST_REF がスクリプトの取得元とクローンの ref を揃える", () => {
  // 揃えないと「ブランチのスクリプトが main を clone し、main のバイナリに新しい引数を渡す」
  // 組み合わせが生まれ、Unknown option で落ちる(未マージのブランチ検証で実際に踏んだ)。
  // 受け手には影響しない(タグは main の祖先なので install.sh@main は常に新しい)が、
  // **直したはずの挙動を確認できない**という一番たちの悪い壊れ方をする
  assert.match(INSTALL_SH, /REF="\$\{FLEETEST_REF:-\}"/, "install.sh が FLEETEST_REF を読んでいません");
  assert.match(INSTALL_SH, /git clone \$\{REF:\+--branch "\$REF"\}/,
    "新規 clone が REF を指定していません");
  assert.match(INSTALL_SH, /fetch --tags origin "\$REF"/,
    "既存クローンを REF へ揃えていません");
  // スキル側の取得元も同じ口を使う(片方だけだと同じズレが残る)
  const setup = readFileSync(path.join(ROOT, ".claude/skills/fleetest-setup/SKILL.md"), "utf8");
  assert.match(setup, /\$\{FLEETEST_REF:-main\}\/Scripts\/install\.sh/,
    "setup スキルの install.sh 取得元が ref を通していません");
});

test("FLEETEST_REF は「版固定(detached)」ガードより先に効く", () => {
  // 後ろに置くと、**一度タグへ固定したクローンが二度とブランチへ戻れない**(実測で踏んだ)。
  // FLEETEST_REF は「ここへ動かせ」という明示指示なので、現在の状態に関わらず従う
  const refBranch = INSTALL_SH.indexOf('elif [ -n "$REF" ]; then');
  const pinnedGuard = INSTALL_SH.indexOf("version pinned:");
  assert.ok(refBranch > 0, "install.sh に REF の分岐がありません");
  assert.ok(pinnedGuard > 0, "install.sh に版固定ガードがありません");
  assert.ok(refBranch < pinnedGuard,
    "REF の分岐が版固定ガードより後ろにあります(タグへ固定すると戻れなくなります)");
});

test("ref へ揃えるとき、ブランチは追跡付き・タグは detached", () => {
  // 追跡を張らないと、次に FLEETEST_REF 無しで実行したとき `git pull` が
  // 「no tracking information」で失敗し、戻れないまま毎回 warn が出る
  assert.match(INSTALL_SH, /checkout -q -B "\$REF" --track "origin\/\$REF"/,
    "ブランチの checkout に --track がありません");
  assert.match(INSTALL_SH, /checkout -q --detach FETCH_HEAD/,
    "タグ・SHA を detached にしていません");
  assert.match(INSTALL_SH, /ls-remote --exit-code --heads origin "\$REF"/,
    "ブランチかどうかの判定がありません");
});

test("ref へ揃える経路でも自己再 exec の材料を取る", () => {
  // 取らないと、揃えた先の新しい install.sh が**その回に1つも実行されない**
  // (CLAUDE.md の再 exec の項と同じ実害)
  const refBranch = INSTALL_SH.indexOf('elif [ -n "$REF" ]; then');
  const section = INSTALL_SH.slice(refBranch, INSTALL_SH.indexOf("version pinned:"));
  const captured = section.indexOf("HEAD_BEFORE_PULL=");
  const fetched = section.indexOf("fetch --tags origin");
  assert.ok(captured > 0, "REF 経路が HEAD_BEFORE_PULL を取っていません(再 exec が働きません)");
  assert.ok(captured < fetched, "HEAD_BEFORE_PULL を fetch の後で取っています(常に同じ値になります)");
});
