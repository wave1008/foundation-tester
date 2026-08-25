// Scripts/preflight.sh --runner(ランナー機の前提判定。docs/remote-runner.md §5・§14)の契約検証。
//
// 検証する契約:
//   1. --runner の判定は読み取り専用(書き込み系コマンドを実行しない)。人間向けの助言文
//      (例: "run: sudo pmset -a sleep 0")は runner_manual+=(...) / kv(...) の**文字列リテラル**
//      としてのみ現れてよい。実行文として現れたら受け手の機械を勝手に変える。
//   2. 3つの終了コード(0/1/2)と3つの verdict 名(ready / needs-manual / blocked)が揃っている。
//   3. --runner を受け付ける引数解析と、--base の既定値 ~/ftester-runner がある
//      (Sources/ftester/FTester.swift 等の --remote-dir 既定と揃える契約。CLAUDE.md 参照)。
//
// process.cwd() は npm test 実行時に vscode-ftester ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const PREFLIGHT_SH = "Scripts/preflight.sh";
const PREFLIGHT_PATH = path.join(ROOT, PREFLIGHT_SH);

/** `--runner`(elif ブロック)の本文だけを取り出す。前後の共通ヘルパ・既定モードは含めない。 */
function runnerSection(source) {
  const startMarker = 'if [ "$MODE" = "runner" ]; then';
  const start = source.indexOf(startMarker);
  assert.ok(start >= 0, `${PREFLIGHT_SH} に ${startMarker} が見つかりません`);
  // 対応する fi は次の「既定モード」見出しコメントの直前にある一行 `fi`。
  const endMarker = "# ===================================================================================\n# 既定モード:";
  const end = source.indexOf(endMarker, start);
  assert.ok(end >= 0, `${PREFLIGHT_SH} で --runner ブロックの終端(既定モード見出し)が見つかりません`);
  return source.slice(start, end);
}

/**
 * 「実行文」だけを対象に書き込み系コマンドの有無を見る。人間向けの助言文
 * (`runner_manual+=("... run: sudo ...")` や `kv`/`say` の引数文字列)は対象から外す —
 * これらは表示されるだけで実行されない。`cond || runner_manual+=(...)` のように条件式と
 * 同一行に同居することがあるため、行頭一致ではなく「その行に runner_manual+=( / kv " /
 * say " が含まれるか」で判別する(ヒューリスティック。誤って実行文まで除外しないことは
 * 「フィルタが効きすぎていないこと」テストと破壊確認テストで担保する)。
 */
function operationalLines(section) {
  return section
    .split("\n")
    .filter((line) => {
      const trimmed = line.trim();
      if (trimmed === "" || trimmed.startsWith("#")) return false;
      if (trimmed.includes("runner_manual+=(")) return false;
      if (trimmed.startsWith("kv ")) return false;
      if (trimmed.startsWith("say ")) return false;
      return true;
    });
}

const FORBIDDEN_WRITE_PATTERNS = [
  /\bsudo /,
  /\bdefaults write/,
  /\brm /,
  /\bmkdir /,
  /\bpmset -a/,
  /\bfdesetup enable/,
];

test("--runner: 実行文に書き込み系コマンドが無い(読み取り専用の契約)", () => {
  const source = readFileSync(PREFLIGHT_PATH, "utf8");
  const section = runnerSection(source);
  const opLines = operationalLines(section);
  assert.ok(opLines.length > 0, "--runner ブロックから実行文を抽出できませんでした(抽出ロジックの見直しが必要)");

  for (const pattern of FORBIDDEN_WRITE_PATTERNS) {
    const hit = opLines.find((line) => pattern.test(line));
    assert.equal(
      hit,
      undefined,
      `--runner の実行文に書き込み系コマンド(${pattern})が見つかりました: "${hit}"\n` +
        "runner モードは読み取り専用の契約(docs/remote-runner.md §14「sudo/GUI が要る項目を実行しない」)。" +
        "助言文(runner_manual+=/kv/say の引数)なら operationalLines() のフィルタに追加すること。",
    );
  }
});

