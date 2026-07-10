// profileModel.test.mjs
// profileModel.ts(isValidateProfileOutput/toDiagnosticsByPath/parseProfileFilePath)の
// ユニットテスト。node:test で実行する。esbuild が "../src/profileModel"(拡張子なし)を
// profileModel.ts に解決してバンドルする。
//
// 末尾に2本の統合テストを含む:
//   - test/fixtures/mock-validate-profile.mjs を FtesterCli(src/cli.ts)経由で実際に spawn し、
//     cli.ts → profileModel.ts の配線(result.json → isValidateProfileOutput → toDiagnosticsByPath)
//     を通す(cli.test.mjs の mock-apply-heal 統合テストと同じ方針)。
//   - 実バイナリ(.build/debug/ftester)が存在する場合だけ、`api validate-profile --project
//     SampleApp` の実出力が isValidateProfileOutput を通ることを確認する(存在しなければ skip。
//     デバイス不要な検証コマンドなので FTESTER_E2E フラグなしで安全に実行できる)。

import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { FtesterCli } from "../src/cli";
import {
  isValidateProfileOutput,
  parseProfileFilePath,
  toDiagnosticsByPath,
} from "../src/profileModel";

const MOCK_VALIDATE_PROFILE = path.resolve(process.cwd(), "test", "fixtures", "mock-validate-profile.mjs");
const CWD = process.cwd();

function makeOutputChannel() {
  const lines = [];
  return { lines, appendLine: (line) => lines.push(line) };
}

// ---- isValidateProfileOutput: 正常値 ----

test("isValidateProfileOutput: results 複数件・machine あり の正常な値を true と判定する", () => {
  const value = {
    machine: "M1 Max",
    project: "SampleApp",
    results: [
      {
        kind: "apps",
        name: "sampleapp",
        path: "/repo/Projects/SampleApp/profiles/apps/sampleapp.json",
        errors: [],
        warnings: [],
      },
      {
        kind: "runs",
        name: "sampleapp_all",
        path: "/repo/Projects/SampleApp/profiles/runs/sampleapp_all.json",
        errors: ["\"devices\" がありません"],
        warnings: ["未知のキー \"foo\" は無視されます"],
      },
    ],
  };
  assert.equal(isValidateProfileOutput(value), true);
});

test("isValidateProfileOutput: machine が null(現在マシン未登録)でも true", () => {
  const value = { machine: null, project: "SampleApp", results: [] };
  assert.equal(isValidateProfileOutput(value), true);
});

test("isValidateProfileOutput: results が空配列でも true(--kind/--name に一致するファイルが無い場合)", () => {
  const value = { machine: "M1 Max", project: "SampleApp", results: [] };
  assert.equal(isValidateProfileOutput(value), true);
});

// ---- isValidateProfileOutput: 不正値 ----

test("isValidateProfileOutput: トップレベルのフィールド欠落/型不一致は false", () => {
  assert.equal(isValidateProfileOutput(null), false);
  assert.equal(isValidateProfileOutput("not an object"), false);
  assert.equal(isValidateProfileOutput({}), false);
  assert.equal(isValidateProfileOutput({ project: "P", results: [] }), false); // machine 欠落
  assert.equal(isValidateProfileOutput({ machine: 123, project: "P", results: [] }), false); // machine が数値
  assert.equal(isValidateProfileOutput({ machine: null, project: 123, results: [] }), false); // project が数値
  assert.equal(isValidateProfileOutput({ machine: null, project: "P", results: "not-an-array" }), false);
});

test("isValidateProfileOutput: results 要素の kind が apps/machines/runs 以外なら false", () => {
  const value = {
    machine: null,
    project: "P",
    results: [{ kind: "unknown", name: "n", path: "/p", errors: [], warnings: [] }],
  };
  assert.equal(isValidateProfileOutput(value), false);
});

test("isValidateProfileOutput: results 要素の errors/warnings が文字列配列でなければ false", () => {
  const base = { kind: "runs", name: "n", path: "/p" };
  assert.equal(
    isValidateProfileOutput({
      machine: null,
      project: "P",
      results: [{ ...base, errors: "not-an-array", warnings: [] }],
    }),
    false,
  );
  assert.equal(
    isValidateProfileOutput({
      machine: null,
      project: "P",
      results: [{ ...base, errors: [1, 2], warnings: [] }],
    }),
    false,
  );
  assert.equal(
    isValidateProfileOutput({
      machine: null,
      project: "P",
      results: [{ ...base, errors: [], warnings: undefined }],
    }),
    false,
  );
});

