// ndjson.test.mjs
// NdjsonParser (src/ndjson.ts) のユニットテスト。node:test で実行する。
// esbuild が "../src/ndjson"(拡張子なし)を ndjson.ts に解決してバンドルする。

import assert from "node:assert/strict";
import { test } from "node:test";
import { NdjsonParser } from "../src/ndjson";

/** NdjsonParser を生成し、パース結果(values)と非JSON行(nonJsonLines)を集める配列を返す。 */
function createCollector() {
  const values = [];
  const nonJsonLines = [];
  const parser = new NdjsonParser(
    (value) => values.push(value),
    (line) => nonJsonLines.push(line),
  );
  return { parser, values, nonJsonLines };
}

test("1行が複数チャンクに割れても正しくパースできる", () => {
  const { parser, values } = createCollector();
  const line = '{"kind":"log","message":"hello world"}\n';
  const buf = Buffer.from(line, "utf8");

  // 1バイトずつのチャンクに分割して push する(極端な分断)。
  for (let i = 0; i < buf.length; i += 1) {
    parser.push(buf.subarray(i, i + 1));
  }

  assert.deepEqual(values, [{ kind: "log", message: "hello world" }]);
});

test("複数行が1チャンクにまとまっていても全行パースできる", () => {
  const { parser, values } = createCollector();
  const chunk = Buffer.from(
    '{"kind":"a"}\n{"kind":"b"}\n{"kind":"c"}\n',
    "utf8",
  );
  parser.push(chunk);

  assert.deepEqual(values, [{ kind: "a" }, { kind: "b" }, { kind: "c" }]);
});

test("日本語(マルチバイトUTF-8)がチャンク境界で分断されても文字化けしない", () => {
  const { parser, values } = createCollector();
  const original = { kind: "log", message: "ログインとエラー表示: ようこそ" };
  const line = JSON.stringify(original) + "\n";
  const buf = Buffer.from(line, "utf8");

  // "ようこそ" などの3バイト文字の途中で分断されるよう、境界をずらして2チャンクに分ける。
  // 複数のオフセットで試し、どの位置で割れても壊れないことを確認する。
  for (let splitAt = 1; splitAt < buf.length; splitAt += 1) {
    const { parser: p, values: v } = createCollector();
    p.push(buf.subarray(0, splitAt));
    p.push(buf.subarray(splitAt));
    assert.deepEqual(v, [original], `splitAt=${splitAt} で復元に失敗`);
  }

  // 素通しの1回 push でも当然通ること。
  parser.push(buf);
  assert.deepEqual(values, [original]);
});

test("空行は無視し、非JSON行は onNonJson に渡す", () => {
  const { parser, values, nonJsonLines } = createCollector();
  const chunk = Buffer.from(
    ['{"kind":"a"}', "", "not json here", '  ', '{"kind":"b"}', ""].join("\n") + "\n",
    "utf8",
  );
  parser.push(chunk);

  assert.deepEqual(values, [{ kind: "a" }, { kind: "b" }]);
  assert.deepEqual(nonJsonLines, ["not json here"]);
});

test("最終行に改行が無いまま EOF になっても end() で処理される", () => {
  const { parser, values, nonJsonLines } = createCollector();
  parser.push(Buffer.from('{"kind":"a"}\n{"kind":"b"}', "utf8")); // 2行目に \n が無い
  assert.deepEqual(values, [{ kind: "a" }]); // end() を呼ぶまでは未確定

  parser.end();
  assert.deepEqual(values, [{ kind: "a" }, { kind: "b" }]);
  assert.deepEqual(nonJsonLines, []);

  // end() 後、buffer が空ならもう一度呼んでも何も起きない。
  parser.end();
  assert.deepEqual(values, [{ kind: "a" }, { kind: "b" }]);
});

test("CRLF 改行でも末尾の \\r が取り除かれてパースできる", () => {
  const { parser, values } = createCollector();
  parser.push(Buffer.from('{"kind":"a"}\r\n{"kind":"b"}\r\n', "utf8"));
  assert.deepEqual(values, [{ kind: "a" }, { kind: "b" }]);
});
