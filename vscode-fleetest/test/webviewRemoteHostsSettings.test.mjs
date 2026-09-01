// webviewRemoteHostsSettings.test.mjs
// 設定タブのリモートマシン表(settingsTab.js)が送る setRemoteConfig の payload が、
// 拡張側の最終ゲート(monitorWebviewMessages.ts の isMonitorFromWebviewMessage)を通ることの
// 往復テスト。実 HTML+実バンドルで動かす方式は webviewDevicePickHost.test.mjs と同じ。
//
// **片側だけ改名すると黙って壊れる**: webview は machine で送り、ゲートが name を要求していると
// メッセージごと捨てられ、マシンの追加・削除が画面上は成功したように見えて登録簿に届かない
// (2026-08-26 の host→machine 改名で実際に起きた)。両側を1本のテストで縛る。

import assert from "node:assert/strict";
import path from "node:path";
import { before, test } from "node:test";
import { createRequire } from "node:module";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";
import { isMonitorFromWebviewMessage } from "../src/monitorModel";

const require2 = createRequire(import.meta.url);

let panelHtml;
let webviewBundle;

before(async () => {
  const htmlBuild = await esbuild.build({
    entryPoints: [path.resolve("src/monitorHtml.ts")],
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node18",
    write: false,
    external: ["vscode"],
    logLevel: "silent",
  });
  const vscodeStub = { Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) } };
  const patchedRequire = (id) => (id === "vscode" ? vscodeStub : require2(id));
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(mod, mod.exports, patchedRequire);
  const webviewStub = { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" };
  panelHtml = mod.exports.renderHtml(webviewStub, { path: "" });

  const mainBuild = await esbuild.build({
    entryPoints: [path.resolve("src/webview/monitor/main.js")],
    bundle: true,
    platform: "browser",
    format: "iife",
    target: "es2022",
    write: false,
    logLevel: "silent",
  });
  webviewBundle = mainBuild.outputFiles[0].text;
});

function createWebview(onPost = () => {}) {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  window.acquireVsCodeApi = () => ({ postMessage: onPost, setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  return { window, document: window.document };
}

function post(window, data) {
  window.dispatchEvent(new window.MessageEvent("message", { data }));
}

function click(window, element) {
  element.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

function fill(window, input, value) {
  input.value = value;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
}

function fillAndCommit(window, input, value) {
  input.value = value;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  input.dispatchEvent(new window.Event("change", { bubbles: true }));
}

// 列の並び(monitorHtml.ts の thead と settingsTab.js の td 生成順が対)。
// **必須のホストが先、任意のマシン名がその右**。下のテストが見出しと入力欄の両方で固定する
const [HOST, MACHINE, FM, DIR] = [0, 1, 2, 3];

const REMOTE_CONFIG = {
  type: "remoteConfig",
  hosts: [{ machine: "M1Max", host: "user@m1max", dir: "" }],
  artifacts: "collect",
};

test("列の並びはホスト → マシン(任意) → 作業ベースディレクトリ", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const headers = [...document.querySelectorAll(".settings-remote-hosts-table thead th")]
    .map((th) => th.textContent.trim());
  assert.match(headers[HOST], /user@host/);
  assert.match(headers[MACHINE], /マシン|Machine/);
  assert.match(headers[FM], /FM/);
  assert.match(headers[DIR], /ディレクトリ|directory/);

  // 入力欄の並びも見出しと同じであること(td の生成順がズレると値が別の列に入る)
  post(window, REMOTE_CONFIG);
  const inputs = document.querySelectorAll("#settings-remote-hosts-body tr input");
  assert.equal(inputs[HOST].value, "user@m1max");
  assert.equal(inputs[MACHINE].value, "M1Max");
});

test("remoteConfig の machine が表のマシン列に出る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, REMOTE_CONFIG);
  const inputs = document.querySelectorAll("#settings-remote-hosts-body tr input");
  assert.equal(inputs[0].value, "user@m1max");
  assert.equal(inputs[1].value, "M1Max");
});

// **マシン名は任意**(2026-08-27)。この Mac だけのエイリアスなので、名前を付けたくない
// 利用者に付けさせない。空欄なら host のホスト部が名前になる(CLI 側も同じ既定を持つが、
// 拡張は差分計算を machine で行うため送る時点で埋める)
test("マシン名が空でもホストだけで確定できる(名前は必須ではない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, REMOTE_CONFIG);
  click(window, document.getElementById("settings-remote-hosts-add"));
  const pendingRow = document.querySelector("#settings-remote-hosts-body tr.settings-remote-hosts-row-pending");
  const inputs = pendingRow.querySelectorAll("input");
  const confirm = pendingRow.querySelector(".settings-remote-hosts-confirm");

  assert.equal(confirm.disabled, true, "空行では確定できない");
  fill(window, inputs[HOST], "user@m1ultra.local");
  assert.equal(confirm.disabled, false, "ホストだけで確定できる(マシン名は任意)");
});

