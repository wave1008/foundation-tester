// i18n の機械検証。npm test(esbuild --tests でバンドル)に自動参加する。
// 1) 辞書パリティ: ja/en 非空・プレースホルダ集合一致・namespace 前置・ファイル横断のキー重複なし
// 2) 残存日本語: src/**/*.ts と src/webview/**/*.js の**文字列/テンプレートリテラルのノードのみ**を
//    TypeScript AST で走査(コメントは AST に乗らないので日本語コメントは自然に除外)。辞書と
//    allowlist は除外。
// 3) webview キー参照: webview .js の t('...') キーが webview 辞書に存在するか
// 4) package.nls: package.json の %...% 参照が両 nls に存在・キー集合一致・contributes に日本語なし
//
// process.cwd() は npm test 実行時に vscode-ftester ルート(profileSchema.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import ts from "typescript";

import { compatStrings } from "../src/i18n/strings/compat";
import { profilesStrings } from "../src/i18n/strings/profiles";
import { panelsStrings } from "../src/i18n/strings/panels";
import { monitorStrings } from "../src/i18n/strings/monitor";
import { liveStrings } from "../src/i18n/strings/live";
import { deviceOpsStrings } from "../src/i18n/strings/deviceOps";
import { runStrings } from "../src/i18n/strings/run";
import { workbenchStrings } from "../src/i18n/strings/workbench";
import { exploreHealStrings } from "../src/i18n/strings/exploreHeal";
import { webviewMonitorAStrings } from "../src/i18n/strings/webviewMonitorA";
import { webviewMonitorBStrings } from "../src/i18n/strings/webviewMonitorB";
import { webviewDashboardStrings } from "../src/i18n/strings/webviewDashboard";
import { laneStrings } from "../src/i18n/strings/lane";

const ROOT = process.cwd();

// 辞書ファイルと namespace 前置の対応(キーの帰属を構造的に強制)。
const DICTS = [
  { name: "profiles", prefix: "profiles.", dict: profilesStrings, side: "ext" },
  { name: "panels", prefix: "panels.", dict: panelsStrings, side: "ext" },
  { name: "monitor", prefix: "monitor.", dict: monitorStrings, side: "ext" },
  { name: "live", prefix: "live.", dict: liveStrings, side: "ext" },
  { name: "deviceOps", prefix: "deviceOps.", dict: deviceOpsStrings, side: "ext" },
  { name: "run", prefix: "run.", dict: runStrings, side: "ext" },
  { name: "workbench", prefix: "workbench.", dict: workbenchStrings, side: "ext" },
  { name: "exploreHeal", prefix: "exploreHeal.", dict: exploreHealStrings, side: "ext" },
  { name: "compat", prefix: "compat.", dict: compatStrings, side: "ext" },
  { name: "webviewMonitorA", prefix: "wvMonitor.", dict: webviewMonitorAStrings, side: "webview" },
  { name: "webviewMonitorB", prefix: "wvMonitor2.", dict: webviewMonitorBStrings, side: "webview" },
  { name: "webviewDashboard", prefix: "wvDashboard.", dict: webviewDashboardStrings, side: "webview" },
  // レーンログ用の別ランタイム(runReducer.ts/runLaneModel.ts、tLane 経由。拡張・webview 両バンドル共有)。
  { name: "lane", prefix: "lane.", dict: laneStrings, side: "lane" },
];

const CJK = /[぀-ヿ㐀-鿿豈-﫿]/;

function placeholders(text) {
  const set = new Set();
  for (const m of text.matchAll(/\{(\w+)\}/g)) {
    set.add(m[1]);
  }
  return [...set].sort();
}

// 変換せず日本語のまま残すことが正当な文字列リテラル(バッチ報告に基づき追記)。
// { file: "src/xxx.ts", text: "日本語" } で1エントリ。file はリポジトリルート相対。
const RESIDUAL_ALLOWLIST = [
  // 不変条件違反時の内部 throw(UI に出さない。バグ検出用。batch C 報告)。
  {
    file: "src/monitorModel.ts",
    text: "finishDeviceLifecycleJob: 実行中に該当ジョブがありません(完了通知が重複した可能性)",
  },
];

function isAllowed(relFile, text) {
  return RESIDUAL_ALLOWLIST.some((e) => e.file === relFile && e.text === text);
}

function walkFiles(dir, exts, out) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walkFiles(full, exts, out);
    } else if (exts.some((e) => entry.name.endsWith(e))) {
      out.push(full);
    }
  }
}