test("--runner: 助言文には想定どおり sudo pmset の文言が残っている(フィルタが効きすぎていないことの確認)", () => {
  // 上のテストが「何もかも除外して常に緑」になっていないかの陽性対照。
  const source = readFileSync(PREFLIGHT_PATH, "utf8");
  const section = runnerSection(source);
  assert.match(section, /runner_manual\+=\("system sleep is enabled.*sudo pmset -a sleep 0/);
});

/**
 * `--runner` 節が参照する変数は、同じ節(または共通部)で必ず代入されていること。
 *
 * `set -u` の下では未代入の参照は**その行を通ったときだけ**致命的に落ちる。判定文は
 * ready / needs-manual / blocked で分岐するので、**片方の経路にしか無い参照は他方を
 * 何度実行しても出ない**。実際 ready 行だけが `$tool_root_exists` 等を参照しており、
 * 手元(needs-manual)では出ず、ランナー機の1回目(ready)で `unbound variable` で落ち、
 * exit 1 = blocked と誤報した。
 *
 * 静的走査なので**「どこかで代入されているが、通った経路では代入されていない」形は見えない**。
 * そちらは判定より前に既定値を代入して構造的に防ぐ(この節の tool_root_exists 等がその形)。
 */
test("--runner: 参照する変数はすべて代入されている(set -u で経路依存に落ちない)", () => {
  const source = readFileSync(PREFLIGHT_PATH, "utf8");
  const section = runnerSection(source);
  const provided = new Set(["HOME", "PWD"]);   // シェル/環境が供給するもの

  // 代入の収集は**ファイル全体**から(共通部で代入され runner 節が参照するものがある)。
  // ただし **表示行は除く** —— `say "… tool_root_exists=$tool_root_exists"` のような
  // 出力文字列は `name=` を含むので、数えると「代入されている」と誤認して検知が死ぬ
  const codeLines = source.split("\n").filter((line) => {
    const t = line.trim();
    if (t === "" || t.startsWith("#")) return false;
    if (t.startsWith("say ") || t.startsWith("kv ") || t.startsWith("printf ")) return false;
    return !t.includes("+=(");   // 配列追加は下で別に拾う(引数の文字列に name= を含み得る)
  });
  const assigned = new Set(
    [...codeLines.join("\n").matchAll(/(?:^|[\s;&|(])(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)=/gm)]
      .map((m) => m[1]),
  );
  for (const m of source.matchAll(/^\s*([A-Za-z_][A-Za-z0-9_]*)\+=\(/gm)) assigned.add(m[1]);
  for (const m of source.matchAll(/\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b/g)) assigned.add(m[1]);
  for (const m of source.matchAll(/\bread\s+(?:-\w+\s+)*([A-Za-z_][A-Za-z0-9_]*)/g)) assigned.add(m[1]);

  const referenced = new Set(
    [...section.matchAll(/\$\{?#?([A-Za-z_][A-Za-z0-9_]*)/g)].map((m) => m[1]),
  );
  const unbound = [...referenced].filter((name) => !assigned.has(name) && !provided.has(name));
  assert.deepEqual(
    unbound,
    [],
    `--runner 節が代入していない変数を参照しています: ${unbound.join(", ")}\n` +
      "set -u の下では、その参照を通る経路(ready / needs-manual / blocked のどれか)でだけ落ちます。",
  );
});

test("verdict: 3終了コード(0/1/2)と3 verdict 名が揃っている", () => {
  const source = readFileSync(PREFLIGHT_PATH, "utf8");
  for (const code of ["exit 0", "exit 1", "exit 2"]) {
    assert.ok(source.includes(code), `${PREFLIGHT_SH} に ${code} がありません`);
  }
  for (const verdict of ["ready", "needs-manual", "blocked"]) {
    assert.ok(source.includes(verdict), `${PREFLIGHT_SH} に verdict 名 "${verdict}" がありません`);
  }
});

test("引数解析: --runner を受け付け、--base の既定値が ~/ftester-runner である", () => {
  const source = readFileSync(PREFLIGHT_PATH, "utf8");
  assert.match(source, /--runner\)/, `${PREFLIGHT_SH} が --runner を case 分岐で受け付けていません`);
  assert.match(source, /--base\)/, `${PREFLIGHT_SH} が --base を case 分岐で受け付けていません`);
  assert.match(
    source,
    /BASE=(["'])~\/ftester-runner\1/,
    `${PREFLIGHT_SH} の --base 既定値が "~/ftester-runner" になっていません` +
      "(CLI 側 --remote-dir の既定と揃える契約)",
  );
});

test("実行: bash Scripts/preflight.sh --runner が動く(構文とモード分岐そのものの生存確認)", () => {
  // 実マシンの状態に依存する項目(ログイン中か・スリープ設定等)があるので verdict の値までは
  // 断定しない。exit code が 0/1/2 のどれかに収まり、機械可読行が出ることだけ見る。
  let stdout = "";
  let exitCode = 0;
  try {
    stdout = execFileSync("bash", [PREFLIGHT_SH, "--runner"], { cwd: ROOT, encoding: "utf8" });
  } catch (err) {
    stdout = err.stdout ?? "";
    exitCode = err.status ?? -1;
  }
  assert.ok([0, 1, 2].includes(exitCode), `--runner の exit code が想定外です: ${exitCode}`);
  assert.match(stdout, /^verdict=(ready|needs-manual|blocked)$/m, "--runner の出力に verdict= 行がありません");
  assert.match(stdout, /^base=/m, "--runner の出力に base= 行がありません");
});

test("破壊確認: forbidden pattern を実行文に混入させると検知テストが落ちる(検知テスト自体の生存確認)", () => {
  const original = readFileSync(PREFLIGHT_PATH, "utf8");
  const marker = 'kv sshd "$sshd_ok"';
  assert.ok(original.includes(marker), "破壊対象のマーカー行が preflight.sh に見つかりません(リファクタで消えた?)");

  // 変異は**メモリ上の文字列だけ**に当てる。preflight.sh は追跡ファイルなので、テストが
  // 途中で死ぬと変異が working tree に残る(復元を finally に置いても kill には勝てない)
  const mutated = original.replace(marker, `${marker}\n  sudo pmset -a sleep 0`);
  const opLines = operationalLines(runnerSection(mutated));
  const hit = opLines.find((line) => /\bsudo /.test(line) || /\bpmset -a/.test(line));
  assert.notEqual(hit, undefined, "書き込みコマンドを混入させても検知ロジックが反応しませんでした(検知テストが無力)");
});
