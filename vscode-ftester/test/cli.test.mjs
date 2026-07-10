// cli.test.mjs
// FtesterCli(src/cli.ts)の stdin 対応 spawn(CliInvocation.stdin)のユニット/統合テスト。
// node:test で実行する。esbuild が "../src/cli"(拡張子なし)を cli.ts に解決してバンドルする。
//
// 相手は本物の ftester CLI ではなく test/fixtures/mock-apply-heal.mjs
// (stdin の JSON をそのまま読んで応答を返すダミー)にする。binaryPath には process.execPath
// (node)を渡し、args の先頭にフィクスチャのパスを置くことで「node <fixture> ...」として
// spawn させる(dap.test.mjs や runReducer.test.mjs の mock-runner 統合テストと同じ方針)。
//
// FtesterCli は vscode.OutputChannel を1引数で受け取るが、このテストでは
// appendLine だけ実装したダミーで足りる(cli.ts は他のメソッドを呼ばない)。

import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";
import { FtesterCli } from "../src/cli";

const MOCK_APPLY_HEAL = path.resolve(process.cwd(), "test", "fixtures", "mock-apply-heal.mjs");
const CWD = process.cwd();

function makeOutputChannel() {
  const lines = [];
  return { lines, appendLine: (line) => lines.push(line) };
}

test("stdin 対応 spawn: invocation.stdin を書き込んで EOF を送り、mock-apply-heal.mjs が読んだ内容をそのまま応答に反映する", async () => {
  const outputChannel = makeOutputChannel();
  const cli = new FtesterCli(outputChannel);

  const request = {
    fixes: [
      {
        scenarioID: "S.T1",
        file: "Projects/P/Scenarios/S.swift",
        line: 12,
        oldSelector: "#old_id",
        newSelector: "#new_id",
        newComment: null,
      },
      {
        scenarioID: "S.T2",
        file: "Projects/P/Scenarios/S.swift",
        line: 20,
        oldSelector: "#old2",
        newSelector: "#FAIL_new2",
        newComment: "説明",
      },
    ],
  };

  const result = await cli.invoke(process.execPath, CWD, {
    args: [MOCK_APPLY_HEAL],
    stdin: JSON.stringify(request),
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.cancelled, false);
  assert.deepEqual(result.json, {
    applied: ["S.T1|Projects/P/Scenarios/S.swift:12|#old_id"],
    failures: [
      {
        id: "S.T2|Projects/P/Scenarios/S.swift:20|#old2",
        message: "模擬エラー: #FAIL_new2",
      },
    ],
  });
});

test("stdin 対応 spawn: fixes が空でも往復できる(applied/failures とも空配列)", async () => {
  const outputChannel = makeOutputChannel();
  const cli = new FtesterCli(outputChannel);

  const result = await cli.invoke(process.execPath, CWD, {
    args: [MOCK_APPLY_HEAL],
    stdin: JSON.stringify({ fixes: [] }),
  });

  assert.equal(result.exitCode, 0);
  assert.deepEqual(result.json, { applied: [], failures: [] });
});

test("stdin 未指定の呼び出し(既存の挙動)は引き続き動作する(stdin を使わない CLI 呼び出しの回帰確認)", async () => {
  const outputChannel = makeOutputChannel();
  const cli = new FtesterCli(outputChannel);

  // mock-apply-heal.mjs は stdin が空でも({fixes:[]} 相当として)正常応答するため、
  // stdin を渡さない(stdio: "ignore")呼び出しでも同じフィクスチャで検証できる。
  const result = await cli.invoke(process.execPath, CWD, { args: [MOCK_APPLY_HEAL] });

  assert.equal(result.exitCode, 1);
  // stdin が閉じている(EOF 即時)ため mock-apply-heal.mjs 側は空文字列 → JSON パース失敗
  // → exitCode 1 で {applied:[],failures:[]} を返す実装になっている。stdio:"ignore" でも
  // プロセスが正しく起動・完走し、cli.ts が結果を受け取れることの確認が目的。
  assert.deepEqual(result.json, { applied: [], failures: [] });
});