/** ファイルの文字列/テンプレートリテラルのノードから、CJK を含むテキスト片を集める。 */
function collectStringLiteralJapanese(absFile) {
  const isJs = absFile.endsWith(".js");
  const source = ts.createSourceFile(
    absFile,
    readFileSync(absFile, "utf8"),
    ts.ScriptTarget.Latest,
    true,
    isJs ? ts.ScriptKind.JS : ts.ScriptKind.TS,
  );
  const hits = [];
  const visit = (node) => {
    if (
      ts.isStringLiteral(node) ||
      ts.isNoSubstitutionTemplateLiteral(node) ||
      node.kind === ts.SyntaxKind.TemplateHead ||
      node.kind === ts.SyntaxKind.TemplateMiddle ||
      node.kind === ts.SyntaxKind.TemplateTail
    ) {
      if (typeof node.text === "string") {
        // HTML テンプレートリテラルの断片には、DOM テキストを ${t()} 化した後も HTML コメント
        // (<!-- -->)内の日本語が残る(コメントは維持対象)。コメントを除去してから判定する。
        const withoutHtmlComments = node.text.replace(/<!--[\s\S]*?-->/g, "");
        if (CJK.test(withoutHtmlComments)) {
          hits.push(node.text);
        }
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  return hits;
}

test("辞書: ja/en が非空でプレースホルダ集合が一致する", () => {
  for (const { name, dict } of DICTS) {
    for (const [key, entry] of Object.entries(dict)) {
      assert.ok(entry && typeof entry.ja === "string" && entry.ja.length > 0, `${name}: ${key} の ja が空`);
      assert.ok(entry && typeof entry.en === "string" && entry.en.length > 0, `${name}: ${key} の en が空`);
      assert.deepEqual(
        placeholders(entry.ja),
        placeholders(entry.en),
        `${name}: ${key} の ja/en でプレースホルダ集合が不一致`,
      );
    }
  }
});

test("辞書: キーが所属ファイルの namespace で始まる", () => {
  for (const { name, prefix, dict } of DICTS) {
    for (const key of Object.keys(dict)) {
      assert.ok(key.startsWith(prefix), `${name}: キー "${key}" が prefix "${prefix}" で始まっていない`);
    }
  }
});

test("辞書: ファイル横断でキーが重複しない", () => {
  const seen = new Map();
  for (const { name, dict } of DICTS) {
    for (const key of Object.keys(dict)) {
      assert.ok(!seen.has(key), `キー "${key}" が ${seen.get(key)} と ${name} で重複`);
      seen.set(key, name);
    }
  }
});

test("残存日本語: 文字列/テンプレートリテラルに未変換の日本語が無い", () => {
  const files = [];
  walkFiles(path.join(ROOT, "src"), [".ts"], files);
  walkFiles(path.join(ROOT, "src", "webview"), [".js"], files);
  const stringsDir = path.join(ROOT, "src", "i18n", "strings") + path.sep;
  const offenders = [];
  for (const abs of files) {
    if (abs.startsWith(stringsDir)) {
      continue; // 辞書は ja を持つのが正当
    }
    const rel = path.relative(ROOT, abs);
    for (const text of collectStringLiteralJapanese(abs)) {
      if (!isAllowed(rel, text)) {
        offenders.push(`${rel}: ${JSON.stringify(text)}`);
      }
    }
  }
  assert.equal(offenders.length, 0, `未変換の日本語リテラル:\n${offenders.join("\n")}`);
});

test("webview: t('...') のキーが webview 辞書に存在する", () => {
  const webviewKeys = new Set();
  for (const { dict, side } of DICTS) {
    if (side === "webview") {
      for (const key of Object.keys(dict)) {
        webviewKeys.add(key);
      }
    }
  }
  const files = [];
  walkFiles(path.join(ROOT, "src", "webview"), [".js"], files);
  const i18nRuntime = path.join(ROOT, "src", "webview", "i18n.js");
  const missing = [];
  for (const abs of files) {
    if (abs === i18nRuntime) {
      continue; // t の定義側(merged[key] であってリテラルキーではない)
    }
    const src = readFileSync(abs, "utf8");
    for (const m of src.matchAll(/\bt\(\s*(['"])([^'"]+)\1/g)) {
      const key = m[2];
      if (!webviewKeys.has(key)) {
        missing.push(`${path.relative(ROOT, abs)}: t('${key}') が webview 辞書に無い`);
      }
    }
  }
  assert.equal(missing.length, 0, missing.join("\n"));
});

test("lane: tLane('...') のキーが lane 辞書に存在する", () => {
  const laneKeys = new Set(Object.keys(laneStrings));
  const missing = [];
  for (const rel of ["src/runReducer.ts", "src/runLaneModel.ts"]) {
    const src = readFileSync(path.join(ROOT, rel), "utf8");
    for (const m of src.matchAll(/\btLane\(\s*(['"])([^'"]+)\1/g)) {
      if (!laneKeys.has(m[2])) {
        missing.push(`${rel}: tLane('${m[2]}') が lane 辞書に無い`);
      }
    }
  }
  assert.equal(missing.length, 0, missing.join("\n"));
});

test("package.nls: %参照% が両 nls に存在しキー集合が一致・contributes に日本語なし", () => {
  const pkgRaw = readFileSync(path.join(ROOT, "package.json"), "utf8");
  const pkg = JSON.parse(pkgRaw);
  const en = JSON.parse(readFileSync(path.join(ROOT, "package.nls.json"), "utf8"));
  const ja = JSON.parse(readFileSync(path.join(ROOT, "package.nls.ja.json"), "utf8"));

  const refs = new Set();
  for (const m of pkgRaw.matchAll(/%([\w.]+)%/g)) {
    refs.add(m[1]);
  }
  assert.ok(refs.size > 0, "package.json に %参照% が見つからない");
  for (const key of refs) {
    assert.ok(key in en, `package.nls.json に "${key}" が無い`);
    assert.ok(key in ja, `package.nls.ja.json に "${key}" が無い`);
  }
  assert.deepEqual(
    Object.keys(en).sort(),
    Object.keys(ja).sort(),
    "package.nls.json と package.nls.ja.json のキー集合が不一致",
  );

  const walkValues = (node, jsonPath) => {
    if (typeof node === "string") {
      assert.ok(!CJK.test(node), `contributes に日本語が残存: ${jsonPath} = ${JSON.stringify(node)}`);
    } else if (Array.isArray(node)) {
      node.forEach((v, i) => walkValues(v, `${jsonPath}[${i}]`));
    } else if (node && typeof node === "object") {
      for (const [k, v] of Object.entries(node)) {
        walkValues(v, `${jsonPath}.${k}`);
      }
    }
  };
  walkValues(pkg.contributes, "contributes");
});

// statSync は未使用警告回避のダミー参照ではなく、将来の拡張余地のため残す想定は無い。
void statSync;
