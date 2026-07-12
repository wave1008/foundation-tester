// exploreModel.test.mjs
// exploreModel.ts(isExploreEvent/進捗文言/完了通知文言/入力検証/デバイス選択アイテム)の
// ユニットテスト。node:test で実行する。esbuild が "../src/exploreModel"(拡張子なし)を
// exploreModel.ts に解決してバンドルする。
//
// 末尾に、mock-explore.mjs を実際に spawn して NdjsonParser → exploreModel に通す
// 統合テストを含む(monitorModel.test.mjs の mock-monitor.mjs 統合テストと同じ方針)。

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { test } from "node:test";
import { NdjsonParser } from "../src/ndjson";
import {
  buildDeviceQuickPickItems,
  buildFinishedNotification,
  DEFAULT_MAX_STEPS,
  formatExploreLogLine,
  formatStepProgressMessage,
  isExploreEvent,
  isExploreWebviewEnvelope,
  parseMaxSteps,
  validateBundleIdInput,
  validateGoalInput,
  validateMaxStepsInput,
} from "../src/exploreModel";

const MOCK_EXPLORE = path.resolve(process.cwd(), "test", "fixtures", "mock-explore.mjs");

// ---- isExploreEvent: 正常5種 ----

test("isExploreEvent: exploreStarted の正常な値を true と判定する", () => {
  const value = {
    kind: "exploreStarted",
    project: "SampleApp",
    bundleID: "com.example.app",
    goal: "ログインする",
    maxSteps: 25,
    platform: "ios",
  };
  assert.equal(isExploreEvent(value), true);
});

test("isExploreEvent: exploreStep の正常な値を true と判定する", () => {
  assert.equal(
    isExploreEvent({ kind: "exploreStep", step: 1, maxSteps: 25, description: "ログイン画面を開く" }),
    true,
  );
});

test("isExploreEvent: exploreValidating の正常な値を true と判定する", () => {
  assert.equal(isExploreEvent({ kind: "exploreValidating", message: "生成コードをビルド検証中" }), true);
});

test("isExploreEvent: exploreFinished の正常な値(3種の outcome いずれも)を true と判定する", () => {
  for (const outcome of ["completed", "gaveUp", "stepLimitReached"]) {
    const value = {
      kind: "exploreFinished",
      outcome,
      detail: null,
      stepsTaken: 5,
      file: "/tmp/Generated/X.swift",
      scenarioID: "X.T0001",
      quarantined: false,
    };
    assert.equal(isExploreEvent(value), true, `outcome=${outcome}`);
  }
});

test("isExploreEvent: exploreFinished は detail/file/scenarioID が null でも true", () => {
  const value = {
    kind: "exploreFinished",
    outcome: "stepLimitReached",
    detail: null,
    stepsTaken: 25,
    file: null,
    scenarioID: null,
    quarantined: false,
  };
  assert.equal(isExploreEvent(value), true);
});

test("isExploreEvent: error の正常な値を true と判定する", () => {
  assert.equal(isExploreEvent({ kind: "error", message: "FM が利用できません" }), true);
});

// ---- isExploreEvent: 不正 ----

test("isExploreEvent: 未知の kind・非オブジェクトは false", () => {
  assert.equal(isExploreEvent({ kind: "exploreSomethingUnknown" }), false);
  assert.equal(isExploreEvent({}), false);
  assert.equal(isExploreEvent(null), false);
  assert.equal(isExploreEvent("not an object"), false);
  assert.equal(isExploreEvent(undefined), false);
});

test("isExploreEvent: exploreStarted はフィールド欠落/型不一致で false", () => {
  assert.equal(isExploreEvent({ kind: "exploreStarted", project: "P" }), false);
  assert.equal(
    isExploreEvent({
      kind: "exploreStarted",
      project: "P",
      bundleID: "b",
      goal: "g",
      maxSteps: "25",
      platform: "ios",
    }),
    false,
  );
});

test("isExploreEvent: exploreStep は step/maxSteps/description の型不一致で false", () => {
  assert.equal(isExploreEvent({ kind: "exploreStep", step: "1", maxSteps: 25, description: "x" }), false);
  assert.equal(isExploreEvent({ kind: "exploreStep", step: 1, maxSteps: 25 }), false);
});

test("isExploreEvent: exploreFinished は outcome が未知の語彙なら false", () => {
  const value = {
    kind: "exploreFinished",
    outcome: "unknownOutcome",
    detail: null,
    stepsTaken: 1,
    file: null,
    scenarioID: null,
    quarantined: false,
  };
  assert.equal(isExploreEvent(value), false);
});

