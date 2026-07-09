// dapDriver.mjs
// FtesterDebugSession(src/debugAdapter.ts)を実エディタ無しで直接駆動するためのテストヘルパー。
// test/dap.test.mjs(mock-runner.mjs 相手)と test/e2e-dryrun-debug.test.mjs(実バイナリ相手)の
// 両方から使う。
//
// debugAdapter.ts は "vscode" モジュールに依存しないため、handleMessage()/onDidSendMessage() だけで
// DAP のリクエスト/レスポンス/イベントをやり取りできる(Content-Length ヘッダ付きのバイトストリームを
// 経由する start(stream) は使わない)。

import { FtesterDebugSession } from "../../src/debugAdapter";

/**
 * FtesterDebugSession のインスタンスと、それを駆動するための send/waitFor* ヘルパーをまとめて返す。
 * options: FtesterDebugSessionOptions と同じ({binaryPath, cwd, log?})。
 */
export function createDapDriver(options) {
  const logs = [];
  const session = new FtesterDebugSession({
    binaryPath: options.binaryPath,
    cwd: options.cwd,
    log: (line, stream) => {
      logs.push({ line, stream });
      options.log?.(line, stream);
    },
  });

  const messages = [];
  const waiters = [];
  // waitForMessage() が「まだ見ていない」メッセージだけを対象にするための読み取り位置。
  // これが無いと、同じ command のレスポンスを複数回 waitFor したときに毎回同じ(最初の)
  // メッセージへヒットしてしまう(例: setBreakpoints を2回送った場合の2回目の応答待ち)。
  let cursor = 0;

  session.onDidSendMessage((msg) => {
    messages.push(msg);
    for (let i = waiters.length - 1; i >= 0; i -= 1) {
      if (waiters[i].predicate(msg)) {
        const [w] = waiters.splice(i, 1);
        w.resolve(msg, messages.length - 1);
      }
    }
  });

  let seq = 1;
  function send(command, args) {
    session.handleMessage({ seq: seq++, type: "request", command, arguments: args });
  }

  function waitForMessage(predicate, timeoutMs = 5000) {
    for (let i = cursor; i < messages.length; i += 1) {
      if (predicate(messages[i])) {
        cursor = i + 1;
        return Promise.resolve(messages[i]);
      }
    }
    return new Promise((resolve, reject) => {
      const wrappedResolve = (msg, index) => {
        clearTimeout(timer);
        cursor = Math.max(cursor, index + 1);
        resolve(msg);
      };
      const timer = setTimeout(() => {
        const idx = waiters.findIndex((w) => w.resolve === wrappedResolve);
        if (idx !== -1) waiters.splice(idx, 1);
        reject(new Error(`timeout waiting for DAP message (predicate: ${predicate})`));
      }, timeoutMs);
      waiters.push({ predicate, resolve: wrappedResolve });
    });
  }

  async function waitUntil(predicate, timeoutMs = 5000) {
    const start = Date.now();
    while (!predicate()) {
      if (Date.now() - start > timeoutMs) {
        throw new Error("timeout waiting for condition");
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }

  const waitForEvent = (event, timeoutMs) =>
    waitForMessage((m) => m.type === "event" && m.event === event, timeoutMs);
  const waitForResponse = (command, timeoutMs) =>
    waitForMessage((m) => m.type === "response" && m.command === command, timeoutMs);

  /** initialize → InitializedEvent 待ち。 */
  async function initialize() {
    send("initialize", {
      clientID: "vscode",
      adapterID: "ftester",
      pathFormat: "path",
      linesStartAt1: true,
      columnsStartAt1: true,
    });
    await waitForEvent("initialized");
  }

  /** launch リクエストを送って応答を待つ(configurationDone はまだ送らない)。 */
  async function launch(launchArgs) {
    send("launch", { type: "ftester", request: "launch", ...launchArgs });
    await waitForResponse("launch");
  }

  async function configurationDone() {
    send("configurationDone", {});
    await waitForResponse("configurationDone");
  }

  return {
    session,
    messages,
    logs,
    send,
    waitForMessage,
    waitForEvent,
    waitForResponse,
    waitUntil,
    initialize,
    launch,
    configurationDone,
  };
}
