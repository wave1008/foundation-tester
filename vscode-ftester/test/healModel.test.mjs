// healModel.test.mjs
// healModel.ts(HealFixCollector・検証/diffロジック・apply-heal 契約の変換)のユニットテスト。
// node:test で実行する。esbuild が "../src/healModel"(拡張子なし)を healModel.ts に解決して
// バンドルする。
//
// 末尾に、mock-runner.mjs(--pattern heal)を実際に spawn して NdjsonParser → HealFixCollector に
// 通す統合テストを1本含む(healReviewPanel.ts が RunEventBus 経由で行う配線の縮小版。
// runReducer.test.mjs の mock-runner 統合テストと同じ方針)。

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { test } from "node:test";
import { NdjsonParser } from "../src/ndjson";
import {
  buildApplyHealRequest,
  buildPreviewAfterLine,
  computeNewComment,
  healFixId,
  HealFixCollector,
  isValidComment,
  isValidSelector,
  parseApplyHealResponse,
  selectorOccursOnce,
  toApplyHealFix,
  trailingComment,
} from "../src/healModel";

const MOCK_RUNNER = path.resolve(process.cwd(), "test", "fixtures", "mock-runner.mjs");

// ---- healFixId ----------------------------------------------------------------------

test("healFixId: scenarioID|file:line|oldSelector の形式になる(GUI の HealFix.id と同形式)", () => {
  const id = healFixId({ scenarioID: "S.T1", file: "Projects/P/Scenarios/S.swift", line: 12, oldSelector: "#old" });
  assert.equal(id, "S.T1|Projects/P/Scenarios/S.swift:12|#old");
});

// ---- HealFixCollector ----------------------------------------------------------------

test("HealFixCollector: fixSuggestion を収集し、必須フィールドが揃った HealFix を返す", () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  collector.collect({
    kind: "fixSuggestion",
    scenario: "S.T1",
    description: 'tap "#old_id"',
    detail: "ロケータが変化した可能性があります",
    file: "Projects/P/Scenarios/S.swift",
    line: 12,
    oldSelector: "#old_id",
    newSelector: "#new_id",
  });
  const list = collector.list();
  assert.equal(list.length, 1);
  assert.deepEqual(list[0], {
    scenarioID: "S.T1",
    file: "Projects/P/Scenarios/S.swift",
    line: 12,
    oldSelector: "#old_id",
    newSelector: "#new_id",
    message: "ロケータが変化した可能性があります",
    command: 'tap "#old_id"',
  });
});

test("HealFixCollector: message は detail が無ければ description、どちらも無ければ空文字列", () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  collector.collect({
    kind: "fixSuggestion",
    scenario: "S.T1",
    description: 'tap "#old_id"',
    file: "a.swift",
    line: 1,
    oldSelector: "#old_id",
    newSelector: "#new_id",
  });
  collector.collect({
    kind: "fixSuggestion",
    scenario: "S.T2",
    file: "a.swift",
    line: 2,
    oldSelector: "#old2",
    newSelector: "#new2",
  });
  const byScenario = Object.fromEntries(collector.list().map((f) => [f.scenarioID, f]));
  assert.equal(byScenario["S.T1"].message, 'tap "#old_id"');
  assert.equal(byScenario["S.T2"].message, "");
});

test("HealFixCollector: scenario/file/line/oldSelector/newSelector のいずれかが欠けるイベントは無視する", () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  const base = {
    kind: "fixSuggestion",
    scenario: "S.T1",
    file: "a.swift",
    line: 1,
    oldSelector: "#old",
    newSelector: "#new",
  };
  for (const key of ["scenario", "file", "line", "oldSelector", "newSelector"]) {
    const event = { ...base };
    delete event[key];
    collector.collect(event);
  }
  assert.equal(collector.list().length, 0);
});

test("HealFixCollector: 同一id(scenario/file/line/oldSelector が同一)は重複排除し、後勝ちで上書きする", () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  const base = { kind: "fixSuggestion", scenario: "S.T1", file: "a.swift", line: 1, oldSelector: "#old" };
  collector.collect({ ...base, newSelector: "#new1", detail: "1回目" });
  collector.collect({ ...base, newSelector: "#new2", detail: "2回目" });
  const list = collector.list();
  assert.equal(list.length, 1);
  assert.equal(list[0].newSelector, "#new2");
  assert.equal(list[0].message, "2回目");
});

test("HealFixCollector: begin(true)(dry-run)の間は collect() が候補を積まない", () => {
  const collector = new HealFixCollector();
  collector.begin(true);
  collector.collect({
    kind: "fixSuggestion",
    scenario: "S.T1",
    file: "a.swift",
    line: 1,
    oldSelector: "#old",
    newSelector: "#new",
  });
  assert.equal(collector.isEmpty(), true);
});

