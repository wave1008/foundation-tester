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
import { readFileSync } from "node:fs";
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
  const begin = source.indexOf('AGENT="auto"') >= 0 ? source.indexOf('if [ "$AGENT" = "auto" ]')
                                                    : source.indexOf('case "$AGENT_ARG" in');
  assert.ok(begin > 0, `${file} に自動判定ブロックが見つかりません`);
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