test("isExploreEvent: exploreFinished は quarantined が非boolean、stepsTaken が非数値なら false", () => {
  const base = {
    kind: "exploreFinished",
    outcome: "completed",
    detail: null,
    file: null,
    scenarioID: null,
  };
  assert.equal(isExploreEvent({ ...base, stepsTaken: 1, quarantined: "false" }), false);
  assert.equal(isExploreEvent({ ...base, stepsTaken: "1", quarantined: false }), false);
});

test("isExploreEvent: error は message が欠落/非文字列なら false", () => {
  assert.equal(isExploreEvent({ kind: "error" }), false);
  assert.equal(isExploreEvent({ kind: "error", message: 123 }), false);
});

// ---- formatStepProgressMessage / formatExploreLogLine ----

test("formatStepProgressMessage: '[n/N] description' 形式になる", () => {
  const message = formatStepProgressMessage({ kind: "exploreStep", step: 3, maxSteps: 25, description: "ログインボタンをタップ" });
  assert.equal(message, "[3/25] ログインボタンをタップ");
});

test("formatExploreLogLine: exploreStarted", () => {
  const line = formatExploreLogLine({
    kind: "exploreStarted",
    project: "SampleApp",
    bundleID: "com.example.app",
    goal: "ログインする",
    maxSteps: 25,
    platform: "ios",
  });
  assert.equal(line, "[explore] 開始: bundle=com.example.app goal=ログインする maxSteps=25 platform=ios");
});

test("formatExploreLogLine: exploreStep は formatStepProgressMessage と同じ内容を含む", () => {
  const event = { kind: "exploreStep", step: 2, maxSteps: 10, description: "検索する" };
  assert.equal(formatExploreLogLine(event), `[explore] ${formatStepProgressMessage(event)}`);
});

test("formatExploreLogLine: exploreValidating", () => {
  assert.equal(
    formatExploreLogLine({ kind: "exploreValidating", message: "生成コードをビルド検証中" }),
    "[explore] 生成コードをビルド検証中",
  );
});

test("formatExploreLogLine: exploreFinished は file/detail があれば含み、無ければ省く", () => {
  const withFileAndDetail = formatExploreLogLine({
    kind: "exploreFinished",
    outcome: "gaveUp",
    detail: "対象要素が見つかりません",
    stepsTaken: 4,
    file: "/tmp/X.swift",
    scenarioID: "X.T0001",
    quarantined: false,
  });
  assert.equal(
    withFileAndDetail,
    "[explore] 終了: outcome=gaveUp stepsTaken=4 quarantined=false file=/tmp/X.swift detail=対象要素が見つかりません",
  );

  const withoutFile = formatExploreLogLine({
    kind: "exploreFinished",
    outcome: "stepLimitReached",
    detail: null,
    stepsTaken: 25,
    file: null,
    scenarioID: null,
    quarantined: false,
  });
  assert.equal(withoutFile, "[explore] 終了: outcome=stepLimitReached stepsTaken=25 quarantined=false");
});

test("formatExploreLogLine: error", () => {
  assert.equal(formatExploreLogLine({ kind: "error", message: "接続できません" }), "[explore] エラー: 接続できません");
});

// ---- buildFinishedNotification ----

test("buildFinishedNotification: completed(quarantined=false) は info「探索完了(Nステップ)」", () => {
  const notification = buildFinishedNotification({
    kind: "exploreFinished",
    outcome: "completed",
    detail: null,
    stepsTaken: 7,
    file: "/tmp/X.swift",
    scenarioID: "X.T0001",
    quarantined: false,
  });
  assert.equal(notification.severity, "info");
  assert.equal(notification.message, "ftester: 探索完了(7ステップ)");
});

test("buildFinishedNotification: gaveUp/stepLimitReached(quarantined=false) は warning「未完了だがシナリオ生成」", () => {
  for (const outcome of ["gaveUp", "stepLimitReached"]) {
    const notification = buildFinishedNotification({
      kind: "exploreFinished",
      outcome,
      detail: null,
      stepsTaken: 25,
      file: "/tmp/X.swift",
      scenarioID: "X.T0001",
      quarantined: false,
    });
    assert.equal(notification.severity, "warning", outcome);
    assert.equal(notification.message, "ftester: 探索は未完了ですがシナリオを生成しました(TODOコメント付き)。", outcome);
  }
});