test("HealFixCollector: begin() を呼ぶと前回までの候補がクリアされる", () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  collector.collect({
    kind: "fixSuggestion",
    scenario: "S.T1",
    file: "a.swift",
    line: 1,
    oldSelector: "#old",
    newSelector: "#new",
  });
  assert.equal(collector.isEmpty(), false);
  collector.begin(false);
  assert.equal(collector.isEmpty(), true);
});

test("HealFixCollector: fixSuggestion 以外の kind は無視する", () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  collector.collect({ kind: "step", scenario: "S.T1", status: "passed" });
  assert.equal(collector.isEmpty(), true);
});

// ---- selectorOccursOnce ---------------------------------------------------------------

test("selectorOccursOnce: 引用符付きセレクタがちょうど1回なら true", () => {
  assert.equal(selectorOccursOnce('tap "#old_id" // ログイン', "#old_id"), true);
});

test("selectorOccursOnce: 0回(引用符無し部分一致は数えない)なら false", () => {
  assert.equal(selectorOccursOnce("tap #old_id", "#old_id"), false);
  assert.equal(selectorOccursOnce('tap "#other"', "#old_id"), false);
});

test("selectorOccursOnce: 2回以上(曖昧)なら false", () => {
  assert.equal(selectorOccursOnce('tap "#old_id" // "#old_id" も出現', "#old_id"), false);
});

// ---- isValidSelector / isValidComment --------------------------------------------------

test("isValidSelector: 空・「\"」を含む・改行を含む場合は false", () => {
  assert.equal(isValidSelector(""), false);
  assert.equal(isValidSelector('#a"b'), false);
  assert.equal(isValidSelector("#a\nb"), false);
  assert.equal(isValidSelector("#a\rb"), false);
});

test("isValidSelector: 通常のセレクタは true", () => {
  assert.equal(isValidSelector("#new_id"), true);
  assert.equal(isValidSelector("#a||.b||ラベル"), true);
});

test("isValidComment: 改行を含む場合のみ false(空文字列はコメント削除として許可)", () => {
  assert.equal(isValidComment(""), true);
  assert.equal(isValidComment("ふつうの説明"), true);
  assert.equal(isValidComment("a\nb"), false);
  assert.equal(isValidComment("a\rb"), false);
});

// ---- trailingComment(文字列リテラル内の // は無視する)-----------------------------------

test("trailingComment: 行末コメントの本文を前後空白除去して返す", () => {
  assert.equal(trailingComment('tap "#login_btn" // ログインボタンを押す'), "ログインボタンを押す");
});

test("trailingComment: コメントが無い行は undefined", () => {
  assert.equal(trailingComment('tap "#login_btn"'), undefined);
});

test("trailingComment: 「//」がコメントのみ(本文空)なら undefined", () => {
  assert.equal(trailingComment('tap "#login_btn" //'), undefined);
});

test("trailingComment: 文字列リテラル内の // はコメントと誤認しない", () => {
  assert.equal(trailingComment('open "https://example.com/path"'), undefined);
  assert.equal(
    trailingComment('open "https://example.com/path" // サイトを開く'),
    "サイトを開く",
  );
});

// ---- computeNewComment(null/空/非空の契約)----------------------------------------------

test("computeNewComment: プリフィルから変更が無ければ null(コメントは変更しない)", () => {
  assert.equal(computeNewComment("既存の説明", "既存の説明"), null);
  assert.equal(computeNewComment(undefined, ""), null);
  assert.equal(computeNewComment("  前後空白  ".trim(), "  前後空白  "), null);
});

test("computeNewComment: 変更されて空になれば空文字列(コメント削除の意思)", () => {
  assert.equal(computeNewComment("既存の説明", ""), "");
  assert.equal(computeNewComment("既存の説明", "   "), "");
});

test("computeNewComment: 変更されて非空ならトリム後の値", () => {
  assert.equal(computeNewComment("旧説明", "新しい説明"), "新しい説明");
  assert.equal(computeNewComment(undefined, "  新しい説明  "), "新しい説明");
});

// ---- buildPreviewAfterLine(diffプレビュー)-----------------------------------------------

test("buildPreviewAfterLine: セレクタのみ置換し、コメント未変更なら行末はそのまま", () => {
  const after = buildPreviewAfterLine(
    'tap "#old_id" // ログイン',
    "#old_id",
    "#new_id",
    "ログイン",
    "ログイン",
  );
  assert.equal(after, 'tap "#new_id" // ログイン');
});

test("buildPreviewAfterLine: コメントを追記する(元コメント無し行)", () => {
  const after = buildPreviewAfterLine('tap "#old_id"', "#old_id", "#new_id", undefined, "説明を追加");
  assert.equal(after, 'tap "#new_id"  // 説明を追加');
});

test("buildPreviewAfterLine: コメントを削除する(編集後が空)", () => {
  const after = buildPreviewAfterLine('tap "#old_id" // ログイン', "#old_id", "#new_id", "ログイン", "");
  assert.equal(after, 'tap "#new_id"');
});

