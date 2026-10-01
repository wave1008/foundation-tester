// curl | bash で実行されるスクリプトは本体全体を { } で括る。括らないと bash はスクリプトを
// stdin から少しずつ読みながら実行するので、stdin を読む子プロセス(doctor の中の adb 等)が
// 残りを吸い、exit 0 のまま黙って途中で終わる(install.sh の集計と Next steps が受け手に
// 一度も出ていなかった)。
//
// 対象は受け手・スキルが `curl … | bash` で呼ぶ3本。足したら PIPED へ足す。

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const PIPED = ["Scripts/install.sh", "Scripts/preflight.sh", "Scripts/update.sh"];

for (const rel of PIPED) {
  test(`${rel} は本体全体を { } で括っている`, () => {
    const lines = readFileSync(path.join(ROOT, rel), "utf8").split("\n");
    const firstCode = lines.findIndex((l, i) => i > 0 && l.trim() !== "" && !l.trimStart().startsWith("#"));
    assert.equal(lines[firstCode], "{", `${rel}: 最初のコード行が { でない(実際: ${JSON.stringify(lines[firstCode])})`);
    const lastCode = lines.findLastIndex((l) => l.trim() !== "" && !l.trimStart().startsWith("#"));
    assert.equal(lines[lastCode], "}", `${rel}: 最後のコード行が } でない(実際: ${JSON.stringify(lines[lastCode])})`);
  });
}

// 括り方が効くことの陽性対照: stdin を読み尽くす子プロセスの後の行が、括れば実行され、
// 括らなければ実行されない(この差が無いなら上の検査は意味を持たない)。
test("括ると stdin を読む子プロセスの後も実行が続く", () => {
  const body = "cat >/dev/null\necho AFTER\n";
  const bare = spawnSync("bash", [], { input: body, encoding: "utf8" });
  const wrapped = spawnSync("bash", [], { input: `{\n${body}}\n`, encoding: "utf8" });
  assert.equal(bare.stdout, "", "括らない形で AFTER が出た(前提が崩れた)");
  assert.equal(wrapped.stdout, "AFTER\n");
});
