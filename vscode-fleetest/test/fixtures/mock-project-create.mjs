#!/usr/bin/env node
// mock-project-create.mjs
// `fleetest project create <name>` を模したダミー。cwd(ワークスペースルート)の
// TestProjects/<name>/scenarios/_Main.swift を作り、実物と同じく人向けの文を stdout に出す。
// 環境変数 MOCK_PROJECT_CREATE_FAIL=1 なら何も作らず stderr にエラーを出して exit 1。
import { mkdirSync, writeFileSync, writeSync } from "node:fs";
import path from "node:path";
import process from "node:process";

const args = process.argv.slice(2);
if (args[0] !== "project" || args[1] !== "create" || typeof args[2] !== "string") {
  writeSync(2, `unexpected args: ${JSON.stringify(args)}\n`);
  process.exit(64);
}
if (process.env.MOCK_PROJECT_CREATE_FAIL === "1") {
  writeSync(2, "Error: the project already exists: /x/TestProjects/default\n");
  process.exit(1);
}
const scenarios = path.join(process.cwd(), "TestProjects", args[2], "scenarios");
mkdirSync(scenarios, { recursive: true });
writeFileSync(path.join(scenarios, "_Main.swift"), "// mock\n");
writeSync(1, `✅ Created the project: TestProjects/${args[2]}/\n`);