test("マシン名欄のウォーターマークが、省略したときに付く名前を先に見せる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, REMOTE_CONFIG);
  click(window, document.getElementById("settings-remote-hosts-add"));
  const pendingRow = document.querySelector("#settings-remote-hosts-body tr.settings-remote-hosts-row-pending");
  const inputs = pendingRow.querySelectorAll("input");

  assert.match(inputs[MACHINE].placeholder, /省略可|optional/,
    "ホスト未入力のうちは「省略できる」ことを出す");
  fill(window, inputs[HOST], "user@m1ultra.local");
  assert.equal(inputs[MACHINE].placeholder, "m1ultra.local", "user@ を落としたホスト部を出す");
  fill(window, inputs[HOST], "192.168.1.20");
  assert.equal(inputs[MACHINE].placeholder, "192.168.1.20");
});

test("マシン名を空のまま確定すると、host のホスト部が machine として送られる", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, REMOTE_CONFIG);
  click(window, document.getElementById("settings-remote-hosts-add"));
  const pendingRow = document.querySelector("#settings-remote-hosts-body tr.settings-remote-hosts-row-pending");
  const inputs = pendingRow.querySelectorAll("input");
  fill(window, inputs[HOST], "user@m1ultra.local");
  click(window, pendingRow.querySelector(".settings-remote-hosts-confirm"));

  const message = JSON.parse(JSON.stringify(posted.filter((m) => m.type === "setRemoteConfig").at(-1)));
  const added = message.hosts.find((h) => h.host === "user@m1ultra.local");
  assert.deepEqual(added,
    { machine: "m1ultra.local", host: "user@m1ultra.local", dir: "", fmConcurrency: 0 });
  assert.ok(isMonitorFromWebviewMessage(message), "拡張側のゲートを通る");
});

test("行を追加して確定すると setRemoteConfig が machine/host/dir で送られ、拡張側のゲートを通る", (t) => {
  const posted = [];
  const { window, document } = createWebview((message) => posted.push(message));
  t.after(() => window.close());

  post(window, REMOTE_CONFIG);
  click(window, document.getElementById("settings-remote-hosts-add"));

  const pendingRow = document.querySelector("#settings-remote-hosts-body tr.settings-remote-hosts-row-pending");
  const inputs = pendingRow.querySelectorAll("input");
  fill(window, inputs[MACHINE], "M1Ultra");
  fill(window, inputs[HOST], "user@m1ultra");
  click(window, pendingRow.querySelector(".settings-remote-hosts-confirm"));

  const raw = posted.filter((m) => m.type === "setRemoteConfig").at(-1);
  assert.ok(raw, "setRemoteConfig が送られる");
  // postMessage で渡るオブジェクトは jsdom 側の realm 産で、deepStrictEqual がプロトタイプ不一致で
  // 落ちる(webviewDevicePickHost.test.mjs と同じ罠)。実際の postMessage と同じく構造化して比べる。
  const message = JSON.parse(JSON.stringify(raw));
  assert.deepEqual(
    message.hosts.map((h) => ({ machine: h.machine, host: h.host, dir: h.dir })),
    [
      { machine: "M1Max", host: "user@m1max", dir: "" },
      { machine: "M1Ultra", host: "user@m1ultra", dir: "" },
    ],
  );
  // 拡張側は isMonitorFromWebviewMessage を通らないメッセージを黙って捨てる(monitorPanel.ts)。
  assert.equal(isMonitorFromWebviewMessage(message), true);
});

// FM 並列枠(2026-09-02)。機械によっては FM を2並列以上で呼ぶと壊れるので機械ごとに絞る。
// **空欄 = 未設定**で、CLI 側へは 0 として送る(dir の "" と同じ流儀)。
test("FM 並列枠は列に出て、値が往復する", (t) => {
  const posted = [];
  const { window, document } = createWebview((m) => posted.push(m));
  t.after(() => window.close());

  post(window, { type: "remoteConfig",
    hosts: [{ machine: "M1Ultra", host: "user@m1u", dir: "", fmConcurrency: 1 }],
    artifacts: "collect" });
  const inputs = document.querySelectorAll("#settings-remote-hosts-body tr input");
  assert.equal(inputs[FM].value, "1", "設定済みの値が欄に出る");

  fillAndCommit(window, inputs[FM], "3");
  const sent = posted.filter((m) => m.type === "setRemoteConfig").at(-1);
  assert.equal(sent.hosts[0].fmConcurrency, 3);
});