test("buildFinishedNotification: quarantined=true は outcome に関わらず隔離の warning を優先する", () => {
  for (const outcome of ["completed", "gaveUp", "stepLimitReached"]) {
    const notification = buildFinishedNotification({
      kind: "exploreFinished",
      outcome,
      detail: null,
      stepsTaken: 3,
      file: "/tmp/_disabled/X.swift",
      scenarioID: "X.T0001",
      quarantined: true,
    });
    assert.equal(notification.severity, "warning", outcome);
    assert.equal(notification.message, "ftester: ビルド検証に失敗したため _disabled/ に隔離されました。", outcome);
  }
});

// ---- 入力値検証 ----

test("validateBundleIdInput: 空文字/空白のみはエラーメッセージ、非空は undefined", () => {
  assert.equal(typeof validateBundleIdInput(""), "string");
  assert.equal(typeof validateBundleIdInput("   "), "string");
  assert.equal(validateBundleIdInput("com.example.app"), undefined);
});

test("validateGoalInput: 空文字/空白のみはエラーメッセージ、非空は undefined", () => {
  assert.equal(typeof validateGoalInput(""), "string");
  assert.equal(typeof validateGoalInput("  "), "string");
  assert.equal(validateGoalInput("ログインする"), undefined);
});

test("validateMaxStepsInput: 1〜50の整数は undefined(妥当)", () => {
  assert.equal(validateMaxStepsInput("1"), undefined);
  assert.equal(validateMaxStepsInput("25"), undefined);
  assert.equal(validateMaxStepsInput("50"), undefined);
});

test("validateMaxStepsInput: 範囲外・非整数・空はエラーメッセージ", () => {
  assert.equal(typeof validateMaxStepsInput("0"), "string");
  assert.equal(typeof validateMaxStepsInput("51"), "string");
  assert.equal(typeof validateMaxStepsInput("-1"), "string");
  assert.equal(typeof validateMaxStepsInput("abc"), "string");
  assert.equal(typeof validateMaxStepsInput("3.5"), "string");
  assert.equal(typeof validateMaxStepsInput(""), "string");
  assert.equal(typeof validateMaxStepsInput("   "), "string");
});

test("parseMaxSteps: 文字列を整数に変換する", () => {
  assert.equal(parseMaxSteps("25"), 25);
  assert.equal(parseMaxSteps(" 7 "), 7);
});

test("DEFAULT_MAX_STEPS は 1〜50 の範囲内", () => {
  assert.equal(validateMaxStepsInput(String(DEFAULT_MAX_STEPS)), undefined);
});

// ---- buildDeviceQuickPickItems ----

test("buildDeviceQuickPickItems: connected は detail が undefined(注意書き無し)", () => {
  const items = buildDeviceQuickPickItems([
    { id: "ios:シミュ1", name: "シミュ1", platform: "ios", state: "connected", detail: "port 8127", port: 8127, serial: null },
  ]);
  assert.equal(items.length, 1);
  assert.equal(items[0].label, "シミュ1");
  assert.ok(items[0].description.includes("ios"));
  assert.ok(items[0].description.includes("接続済み"));
  assert.equal(items[0].detail, undefined);
  assert.equal(items[0].device.name, "シミュ1");
});

test("buildDeviceQuickPickItems: connected 以外(booted/offline/unknown)は detail に注意書きが付く", () => {
  const items = buildDeviceQuickPickItems([
    { id: "ios:シミュ2", name: "シミュ2", platform: "ios", state: "booted", detail: "", port: 8128, serial: null },
    { id: "android:エミュ1", name: "エミュ1", platform: "android", state: "offline", detail: "", port: null, serial: null },
    { id: "config-fallback", name: "設定のデバイス", platform: "ios", state: "unknown", detail: "", port: null, serial: null },
  ]);
  for (const item of items) {
    assert.ok(item.detail && item.detail.includes("⚠"), JSON.stringify(item));
  }
});

// ---- isExploreWebviewEnvelope ----

test("isExploreWebviewEnvelope: type:'explore' + 正常な ExploreFromWebviewMessage を true と判定する", () => {
  assert.equal(isExploreWebviewEnvelope({ type: "explore", message: { type: "refreshDevices" } }), true);
  assert.equal(isExploreWebviewEnvelope({ type: "explore", message: { type: "cancel" } }), true);
  assert.equal(isExploreWebviewEnvelope({ type: "explore", message: { type: "openFile" } }), true);
  assert.equal(isExploreWebviewEnvelope({ type: "explore", message: { type: "selectDevice", id: "ios:x" } }), true);
  assert.equal(
    isExploreWebviewEnvelope({
      type: "explore",
      message: { type: "start", bundleId: "com.example.app", goal: "ログインする", maxSteps: "25" },
    }),
    true,
  );
});

