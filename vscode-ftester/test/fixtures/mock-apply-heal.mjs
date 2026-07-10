#!/usr/bin/env node
// mock-apply-heal.mjs
// `ftester api apply-heal` を模したダミースクリプト。cli.ts の stdin 対応 spawn
// (CliInvocation.stdin)を検証するためのフィクスチャ(実バイナリは使わない)。
//
// 契約(Sources/ftester/ApiApplyHealCommand.swift と同じ):
//   stdin: {"fixes":[{"scenarioID":...,"file":...,"line":...,"oldSelector":...,
//                     "newSelector":...,"newComment":string|null}, ...]}
//   stdout(1行JSON): {"applied":["<id>",...],"failures":[{"id":"<id>","message":"..."}]}
//   id = "<scenarioID>|<file>:<line>|<oldSelector>"
//
// 判定規則(テストが結果を作り分けるための素朴なルール): newSelector に "FAIL" を含む fix は
// 失敗扱い(failures に message 付きで積む)、それ以外は applied に積む。
// 診断は stderr のみ(実物と同じく stdout は結果1行のみ)。

import { writeSync } from "node:fs";
import process from "node:process";

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function fixId(fix) {
  return `${fix.scenarioID}|${fix.file}:${String(fix.line)}|${fix.oldSelector}`;
}

const raw = await readStdin();
let input;
try {
  input = JSON.parse(raw);
} catch (error) {
  writeSync(2, `mock-apply-heal: stdin の JSON を解析できません: ${String(error)}\n`);
  writeSync(1, `${JSON.stringify({ applied: [], failures: [] })}\n`);
  process.exit(1);
}

const fixes = Array.isArray(input.fixes) ? input.fixes : [];
const applied = [];
const failures = [];
for (const fix of fixes) {
  const id = fixId(fix);
  if (typeof fix.newSelector === "string" && fix.newSelector.includes("FAIL")) {
    failures.push({ id, message: `模擬エラー: ${fix.newSelector}` });
  } else {
    applied.push(id);
  }
}

writeSync(1, `${JSON.stringify({ applied, failures })}\n`);
process.exit(0);
