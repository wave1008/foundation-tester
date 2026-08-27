// エージェント規約位置の言語跨ぎ整合検証。
//
// 契約: 「どのエージェントを使っているか」の判定規則と、規約位置(スキルの置き場所・入口
// ファイル・呼び出し記法)の定義元は Sources/FTCore/AgentIntegration.swift ただ1つ。
// ただし **install.sh / install-skill.sh は Swift を呼べない**(clone 前・ビルド前に走る)ので、
// 同じ規則をシェルにも手で書いている。**片方だけ変えると、CLI が書いた場所と
// インストーラが見る場所が食い違い、しかも「動いているように見える」**(どちらも正しく
// 動作するが、別の場所を触る)。ここが両者のドリフトを落とす。
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

/** 判定に使う手掛かり(この6つが揃って1つの規則)。 */
const SIGNALS = {
  claude: [".claude", "CLAUDE.md", ".claude"], // 3つ目はホーム側(~/.claude)
  codex: [".agents", "AGENTS.md", ".codex"],
};

/** 規約位置(Swift の enum が返す値と同じ文字列がシェルにも要る)。 */
const CONVENTIONS = [
  { agent: "claude", skills: ".claude/skills", entry: "CLAUDE.md" },
  { agent: "codex", skills: ".agents/skills", entry: "AGENTS.md" },
];