test("FM 並列枠の空欄は 0(未設定)として送られる", (t) => {
  const posted = [];
  const { window, document } = createWebview((m) => posted.push(m));
  t.after(() => window.close());

  post(window, { type: "remoteConfig",
    hosts: [{ machine: "M1Ultra", host: "user@m1u", dir: "", fmConcurrency: 2 }],
    artifacts: "collect" });
  const inputs = document.querySelectorAll("#settings-remote-hosts-body tr input");
  fillAndCommit(window, inputs[FM], "");
  const sent = posted.filter((m) => m.type === "setRemoteConfig").at(-1);
  assert.equal(sent.hosts[0].fmConcurrency, 0, "空欄は解除として届く");
});

// 未設定(0)は空欄で描く。0 と表示すると「0 並列」に見えて意味が反転する
test("未設定(0)は空欄で描かれる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "remoteConfig",
    hosts: [{ machine: "M1Max", host: "user@m1max", dir: "", fmConcurrency: 0 }],
    artifacts: "collect" });
  const inputs = document.querySelectorAll("#settings-remote-hosts-body tr input");
  assert.equal(inputs[FM].value, "");
});

// ウォーターマークは **CLI が返す既定値**。拡張側に数字を持たせない(二重管理にすると
// FMLock.defaultConcurrency を変えたときにウォーターマークだけ嘘になる)
test("未設定の FM 並列枠には CLI が返した既定値が実値として入る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "remoteConfig",
    hosts: [{ machine: "M1Max", host: "user@m1max", dir: "", fmConcurrency: 0 }],
    artifacts: "collect", defaultFMConcurrency: 5,
    local: { machine: "local", host: "wave1008@localhost", fmConcurrency: 0 } });

  // 固定行・可変行のどちらも空欄にしない(空欄だと「何枠で走るのか」が画面から読めない)
  for (const [label, row] of [["固定行", 0], ["可変行", 1]]) {
    const fm = document.querySelectorAll("#settings-remote-hosts-body tr")[row]
      .querySelectorAll("input")[FM];
    assert.equal(fm.value, "5", `${label}: 既定値が入る`);
    assert.equal(fm.placeholder, "5", `${label}: ウォーターマークも既定値`);
  }
});

// 既に値を持つ行は既定で上書きしない(0 だけが「未設定」)
test("設定済みの FM 並列枠は既定値で上書きしない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "remoteConfig",
    hosts: [{ machine: "M1Ultra", host: "user@m1u", dir: "", fmConcurrency: 2 }],
    artifacts: "collect", defaultFMConcurrency: 5,
    local: { machine: "local", host: "wave1008@localhost", fmConcurrency: 3 } });

  const rows = document.querySelectorAll("#settings-remote-hosts-body tr");
  assert.equal(rows[0].querySelectorAll("input")[FM].value, "3", "固定行");
  assert.equal(rows[1].querySelectorAll("input")[FM].value, "2", "可変行");
});

test("既定値が届いていなければウォーターマークは出さない(推測の数字を見せない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "remoteConfig",
    hosts: [{ machine: "M1Max", host: "user@m1max", dir: "", fmConcurrency: 0 }],
    artifacts: "collect" });
  const inputs = document.querySelectorAll("#settings-remote-hosts-body tr input");
  assert.equal(inputs[FM].placeholder, "");
  assert.equal(inputs[FM].value, "", "既定が読めないなら実値も入れない(推測を書き込まない)");
});

// FM 並列枠は1〜2桁しか入らないので、見出し幅に合わせて縮める(他の3列が余りを分け合う)。
// 見出しとセルの**両方**にクラスが要る(片方だけだと auto レイアウトが効かない)
test("列幅のクラスが見出し・可変行・固定行の3箇所に付いている", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "remoteConfig", hosts: [{ machine: "M1Max", host: "user@m1max", dir: "" }],
    artifacts: "collect", defaultFMConcurrency: 5,
    local: { machine: "local", host: "wave1008@localhost", fmConcurrency: 0 } });

  // 幅は CSS が列ごとのクラスで決める。**見出しとセルの両方に要る**(片方だけだと効かない)
  const widthClass = [[HOST, "host"], [MACHINE, "machine"], [FM, "fm"], [DIR, "dir"]];
  const th = [...document.querySelectorAll(".settings-remote-hosts-table thead th")];
  for (const [col, name] of widthClass) {
    assert.ok(th[col].classList.contains(`settings-remote-hosts-${name}`), `見出し(${name})`);
  }
  // 固定行・可変行のどちらにも要る(片方だけだと列がズレて見える)
  for (const [label, row] of [["固定行", 0], ["可変行", 1]]) {
    const td = document.querySelectorAll("#settings-remote-hosts-body tr")[row]
      .querySelectorAll("td");
    for (const [col, name] of widthClass) {
      assert.ok(td[col].classList.contains(`settings-remote-hosts-${name}`), `${label}(${name})`);
    }
  }
});