test("buildPreviewAfterLine: 既存コメントの本文だけ差し替える(「//」直後の空白は保つ)", () => {
  const after = buildPreviewAfterLine(
    'tap "#old_id" //   ログイン',
    "#old_id",
    "#new_id",
    "ログイン",
    "新しい説明",
  );
  assert.equal(after, 'tap "#new_id" //   新しい説明');
});

// ---- apply-heal 契約(リクエスト組み立て・レスポンス解析)----------------------------------

test("buildApplyHealRequest: fixes をそのまま {fixes:[...]} に包む", () => {
  const fixes = [
    { scenarioID: "S.T1", file: "a.swift", line: 1, oldSelector: "#old", newSelector: "#new", newComment: null },
  ];
  assert.deepEqual(buildApplyHealRequest(fixes), { fixes });
});

test("parseApplyHealResponse: 正常な応答を解析する", () => {
  const response = parseApplyHealResponse({
    applied: ["S.T1|a.swift:1|#old"],
    failures: [{ id: "S.T1|a.swift:2|#old2", message: "セレクタが見つかりません" }],
  });
  assert.deepEqual(response, {
    applied: ["S.T1|a.swift:1|#old"],
    failures: [{ id: "S.T1|a.swift:2|#old2", message: "セレクタが見つかりません" }],
  });
});

test("parseApplyHealResponse: 不正な形(型不一致・欠落)は undefined を返す", () => {
  assert.equal(parseApplyHealResponse(null), undefined);
  assert.equal(parseApplyHealResponse({}), undefined);
  assert.equal(parseApplyHealResponse({ applied: "not-an-array", failures: [] }), undefined);
  assert.equal(parseApplyHealResponse({ applied: [1, 2], failures: [] }), undefined);
  assert.equal(parseApplyHealResponse({ applied: [], failures: [{ id: "x" }] }), undefined);
});

// ---- toApplyHealFix -------------------------------------------------------------------

test("toApplyHealFix: 有効な編集値から HealApplyFix を組み立てる", () => {
  const fix = toApplyHealFix(
    { scenarioID: "S.T1", file: "a.swift", line: 1, oldSelector: "#old" },
    "#new",
    "新しい説明",
    "旧説明",
  );
  assert.deepEqual(fix, {
    scenarioID: "S.T1",
    file: "a.swift",
    line: 1,
    oldSelector: "#old",
    newSelector: "#new",
    newComment: "新しい説明",
  });
});

test("toApplyHealFix: 不正なセレクタ・コメントは undefined を返す(二重の安全)", () => {
  assert.equal(
    toApplyHealFix({ scenarioID: "S.T1", file: "a.swift", line: 1, oldSelector: "#old" }, "", "説明", undefined),
    undefined,
  );
  assert.equal(
    toApplyHealFix(
      { scenarioID: "S.T1", file: "a.swift", line: 1, oldSelector: "#old" },
      "#new",
      "改行\nあり",
      undefined,
    ),
    undefined,
  );
});

// ---- 統合: mock-runner.mjs(heal パターン)→ NdjsonParser → HealFixCollector -----------------

test("統合: mock-runner.mjs(heal パターン)の出力から、重複排除された1件の候補が収集される", async () => {
  const collector = new HealFixCollector();
  collector.begin(false);
  await runMockThroughCollector(collector, ["--pattern", "heal", "--scenario", "統合.HealT1"]);

  const list = collector.list();
  assert.equal(list.length, 1);
  assert.equal(list[0].scenarioID, "統合.HealT1");
  assert.equal(list[0].oldSelector, "#old_id");
  assert.equal(list[0].newSelector, "#new_id");
  // 2件目(後勝ち)の detail が残る
  assert.match(list[0].message, /2回目/);
});

test("統合: mock-runner.mjs(heal パターン)でも begin(true)(dry-run)なら候補が収集されない", async () => {
  const collector = new HealFixCollector();
  collector.begin(true);
  await runMockThroughCollector(collector, ["--pattern", "heal", "--scenario", "統合.HealT2"]);

  assert.equal(collector.isEmpty(), true);
});

/**
 * mock-runner.mjs を spawn し、stdout を NdjsonParser に通して RunEvent を collector.collect() へ
 * 渡す(healReviewPanel.ts が RunEventBus 経由で行う配線の縮小版)。
 */
function runMockThroughCollector(collector, mockArgs) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [MOCK_RUNNER, ...mockArgs], {
      cwd: path.dirname(MOCK_RUNNER),
      stdio: ["ignore", "pipe", "pipe"],
    });

    const parser = new NdjsonParser(
      (value) => {
        if (value && typeof value === "object" && typeof value.kind === "string") {
          collector.collect(value);
        }
      },
      () => {
        // 非JSON行は無視する(このテストでは検証対象外)
      },
    );

    proc.stdout.on("data", (chunk) => parser.push(chunk));
    proc.on("error", reject);
    proc.on("close", () => {
      parser.end();
      resolve();
    });
  });
}
