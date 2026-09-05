#!/usr/bin/env node
// mock-slow-cleanup.mjs
// cli.test.mjs のキャンセル方針テスト用フィクスチャ。SIGTERM を無視する(長い終了スクリプトを
// 持つ `fleetest api run` の子を模す)。起動直後に stdout へ "ready\n" を1行出すので、テスト側は
// これを見てから SIGTERM を送れば「ハンドラ登録前に届いて素通りする」競合を避けられる。
// 安全弁として起動 10 秒後に自ら exit する(テストが cleanup を忘れて失敗しても孤児を残さない)。

import { writeSync } from "node:fs";

process.on("SIGTERM", () => {});
writeSync(1, "ready\n");

setInterval(() => {}, 1000);
setTimeout(() => process.exit(0), 10000);