// この機械の行は**固定**(登録簿には入らない。"local" は予約名で値は LocalConfig 側)。
// 消せないこと・FM 枠だけ編集できることを固定する
test("この機械の行が先頭に固定で描かれ、削除ボタンを持たない", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "remoteConfig", hosts: [{ machine: "M1Max", host: "user@m1max", dir: "" }],
    artifacts: "collect", defaultFMConcurrency: 5,
    local: { machine: "local", host: "wave1008@localhost", fmConcurrency: 0 } });

  const rows = document.querySelectorAll("#settings-remote-hosts-body tr");
  assert.ok(rows[0].classList.contains("settings-remote-hosts-row-local"), "先頭が固定行");
  const values = [...rows[0].querySelectorAll("input")].map((i) => i.value);
  assert.equal(values[HOST], "wave1008@localhost");
  assert.equal(values[MACHINE], "local");
  assert.equal(rows[0].querySelectorAll(".settings-remote-hosts-remove").length, 0, "削除できない");
  // 左端を可変行と揃えるため host/machine も input にするが、**読み取り専用**にして
  // 編集できるのは FM 枠だけに保つ
  const inputs = rows[0].querySelectorAll("input");
  assert.equal(inputs.length, 4, "host / machine / dir / FM");
  // 並びは HOST / MACHINE / FM / DIR。編集できるのは FM だけ
  assert.deepEqual([...inputs].map((i) => i.readOnly), [true, true, false, true]);
});

test("この機械の FM 枠は machine:'local' として送られる(登録簿には入らない)", (t) => {
  const posted = [];
  const { window, document } = createWebview((m) => posted.push(m));
  t.after(() => window.close());

  post(window, { type: "remoteConfig", hosts: [], artifacts: "collect", defaultFMConcurrency: 5,
    local: { machine: "local", host: "wave1008@localhost", fmConcurrency: 0 } });
  const inputs = document.querySelectorAll("#settings-remote-hosts-body tr input");
  fillAndCommit(window, inputs[FM], "2");

  const sent = posted.filter((m) => m.type === "setRemoteConfig").at(-1);
  const local = sent.hosts.find((h) => h.machine === "local");
  assert.equal(local.fmConcurrency, 2);
  assert.equal(local.host, "wave1008@localhost");
});

// セクションの構成。**成果物(録画・ログ)は「ログ」に属し、マシンより上**。
// artifacts セレクタは remoteConfig/setRemoteConfig に相乗りしているので、DOM 上で
// 別セクションへ移しても配線は変わらない —— その前提が崩れていないことも併せて見る
test("ログ セクションがマシンの上にあり、成果物セレクタを含む", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  const titles = [...document.querySelectorAll("#panel-settings .settings-section-title")]
    .map((el) => el.textContent.trim());
  const log = titles.findIndex((x) => /ログ|Logs/.test(x));
  const machines = titles.findIndex((x) => /^マシン$|^Machines$/.test(x.trim()));
  assert.ok(log >= 0 && machines >= 0, `見出しが見つからない: ${titles.join(" / ")}`);
  assert.ok(log < machines, "ログ はマシンより上");

  // 成果物セレクタは「ログ」セクションの中(= マシン設定の表とは別のグループ)
  const artifacts = document.getElementById("settings-remote-artifacts");
  const group = artifacts.closest(".settings-group");
  assert.match(group.querySelector(".settings-section-title").textContent, /ログ|Logs/);
  assert.equal(group.querySelector(".settings-remote-hosts-table"), null, "表は別セクション");
});

test("追加ボタンの文言はリモートホストを追加", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  assert.match(document.getElementById("settings-remote-hosts-add").textContent,
               /リモートホストを追加|Add remote host/);
});

// FM 並列枠は 1〜9 の1桁だけ。**固定行と可変行の両方**に効くこと(片方だけ書くと漏れる)
function typeInto(window, input, text) {
  input.value = text;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  return input.value;
}