test("Swift の AgentIntegration が両エージェントの規約位置を持つ", () => {
  for (const { skills, entry } of CONVENTIONS) {
    assert.ok(SWIFT.includes(`"${skills}"`), `AgentIntegration に ${skills} がありません`);
    assert.ok(SWIFT.includes(`"${entry}"`), `AgentIntegration に ${entry} がありません`);
  }
  assert.ok(SWIFT.includes('case codex'), "AgentIntegration に codex がありません");
  // 呼び出し記法(入口ファイルの本文と install.sh の write_entry_point 呼び出しで使う)
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

/**
 * 自動判定のブロックだけを切り出す。**ファイル全体に対して includes() で見てはいけない** ——
 * `$HOME/.codex` はステップ7.5 の CODEX_CONFIG にも出るので、判定から手掛かりを1つ消しても
 * 素通しする(実際に変異が生き残った)。
 */
function detectionBlock(file, source) {
  // 判定の実体は install.sh では detect_agents()、install-skill.sh では auto の if 文にある。
  // **どちらか一方だけを見ると、実体が関数へ移った瞬間に空を検査して素通しする**(実際に踏んだ)
  const candidates = ["detect_agents() {", 'if [ "$AGENT" = "auto" ]', 'case "$AGENT_ARG" in']
    .map((marker) => source.indexOf(marker))
    .filter((at) => at > 0);
  const begin = Math.min(...candidates);
  assert.ok(Number.isFinite(begin) && begin > 0, `${file} に自動判定ブロックが見つかりません`);
  const endMarkers = ["has_agent()", "case \"$AGENT\" in"];
  let end = -1;
  for (const marker of endMarkers) {
    const at = source.indexOf(marker, begin);
    if (at > 0 && (end < 0 || at < end)) end = at;
  }
  assert.ok(end > begin, `${file} の自動判定ブロックの終端が見つかりません`);
  return source.slice(begin, end);
}

for (const [file, source] of [
  ["Scripts/install.sh", INSTALL_SH],
  ["Scripts/install-skill.sh", INSTALL_SKILL_SH],
]) {
  test(`${file} の自動判定が Swift と同じ6つの手掛かりを見る`, () => {
    const block = detectionBlock(file, source);
    for (const [agent, signals] of Object.entries(SIGNALS)) {
      for (const signal of new Set(signals)) {
        assert.ok(
          block.includes(signal),
          `${file} の判定に ${agent} の手掛かり ${signal} がありません`,
        );
      }
    }
    // ホーム側も見ること(まだ何も置いていない受け手を拾う唯一の手掛かり)
    assert.ok(block.includes("$HOME/.claude"), `${file} が ~/.claude を見ていません`);
    assert.ok(block.includes("$HOME/.codex"), `${file} が ~/.codex を見ていません`);
  });

  test(`${file} は手掛かりが1つも無ければ claude に倒す(既存の受け手の挙動を変えない)`, () => {
    assert.match(
      detectionBlock(file, source),
      /AGENTS?(?:_ARG)?=?"?\w*"?\s*\]\s*\|\|\s*AGENTS?\w*="claude"|\|\| AGENT(?:S)?="claude"/,
      `${file} に "どれも無ければ claude" のフォールバックがありません`,
    );
  });
}

test("Codex 側は project スコープの .codex/config.toml を使わない(黙って効かない設定を作らない)", () => {
  // trusted なプロジェクトでしか読まれないため、書いても無効になりうる。
  // 登録先はユーザーレベルの ~/.codex/config.toml だけ。
  assert.ok(
    INSTALL_SH.includes("CODEX_HOME:-$HOME/.codex"),
    "install.sh が ~/.codex/config.toml(CODEX_HOME 対応)を登録先にしていません",
  );
  assert.ok(
    !/WORK_DIR"?\/\.codex\/config\.toml/.test(INSTALL_SH),
    "install.sh がプロジェクトスコープの .codex/config.toml を書こうとしています",
  );
});

test("install.sh はサンドボックス設定を書かない(判定だけ)", () => {
  const start = INSTALL_SH.indexOf("# ---- 7.7");
  assert.ok(start > 0, "install.sh にステップ7.7(サンドボックス判定)がありません");
  const end = INSTALL_SH.indexOf("# ---- 5. プロファイル", start);
  const section = INSTALL_SH.slice(start, end > 0 ? end : undefined);
  // 判定は python の read だけ。open(..., "w"/"a") が現れたら書き込みに転んでいる
  assert.ok(
    !/open\([^)]*,\s*"[wa]"/.test(section),
    "ステップ7.7 が ~/.codex/config.toml へ書き込もうとしています(受け手のセキュリティ境界)",
  );
  assert.match(section, /network_access/, "サンドボックス判定に network_access がありません");
});

// --- インストーラの決定を CLI が上書きしないこと --------------------------------
// 実害: `install.sh --agent codex` で導入したのに、CLI 側が独自判定して
// **受け手のホームに ~/.claude があるだけで** Codex 専用のワークスペースに
// .claude/settings.json ができた。決定は install.sh が1回だけ行い、CLI へ渡す。

for (const command of ["api ensure-settings", "init"]) {
  test(`install.sh は ${command} に --agent を渡す(CLI に再判定させない)`, () => {
    const at = INSTALL_SH.indexOf(command === "init" ? '"$FT" init ' : '"$FT" api ensure-settings');
    assert.ok(at > 0, `install.sh に ${command} の呼び出しがありません`);
    // 呼び出しは行継続で複数行に跨る
    const invocation = INSTALL_SH.slice(at, at + 400).split("\n").slice(0, 4).join("\n");
    assert.match(
      invocation,
      /--agent "\$\{AGENTS\/\/ \/,\}"/,
      `${command} の呼び出しに --agent がありません(CLI が独自判定に落ちます)`,
    );
  });
}

test("CLI 側は --agent を受け取る口を持つ", () => {
  const files = {
    "Sources/fleetest/ApiEnsureSettingsCommand.swift": "ensure-settings",
    "Sources/fleetest/InitCommand.swift": "init",
  };
  for (const [file, label] of Object.entries(files)) {
    const source = readFileSync(path.join(ROOT, file), "utf8");
    assert.match(source, /var agent: String\?/, `${label} に --agent オプションがありません`);
    assert.match(
      source,
      /AgentIntegration\.parse\(agent,/,
      `${label} が --agent を AgentIntegration.parse で解釈していません`,
    );
  }
});

// --- ランナー機には入口ファイルを置かない -------------------------------------
// 入口(CLAUDE.md / AGENTS.md)は**人が開く機械**のためのもので、ランナー機には要らない。
// エージェントの規約位置が増えたら抑止フラグも増えるので、Swift の実引数と docs の記載が
// ドリフトする(実際に `--skip-agents-md` を足したとき docs 側が2箇所とも古いまま残った)。

test("RemoteSetup.installArgs が全エージェントの入口を抑止する", () => {
  const swift = readFileSync(path.join(ROOT, "Sources/FTCore/RemoteSetup.swift"), "utf8");
  for (const { agent, flag } of [
    { agent: "claude", flag: "--skip-claude-md" },
    { agent: "codex", flag: "--skip-agents-md" },
  ]) {
    assert.ok(swift.includes(`"${flag}"`),
      `RemoteSetup.installArgs に ${agent} の入口抑止 ${flag} がありません`);
  }
});

test("ランナーの install 引数が docs と一致する(片方だけ変えない)", () => {
  const swift = readFileSync(path.join(ROOT, "Sources/FTCore/RemoteSetup.swift"), "utf8");
  const body = swift.slice(swift.indexOf("func installArgs"));
  const flags = [...body.slice(0, body.indexOf("\n    }")).matchAll(/"(--[a-z-]+)"/g)]
    .map((m) => m[1])
    .filter((f) => f.startsWith("--skip") || f === "--no-next-steps");
  assert.ok(flags.length >= 4, `installArgs から抑止フラグを抽出できません: ${flags}`);
  for (const doc of ["docs/remote-runner.md", "docs/remote-runner-setup.md"]) {
    const source = readFileSync(path.join(ROOT, doc), "utf8");
    const missing = flags.filter((f) => !source.includes(f));
    // --no-next-steps は setup 手順書には出ないので、そちらだけ緩める
    const required = doc.endsWith("remote-runner.md") ? missing : missing.filter((f) => f !== "--no-next-steps");
    assert.deepEqual(required, [],
      `${doc} が installArgs の抑止フラグを載せていません: ${required.join(", ")}`);
  }
});

// --- レビューで出た3つの穴の回帰 ------------------------------------------------

test("CODEX_CONFIG は --skip-mcp のブロックの外で定義する", () => {
  // ステップ7.7(サンドボックス判定)も参照するので、7.5 の else の中で定義すると
  // `--skip-mcp` のときに set -u で落ちる([fail] 行も出ないまま exit 1)。
  // RemoteSetupPlan.installArgs は常に --skip-mcp を渡すので、~/.codex のある
  // ランナー機で必ず踏む
  const assign = INSTALL_SH.indexOf('CODEX_CONFIG="');
  const guard = INSTALL_SH.indexOf('if [ "$DO_MCP" = "0" ]');
  assert.ok(assign > 0, "install.sh に CODEX_CONFIG の定義がありません");
  assert.ok(guard > 0, "install.sh に --skip-mcp のガードがありません");
  assert.ok(assign < guard,
    "CODEX_CONFIG が --skip-mcp のブロックの中で定義されています(7.7 が set -u で落ちます)");
});

test("clone 構成では WORK_DIR 側の手掛かりを判定に使わない", () => {
  // クローン自身が .claude/ も .agents/ も CLAUDE.md も持っている(このツールのアダプタで
  // あって、受け手が Codex を使っている証拠ではない)。見るとどのクローンでも codex と
  // 判定され、クローンの中に AGENTS.md を書いて次の更新を pull ガードで止める
  const block = detectionBlock("Scripts/install.sh", INSTALL_SH);
  const cloneBranch = block.slice(block.indexOf('LAYOUT" = "clone"'));
  assert.ok(cloneBranch.length > 0, "clone 構成の分岐がありません");
  const untilElse = cloneBranch.slice(0, cloneBranch.indexOf("else"));
  assert.ok(!untilElse.includes("$WORK_DIR"),
    "clone 構成の判定が WORK_DIR 側の手掛かりを見ています(どのクローンでも codex になります)");
  assert.ok(untilElse.includes("$HOME/.codex") && untilElse.includes("$HOME/.claude"),
    "clone 構成の判定がホーム側の手掛かりを見ていません");
});

test("判定結果を state.json に残し、auto のときは引き継ぐ", () => {
  // 引き継がないと `--agent codex` で入れた受け手が更新のたびに自動判定へ戻り、
  // ホームに ~/.claude があるだけで .claude/settings.json と CLAUDE.md が湧く
  // (update.sh は install.sh を呼び直すだけなので、決定はここで持つ)
  assert.match(INSTALL_SH, /"agents":\s*"\$AGENTS"/,
    "install.sh が state.json に判定結果(agents)を残していません");
  const block = detectionBlock("Scripts/install.sh", INSTALL_SH);
  const auto = block.slice(block.indexOf("auto)"));
  assert.ok(auto.includes("state.json"),
    "auto の判定が state.json の記録を先に読んでいません(更新のたびに決定が揺れます)");
});

test("入口ファイルはクローンの中には書かない(未追跡でも)", () => {
  // 追跡の有無で判定すると、**まだ存在しない AGENTS.md が素通り**する
  // (CLAUDE.md はクローンの追跡ファイルなので追跡判定でも止まっていた)。
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
      'write_entry_point "AGENTS.md" "\\$" "AGENTS.md"',
    ].join("\n"));

    const inClone = execFileSync("bash", [script, clone, clone], { encoding: "utf8" });
    assert.match(inClone, /AGENTS\.md\|skip/, `クローンの中に書こうとしています: ${inClone}`);
    assert.ok(!existsSync(path.join(clone, "AGENTS.md")), "クローンに AGENTS.md が作られました");

    const outsideClone = execFileSync("bash", [script, outside, clone], { encoding: "utf8" });
    assert.match(outsideClone, /AGENTS\.md\|ok/, `クローンの外なのに書いていません: ${outsideClone}`);
    assert.ok(existsSync(path.join(outside, "AGENTS.md")), "クローン外の入口が作られていません");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// --- 実機検証(2026-08-27)で分かった構造を固定する --------------------------------

test("clone 構成の例外が Swift とシェルの両方にある", () => {
  // 片方だけに入れると「規則は1つ」という前提が静かに崩れる。**シグナル名の一致だけを
  // 見ていたテストはこの乖離を素通しした**ので、例外そのものを両側で見る
  assert.match(SWIFT, /ignoringWorkspaceSignals/,
    "AgentIntegration に clone 構成の例外がありません(シェル側だけにあります)");
  assert.match(SWIFT, /isExternalPackage/,
    "Swift 側が「クローン自身か」を判定していません");
  const block = detectionBlock("Scripts/install.sh", INSTALL_SH);
  assert.ok(block.includes('LAYOUT" = "clone"'),
    "install.sh に clone 構成の例外がありません(Swift 側だけにあります)");
});

test("シェルは知らないエージェント名を素通しさせない", () => {
  // 素通しすると has_agent がどれにも当たらず、MCP 登録も入口も行われないまま [ok] で終わる
  // (state.json 経由で実際に踏んだ)。Swift の parsed() も unknown を返して呼び手に警告させる
  assert.match(INSTALL_SH, /valid_agents\(\)/, "install.sh に検証関数がありません");
  assert.match(INSTALL_SH, /case "\$candidate" in claude\|codex\)/,
    "install.sh の検証が既知の名前だけを通していません");
  assert.match(SWIFT, /func parsed\(/, "AgentIntegration に unknown を返す parsed() がありません");
});

test("判定の出所を record に出し、--agent auto で再判定できる", () => {
  // pin が見えないと「後から Claude Code を入れたのに何も起きない」で詰まる
  assert.match(INSTALL_SH, /AGENT_SOURCE=/, "判定の出所を持っていません");
  assert.match(INSTALL_SH, /record "agent" ok "\$AGENTS — \$AGENT_SOURCE"/,
    "record が判定の出所を出していません");
  const block = detectionBlock("Scripts/install.sh", INSTALL_SH);
  assert.match(block, /auto\)\s+detect_agents/,
    "--agent auto を明示しても再判定していません(pin から抜け出せなくなります)");
});

test("サンドボックス判定は danger-full-access 以外を OK にしない", () => {
  // **false green を作らない**。実測(2026-08-27): workspace-write では SwiftPM の入れ子
  // sandbox-exec で `swift build` が起動できず、simctl も CoreSimulatorService に届かない。
  // network_access / writable_roots を積んでも直らないので、それらを根拠に OK を返してはいけない
  const start = INSTALL_SH.indexOf("# ---- 7.7");
  const section = INSTALL_SH.slice(start, INSTALL_SH.indexOf("# ---- 5. プロファイル", start));
  assert.ok(start > 0 && section.length > 0, "ステップ7.7 がありません");
  const okLines = section.split("\n").filter((l) => l.includes('print("OK'));
  assert.equal(okLines.length, 1, `OK を返す分岐は1つだけ: ${okLines.join(" / ")}`);
  assert.match(okLines[0], /danger-full-access/, "danger-full-access 以外で OK を返しています");
  // **判定の入力**に使っていないことを見る(案内の本文に「これでは直らない」と書くのは正しい)
  assert.ok(!/data\.get\("sandbox_workspace_write"/.test(section),
    "判定が sandbox_workspace_write を根拠にしています(実測では直らないので false green になります)");
  // MCP は影響を受けないという事実を案内に含める(取り違えると切り分けを誤らせる)
  assert.match(section, /MCP server runs outside the sandbox/,
    "MCP がサンドボックス外である旨が案内にありません");
});

test("update.sh のコピー対象が install-skill.sh の一覧と揃っている", () => {
  // スキル一覧は3箇所(install-skill.sh の SKILLS / 正典ディレクトリ / update.sh の
  // COPIED_SKILLS)。増やす・改名するときに update.sh を忘れると、コピー配置の受け手だけ
  // 取り残される
  const updateSh = readFileSync(path.join(ROOT, "Scripts/update.sh"), "utf8");
  const list = (source, name) => {
    const m = source.match(new RegExp(`${name}="([^"]+)"`));
    assert.ok(m, `${name} が見つかりません`);
    return m[1].split(/\s+/).filter(Boolean).sort();
  };
  const declared = list(INSTALL_SKILL_SH, "SKILLS");
  const copied = list(updateSh, "COPIED_SKILLS");
  const canon = readdirSync(path.join(ROOT, ".claude", "skills"), { withFileTypes: true })
    .filter((d) => d.isDirectory()).map((d) => d.name).sort();
  assert.deepEqual(declared, canon, "install-skill.sh の SKILLS と正典が食い違っています");
  // fleetest-setup だけは写さない(受け手のそれは init が生成した別内容)
  assert.deepEqual(copied, declared.filter((n) => n !== "fleetest-setup"),
    "COPIED_SKILLS が SKILLS から fleetest-setup を除いたものになっていません");
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
