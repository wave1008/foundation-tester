// 自己修復の確認パネル(healReviewPanel.ts の HTML + src/webview/healReview/main.js の実バンドル)を
// jsdom で動かす。初期データは #heal-review-data の JSON 経由・プレビューと適用は healModel.ts の関数を通る。

import assert from "node:assert/strict";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";

import { HealReviewController } from "../src/healReviewPanel";
import { RunEventBus } from "../src/runEventBus";

let bundle;

before(async () => {
  const build = await esbuild.build({
    entryPoints: [path.resolve("src/webview/healReview/main.js")],
    bundle: true,
    platform: "browser",
    format: "iife",
    target: "es2022",
    write: false,
    logLevel: "silent",
  });
  bundle = build.outputFiles[0].text;
});

const ITEM = {
  id: "a",
  scenarioID: "S0010",
  file: "scenarios/01.swift",
  line: 12,
  oldSelector: "#old",
  newSelector: "#new",
  message: "healed",
  unavailable: false,
  originalLine: '    tap("#old")  // keep',
  originalComment: "keep",
};

function open(items) {
  const assets = {
    localResourceRoots: [],
    resolve: () => ({ styleUri: "https://localhost/style.css", scriptUri: "https://localhost/main.js", cspSource: "https://localhost" }),
  };
  const controller = new HealReviewController(
    "/tmp/proj", () => ({ binaryPath: "/usr/local/bin/fleetest", project: "P", profile: "" }),
    { appendLine() {} }, {}, new RunEventBus(), assets);
  const panel = { webview: { html: "" } };
  controller.panel = panel;
  controller.items = items;
  controller.relocalize();
  const dom = new JSDOM(panel.webview.html, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const posted = [];
  dom.window.acquireVsCodeApi = () => ({ postMessage: (m) => posted.push(m), setState: () => {}, getState: () => undefined });
  dom.window.eval(bundle);
  return { window: dom.window, document: dom.window.document, posted, html: panel.webview.html };
}

test("初期データの候補を行にし、プレビューに変更前後の行を出す", (t) => {
  const { window, document } = open([ITEM]);
  t.after(() => window.close());
  const lines = [...document.querySelectorAll(".preview div")].map((el) => el.textContent);
  assert.deepEqual(lines, ['-     tap("#old")  // keep', '+     tap("#new")  // keep']);
  assert.match(document.getElementById("btn-apply").textContent, /1/);
});

test("適用はチェックした行の修正を送り、コメントを変えたら newComment に入れる", (t) => {
  const { window, document, posted } = open([ITEM]);
  t.after(() => window.close());
  const [, commentInput] = document.querySelectorAll('input[type="text"]');
  commentInput.value = "changed";
  commentInput.dispatchEvent(new window.Event("input"));
  document.getElementById("btn-apply").click();
  // jsdom の realm で作られたオブジェクトなので JSON で Node 側へ写してから比べる
  assert.deepEqual(JSON.parse(JSON.stringify(posted)), [{
    type: "apply",
    fixes: [{ scenarioID: "S0010", file: "scenarios/01.swift", line: 12, oldSelector: "#old", newSelector: "#new", newComment: "changed" }],
  }]);
});

test("applyResult で適用済みの行を隠し、残りが無ければ空表示にする", (t) => {
  const { window, document } = open([ITEM]);
  t.after(() => window.close());
  window.dispatchEvent(new window.MessageEvent("message", { data: { type: "applyResult", appliedIds: ["a"], failures: [] } }));
  assert.equal(document.getElementById("empty").style.display, "block");
});

test("セレクタに </script> を含んでも初期データの要素が閉じない", (t) => {
  const tricky = { ...ITEM, newSelector: "</script><b>x</b>" };
  const { window, document, html } = open([tricky]);
  t.after(() => window.close());
  assert.doesNotMatch(html, /<\/script><b>/);
  const [selectorInput] = document.querySelectorAll('input[type="text"]');
  assert.equal(selectorInput.value, "</script><b>x</b>");
});