test("FM 並列枠は 1〜9 の1桁だけ受け付ける(可変行)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "remoteConfig", hosts: [{ machine: "M1Max", host: "user@m1max", dir: "" }],
    artifacts: "collect", defaultFMConcurrency: 5 });
  const fm = document.querySelectorAll("#settings-remote-hosts-body tr input")[FM];

  assert.equal(typeInto(window, fm, "3"), "3", "1桁の数字は通る");
  assert.equal(typeInto(window, fm, "0"), "", "0 は打てない(空欄が未設定)");
  assert.equal(typeInto(window, fm, "12"), "1", "2桁目は落ちる");
  assert.equal(typeInto(window, fm, "a"), "", "英字は落ちる");
  assert.equal(typeInto(window, fm, "-1"), "1", "符号は落ちる");
  // **maxLength は type=number では効かない**(-1 を返す)。桁の制限を担っているのは
  // 上の input イベントだけ —— 消しても maxLength を見るテストでは気づけない
  assert.equal(fm.maxLength, -1, "maxLength に頼っていないこと");
});

// 「直近 N 件までの履歴を使用する」と同じ作り。**.settings-remote-hosts-input は当てない**
// (width:100% / min-width:90px が .settings-number の 80px 固定を上書きして列が広がる)
test("FM 並列枠の入力欄は履歴件数と同じデザイン(type=number + .settings-number)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "remoteConfig", hosts: [{ machine: "M1Max", host: "user@m1max", dir: "" }],
    artifacts: "collect", defaultFMConcurrency: 5,
    local: { machine: "local", host: "wave1008@localhost", fmConcurrency: 0 } });

  const history = document.getElementById("settings-lpt-history");
  assert.ok(history.classList.contains("settings-number"), "比較対象(履歴件数)");

  for (const [label, row] of [["固定行", 0], ["可変行", 1]]) {
    const fm = document.querySelectorAll("#settings-remote-hosts-body tr")[row]
      .querySelectorAll("input")[FM];
    assert.equal(fm.type, "number", `${label}: type`);
    assert.equal(fm.type, history.type, `${label}: 履歴件数と同じ type`);
    assert.ok(fm.classList.contains("settings-number"), `${label}: .settings-number`);
    assert.ok(!fm.classList.contains("settings-remote-hosts-input"), `${label}: 幅指定を当てない`);
    assert.equal(fm.min, "1", `${label}: min`);
    assert.equal(fm.max, "9", `${label}: max`);
  }
});

test("FM 並列枠は 1〜9 の1桁だけ受け付ける(この機械の固定行)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "remoteConfig", hosts: [], artifacts: "collect", defaultFMConcurrency: 5,
    local: { machine: "local", host: "wave1008@localhost", fmConcurrency: 0 } });
  const fm = document.querySelectorAll("#settings-remote-hosts-body tr input")[FM];

  assert.equal(typeInto(window, fm, "9"), "9");
  assert.equal(typeInto(window, fm, "0"), "");
  assert.equal(typeInto(window, fm, "99"), "9");
});

// 列の並びは**見出し・可変行・固定行の3箇所**で決まる(td の生成順)。1つでもズレると
// 値が別の列に入る。3つを同時に見て等号で固定する
test("列の並びが見出し・可変行・固定行で一致する", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());

  post(window, { type: "remoteConfig",
    hosts: [{ machine: "M1Ultra", host: "user@m1u", dir: "~/runner", fmConcurrency: 3 }],
    artifacts: "collect", defaultFMConcurrency: 5,
    local: { machine: "local", host: "wave1008@localhost", fmConcurrency: 7 } });

  const headers = [...document.querySelectorAll(".settings-remote-hosts-table thead th")]
    .map((th) => th.textContent.trim());
  assert.match(headers[HOST], /user@host/);
  assert.match(headers[MACHINE], /マシン|Machine/);
  assert.match(headers[FM], /FM/);
  assert.match(headers[DIR], /ディレクトリ|directory/);

  const rows = document.querySelectorAll("#settings-remote-hosts-body tr");
  const fixed = [...rows[0].querySelectorAll("input")].map((i) => i.value);
  assert.deepEqual([fixed[HOST], fixed[MACHINE], fixed[FM], fixed[DIR]],
                   ["wave1008@localhost", "local", "7", ""], "固定行");

  const editable = [...rows[1].querySelectorAll("input")].map((i) => i.value);
  assert.deepEqual([editable[HOST], editable[MACHINE], editable[FM], editable[DIR]],
                   ["user@m1u", "M1Ultra", "3", "~/runner"], "可変行");
});
