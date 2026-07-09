// stepsModel.test.mjs
// buildStepTree (src/stepsModel.ts) のユニットテスト。node:test で実行する。
// esbuild が "../src/stepsModel"(拡張子なし)を stepsModel.ts に解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import { buildStepTree } from "../src/stepsModel";

/** テスト用の StepRow を最小限の指定で組み立てるヘルパー。 */
function step(overrides) {
  return {
    index: 1,
    scene: 1,
    sceneTitle: "シーン1",
    section: "action",
    command: "tap \"#btn\"",
    comment: null,
    generatedComment: null,
    file: "Projects/P/Scenarios/S.swift",
    line: 10,
    ...overrides,
  };
}

test("scene ごとにグループ化される", () => {
  const steps = [
    step({ index: 1, scene: 1, sceneTitle: "ログインできる", command: "launch app" }),
    step({ index: 2, scene: 1, sceneTitle: "ログインできる", command: "tap \"#login\"" }),
    step({ index: 3, scene: 2, sceneTitle: "エラー表示", command: "type \"#pw\" \"x\"" }),
  ];

  const scenes = buildStepTree(steps);

  assert.equal(scenes.length, 2);
  assert.equal(scenes[0].scene, 1);
  assert.equal(scenes[0].label, "scene 1: ログインできる");
  assert.equal(scenes[0].steps.length, 2);
  assert.equal(scenes[1].scene, 2);
  assert.equal(scenes[1].label, "scene 2: エラー表示");
  assert.equal(scenes[1].steps.length, 1);

  // ステップ側のノードも index/command/label が期待どおりに変換されていること
  assert.deepEqual(
    scenes[0].steps.map((s) => s.label),
    ['1. launch app', '2. tap "#login"'],
  );
});

test("description は comment を優先し、無ければ generatedComment、どちらも無ければ空文字列", () => {
  const steps = [
    step({ index: 1, comment: "ソースのコメント", generatedComment: "生成された説明" }),
    step({ index: 2, comment: null, generatedComment: "生成された説明のみ" }),
    step({ index: 3, comment: null, generatedComment: null }),
  ];

  const [scene] = buildStepTree(steps);

  assert.equal(scene.steps[0].description, "ソースのコメント");
  assert.equal(scene.steps[1].description, "生成された説明のみ");
  assert.equal(scene.steps[2].description, "");

  // tooltip は「区分: <section>」に加えて comment/generatedComment があれば全文を含む
  assert.equal(scene.steps[0].tooltip, "区分: action\nソースのコメント");
  assert.equal(scene.steps[1].tooltip, "区分: action\n生成された説明のみ");
  assert.equal(scene.steps[2].tooltip, "区分: action");
});

test("空の steps 配列では空配列を返す", () => {
  assert.deepEqual(buildStepTree([]), []);
});

test("scene の出現順序を保持する(シーン番号でソートし直さない)", () => {
  // シーン番号が 2 → 1 → 2 の順で出現する(通常の dry-run では起きないが、
  // グループ化ロジックが「出現順」であって「シーン番号順」でないことを検証する)。
  const steps = [
    step({ index: 1, scene: 2, sceneTitle: "シーン2", command: "cmd-a" }),
    step({ index: 2, scene: 1, sceneTitle: "シーン1", command: "cmd-b" }),
    step({ index: 3, scene: 2, sceneTitle: "シーン2", command: "cmd-c" }),
  ];

  const scenes = buildStepTree(steps);

  // グループの並び順は最初に出現したシーン番号の順(2 → 1)
  assert.deepEqual(scenes.map((s) => s.scene), [2, 1]);
  // scene 2 グループの中では、入力の並び順(cmd-a, cmd-c)がそのまま保持される
  assert.deepEqual(
    scenes[0].steps.map((s) => s.command),
    ["cmd-a", "cmd-c"],
  );
  assert.deepEqual(
    scenes[1].steps.map((s) => s.command),
    ["cmd-b"],
  );
});