test("isValidateProfileOutput: results 要素の name/path が欠落していれば false", () => {
  assert.equal(
    isValidateProfileOutput({
      machine: null,
      project: "P",
      results: [{ kind: "runs", path: "/p", errors: [], warnings: [] }],
    }),
    false,
  );
  assert.equal(
    isValidateProfileOutput({
      machine: null,
      project: "P",
      results: [{ kind: "runs", name: "n", errors: [], warnings: [] }],
    }),
    false,
  );
});

// ---- toDiagnosticsByPath ----

test("toDiagnosticsByPath: results を path キーの Map に変換し、errors/warnings をそのまま引き継ぐ", () => {
  const output = {
    machine: "M1 Max",
    project: "SampleApp",
    results: [
      {
        kind: "apps",
        name: "sampleapp",
        path: "/repo/Projects/SampleApp/profiles/apps/sampleapp.json",
        errors: [],
        warnings: [],
      },
      {
        kind: "runs",
        name: "broken",
        path: "/repo/Projects/SampleApp/profiles/runs/broken.json",
        errors: ["\"app\"(apps/ への参照)がありません"],
        warnings: ["未知のキー \"foo\" は無視されます"],
      },
    ],
  };
  const map = toDiagnosticsByPath(output);
  assert.equal(map.size, 2);
  assert.deepEqual(map.get("/repo/Projects/SampleApp/profiles/apps/sampleapp.json"), {
    errors: [],
    warnings: [],
  });
  assert.deepEqual(map.get("/repo/Projects/SampleApp/profiles/runs/broken.json"), {
    errors: ["\"app\"(apps/ への参照)がありません"],
    warnings: ["未知のキー \"foo\" は無視されます"],
  });
});

test("toDiagnosticsByPath: results が空なら空の Map を返す", () => {
  const map = toDiagnosticsByPath({ machine: null, project: "P", results: [] });
  assert.equal(map.size, 0);
});

// ---- parseProfileFilePath ----

test("parseProfileFilePath: workspaceRoot 配下の絶対パスから project/kind/name を抽出する", () => {
  const location = parseProfileFilePath(
    "/repo",
    "/repo/Projects/SampleApp/profiles/runs/sampleapp_all.json",
  );
  assert.deepEqual(location, { project: "SampleApp", kind: "runs", name: "sampleapp_all" });
});

test("parseProfileFilePath: apps/machines も同様に抽出する", () => {
  assert.deepEqual(parseProfileFilePath("/repo", "/repo/Projects/SampleApp/profiles/apps/sampleapp.json"), {
    project: "SampleApp",
    kind: "apps",
    name: "sampleapp",
  });
  assert.deepEqual(
    parseProfileFilePath("/repo", "/repo/Projects/SampleApp/profiles/machines/M1 Max.json"),
    { project: "SampleApp", kind: "machines", name: "M1 Max" },
  );
});

test("parseProfileFilePath: 既にワークスペースルート相対のパスでも抽出できる", () => {
  const location = parseProfileFilePath("/repo", "Projects/SampleApp/profiles/runs/ios.json");
  assert.deepEqual(location, { project: "SampleApp", kind: "runs", name: "ios" });
});

test("parseProfileFilePath: Windows 風のバックスラッシュ区切りも正規化して抽出する", () => {
  const location = parseProfileFilePath(
    "C:\\repo",
    "C:\\repo\\Projects\\SampleApp\\profiles\\runs\\ios.json",
  );
  assert.deepEqual(location, { project: "SampleApp", kind: "runs", name: "ios" });
});

test("parseProfileFilePath: profiles/ 配下以外のパスは undefined", () => {
  assert.equal(
    parseProfileFilePath("/repo", "/repo/Projects/SampleApp/Scenarios/ログインテスト.swift"),
    undefined,
  );
});

test("parseProfileFilePath: 種別ディレクトリが apps/machines/runs 以外なら undefined", () => {
  assert.equal(
    parseProfileFilePath("/repo", "/repo/Projects/SampleApp/profiles/unknown/foo.json"),
    undefined,
  );
});