test("isExploreWebviewEnvelope: type が 'explore' 以外、または message が不正なら false", () => {
  assert.equal(isExploreWebviewEnvelope({ type: "live", message: { type: "refreshDevices" } }), false);
  assert.equal(isExploreWebviewEnvelope({ type: "explore", message: { type: "unknown" } }), false);
  assert.equal(isExploreWebviewEnvelope({ type: "explore" }), false);
  assert.equal(isExploreWebviewEnvelope(null), false);
  assert.equal(isExploreWebviewEnvelope({}), false);
});

test("isExploreWebviewEnvelope: start はフィールド欠落/型不一致で false(maxSteps は文字列のまま検証前)", () => {
  assert.equal(
    isExploreWebviewEnvelope({
      type: "explore",
      message: { type: "start", bundleId: "com.example.app", goal: "ログインする" },
    }),
    false,
  );
  assert.equal(
    isExploreWebviewEnvelope({
      type: "explore",
      message: { type: "start", bundleId: "com.example.app", goal: "ログインする", maxSteps: 25 },
    }),
    false,
  );
});

// ---- 統合: mock-explore.mjs → NdjsonParser → isExploreEvent ----

test("統合: mock-explore.mjs(既定パターン)の出力を NdjsonParser → isExploreEvent に通すと started→step×3→validating→finished の順のイベント列になる", async () => {
  const events = await runMockExplore(["--bundle", "com.example.app", "--goal", "ログインする", "--max-steps", "10", "--delay-ms", "1"]);

  assert.deepEqual(
    events.map((e) => e.kind),
    ["exploreStarted", "exploreStep", "exploreStep", "exploreStep", "exploreValidating", "exploreFinished"],
  );
  assert.equal(events[0].bundleID, "com.example.app");
  assert.equal(events[0].maxSteps, 10);
  assert.equal(events[1].step, 1);
  assert.equal(events[3].step, 3);
  assert.equal(events[5].outcome, "completed");
  assert.equal(events[5].quarantined, false);
  assert.equal(events[5].stepsTaken, 3);
});

test("統合: mock-explore.mjs --outcome gaveUp --quarantined は quarantined:true の exploreFinished で終わる", async () => {
  const events = await runMockExplore([
    "--bundle",
    "com.example.app",
    "--goal",
    "ログインする",
    "--outcome",
    "gaveUp",
    "--quarantined",
    "--delay-ms",
    "1",
  ]);
  const finished = events[events.length - 1];
  assert.equal(finished.kind, "exploreFinished");
  assert.equal(finished.outcome, "gaveUp");
  assert.equal(finished.quarantined, true);
  assert.ok(finished.detail && finished.detail.length > 0);
});

test("統合: mock-explore.mjs --fail は exploreStarted を出さず error のみで exit 1", async () => {
  const { events, exitCode } = await runMockExploreWithExitCode(["--bundle", "b", "--goal", "g", "--fail"]);
  assert.equal(exitCode, 1);
  assert.equal(events.length, 1);
  assert.equal(events[0].kind, "error");
  assert.ok(events[0].message.length > 0);
});

/** mock-explore.mjs を spawn し、stdout を NdjsonParser → isExploreEvent に通して収集したイベント配列を返す。 */
function runMockExplore(mockArgs) {
  return runMockExploreWithExitCode(mockArgs).then((result) => result.events);
}

function runMockExploreWithExitCode(mockArgs) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [MOCK_EXPLORE, ...mockArgs], {
      cwd: path.dirname(MOCK_EXPLORE),
      stdio: ["ignore", "pipe", "pipe"],
    });

    const events = [];
    const parser = new NdjsonParser(
      (value) => {
        if (isExploreEvent(value)) {
          events.push(value);
        }
      },
      () => {
        // 非JSON行は無視する(このテストでは検証対象外)
      },
    );

    const timer = setTimeout(() => {
      proc.kill("SIGKILL");
      reject(new Error("mock-explore.mjs からの応答がタイムアウトしました"));
    }, 5000);

    proc.stdout.on("data", (chunk) => parser.push(chunk));
    proc.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    proc.on("close", (exitCode) => {
      clearTimeout(timer);
      parser.end();
      resolve({ events, exitCode });
    });
  });
}
