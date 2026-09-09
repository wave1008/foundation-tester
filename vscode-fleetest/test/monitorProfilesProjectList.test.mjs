// monitorProfilesProjectList.test.mjs
// postProfileInfo が「TestProjects/ 直下のプロジェクト一覧」を載せることの回帰テスト
// (fake-deps パターンは monitorProfilesDeviceMachineScope.test.mjs と同じ)。
//
// 「テスト実行」タブのプロジェクト選択はこの1メッセージだけで作られる。ここが空だと、実行プロファイルの
// ドロップダウンだけが並んで切り替え先が1つも出ない(webview 側の形は
// webviewProjectSelect.test.mjs が固定する)。

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { MonitorProfilesController } from "../src/monitorProfilesController";

/** TestProjects/{A,B}/ を持つ一時ワークスペースとコントローラを作る(watcher を作る
 * コンストラクタは通さない。理由は monitorProfilesDeviceMachineScope.test.mjs と同じ)。 */
function makeController(project) {
  const workspaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fleetest-projects-test-"));
  fs.mkdirSync(path.join(workspaceRoot, "TestProjects", "E2E-CMP", "profiles", "runs"), { recursive: true });
  fs.writeFileSync(path.join(workspaceRoot, "TestProjects", "E2E-CMP", "profiles", "runs", "local.json"), "{}\n");
  fs.mkdirSync(path.join(workspaceRoot, "TestProjects", "E2E-Android"), { recursive: true });
  const posts = [];
  const controller = Object.create(MonitorProfilesController.prototype);
  controller.deps = {
    workspaceRoot,
    getConfig: () => ({ binaryPath: "fleetest", project, profile: "", monitorDeviceFilter: "all" }),
    outputChannel: { appendLine() {} },
    post: (message) => posts.push(message),
  };
  return { controller, posts };
}

test("postProfileInfo: TestProjects/ 直下の候補を projects に載せる", () => {
  const { controller, posts } = makeController("E2E-CMP");
  controller.postProfileInfo();

  const message = posts.find((m) => m.type === "profileInfo");
  assert.deepEqual(message.projects, ["E2E-Android", "E2E-CMP"]);
  assert.equal(message.project, "E2E-CMP");
  assert.deepEqual(message.profiles, ["local"]);
});

test("postProfileInfo: プロジェクト未解決でも候補は載せる(ここから復帰できるように)", () => {
  // 設定なし + 候補が複数 = 未解決。実行プロファイル一覧は引けないが、切り替え先は出す。
  const { controller, posts } = makeController("");
  controller.postProfileInfo();

  const message = posts.find((m) => m.type === "profileInfo");
  assert.deepEqual(message.projects, ["E2E-Android", "E2E-CMP"]);
  assert.equal(message.project, "");
  assert.deepEqual(message.profiles, []);
});