test("parseProfileFilePath: 拡張子が .json 以外なら undefined", () => {
  assert.equal(
    parseProfileFilePath("/repo", "/repo/Projects/SampleApp/profiles/runs/README.md"),
    undefined,
  );
});

test("parseProfileFilePath: profiles/ より深い/浅いパス(セグメント数不一致)は undefined", () => {
  assert.equal(parseProfileFilePath("/repo", "/repo/Projects/SampleApp/profiles/runs/sub/ios.json"), undefined);
  assert.equal(parseProfileFilePath("/repo", "/repo/Projects/SampleApp/profiles/runs.json"), undefined);
});

// ---- 統合: mock-validate-profile.mjs → FtesterCli → profileModel ----

test("統合: mock-validate-profile.mjs(mixed パターン)の出力を FtesterCli 経由で受け取り、isValidateProfileOutput/toDiagnosticsByPath に通せる", async () => {
  const cli = new FtesterCli(makeOutputChannel());
  const result = await cli.invoke(process.execPath, CWD, {
    args: [MOCK_VALIDATE_PROFILE, "--project", "SampleApp"],
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.cancelled, false);
  assert.ok(isValidateProfileOutput(result.json), "出力が契約形状と一致すること");

  const output = result.json;
  assert.equal(output.project, "SampleApp");
  assert.equal(output.machine, "M1 Max");
  assert.equal(output.results.length, 4);

  const byPath = toDiagnosticsByPath(output);
  assert.equal(byPath.size, 4);
  assert.deepEqual(byPath.get("/repo/Projects/SampleApp/profiles/apps/sampleapp.json"), {
    errors: [],
    warnings: [],
  });
  assert.equal(byPath.get("/repo/Projects/SampleApp/profiles/machines/M1 Max.json").errors.length, 1);
  assert.equal(byPath.get("/repo/Projects/SampleApp/profiles/runs/sampleapp_all.json").warnings.length, 1);
  assert.equal(byPath.get("/repo/Projects/SampleApp/profiles/runs/broken.json").errors.length, 1);
});

test("統合: mock-validate-profile.mjs を --kind/--name 付きで呼ぶと results が1件に絞り込まれる", async () => {
  const cli = new FtesterCli(makeOutputChannel());
  const result = await cli.invoke(process.execPath, CWD, {
    args: [MOCK_VALIDATE_PROFILE, "--project", "SampleApp", "--kind", "runs", "--name", "broken"],
  });

  assert.equal(result.exitCode, 0);
  assert.ok(isValidateProfileOutput(result.json));
  assert.equal(result.json.results.length, 1);
  assert.equal(result.json.results[0].name, "broken");
  assert.equal(result.json.results[0].errors.length, 1);
});

// ---- 実バイナリ(存在すれば): api validate-profile ----

// npm test は vscode-ftester/ を cwd として実行される(package.json の "test" スクリプト)ので、
// リポジトリルート(Package.swift のあるフォルダ)はその1つ上(e2e-*.test.mjs と同じ)。
const REPO_ROOT = path.resolve(process.cwd(), "..");
const BINARY_PATH = path.join(REPO_ROOT, ".build", "debug", "ftester");
const BINARY_EXISTS = existsSync(BINARY_PATH);

test(
  "実バイナリ(存在すれば): `ftester api validate-profile --project SampleApp` の実出力が isValidateProfileOutput を通る",
  { skip: !BINARY_EXISTS && "実バイナリ(.build/debug/ftester)が見つからないため skip します" },
  async () => {
    const cli = new FtesterCli(makeOutputChannel());
    const result = await cli.invoke(BINARY_PATH, REPO_ROOT, {
      args: ["api", "validate-profile", "--project", "SampleApp"],
    });

    assert.equal(result.exitCode, 0, `exit code 0 で終了すること(実際: ${String(result.exitCode)})`);
    assert.ok(
      isValidateProfileOutput(result.json),
      `出力が契約形状と一致すること: ${JSON.stringify(result.json)}`,
    );

    const output = result.json;
    assert.equal(output.project, "SampleApp");
    assert.ok(output.results.length >= 1, "SampleApp には少なくとも1件のプロファイルがあること");

    const byPath = toDiagnosticsByPath(output);
    assert.equal(byPath.size, output.results.length);
    for (const fileResult of output.results) {
      assert.ok(["apps", "machines", "runs"].includes(fileResult.kind));
      assert.ok(fileResult.path.length > 0);
    }
  },
);
