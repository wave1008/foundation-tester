// リリースタグ追従の契約(Scripts/update-check.sh / Scripts/install.sh --align-release-only)。
// 一時ディレクトリに上流のベアリポジトリ(注釈付きタグ 0.9.0 / 0.10.0)と受け手のクローンを作り、
// スクリプトを実物のまま回す(swift build 等が走る install.sh の全体は回さず、--align-release-only の範囲だけ)。
//
// 守る性質:
//   - 最新 = semver の数値順の最大(0.10.0 > 0.9.0。文字列ソートにしない)
//   - channel は .git/config の fleetest.channel と HEAD で決まる(release / branch / pinned)
//   - update-check は読み取りのみ(--notes も含め、クローンの refs と FETCH_HEAD を変えない)
//   - latest_release_tag は install.sh と update-check.sh で同一本文(install.sh は単体 scp されるため複製)

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");
const INSTALL_SH = path.join(ROOT, "Scripts/install.sh");
const UPDATE_CHECK_SH = path.join(ROOT, "Scripts/update-check.sh");
const UPDATE_SH = path.join(ROOT, "Scripts/update.sh");

const GIT_ENV = {
  ...process.env,
  GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.com",
  GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.com",
  GIT_TERMINAL_PROMPT: "0",
};
delete GIT_ENV.FLEETEST_REF;

function git(cwd, ...args) {
  const r = spawnSync("git", ["-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", ...args], { cwd, env: GIT_ENV, encoding: "utf8" });
  assert.equal(r.status, 0, `git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.trim();
}

function commit(dir, file, tag) {
  writeFileSync(path.join(dir, file), file);
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", file);
  if (tag) git(dir, "tag", "-a", tag, "-m", `fleetest ${tag}\n\nnotes for ${tag}`);
  return git(dir, "rev-parse", "HEAD");
}

/**
 * 上流(ベア)+ 受け手のクローン + 作業フォルダ。
 * cloneAfterRelease=false: 受け手は 0.9.0 の時点で clone し、その後に上流へ 0.10.0 と main の先を足す
 *   (受け手は 0.10.0 のタグオブジェクトを持たない = --notes が受け手を変えないことを意味のある形で検証できる)。
 */
function fixture({ cloneAfterRelease = false } = {}) {
  const base = mkdtempSync(path.join(tmpdir(), "ft-release-track-"));
  const seed = path.join(base, "seed");
  const upstream = path.join(base, "upstream.git");
  const receiver = path.join(base, "foundation-tester");
  const work = path.join(base, "work");
  mkdirSync(seed);
  mkdirSync(work);
  git(seed, "init", "-q", "-b", "main");
  mkdirSync(path.join(seed, "Sources/FTScenarioRunner"), { recursive: true });
  writeFileSync(path.join(seed, "Package.swift"), "// fixture\n");
  writeFileSync(path.join(seed, "Sources/FTScenarioRunner/x.swift"), "// fixture\n");
  const c9 = commit(seed, "nine", "0.9.0");
  git(base, "clone", "-q", "--bare", seed, upstream);
  git(seed, "remote", "add", "origin", upstream);
  const clone = () => git(base, "clone", "-q", upstream, receiver);
  if (!cloneAfterRelease) clone();
  const c10 = commit(seed, "ten", "0.10.0");
  const cMain = commit(seed, "after", null);
  git(seed, "push", "-q", "origin", "main", "--tags");
  if (cloneAfterRelease) clone();
  return { base, seed, upstream, receiver, work, c9, c10, cMain };
}

function parse(stdout) {
  const kv = {};
  for (const line of stdout.split("\n")) {
    const m = line.match(/^([a-z_]+)=(.*)$/);
    if (m) kv[m[1]] = m[2];
  }
  return kv;
}

function updateCheck(f, ...extra) {
  const r = spawnSync("bash", [UPDATE_CHECK_SH, "--tool-root", f.receiver, ...extra], { cwd: f.work, env: GIT_ENV, encoding: "utf8" });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr, kv: parse(r.stdout) };
}

function align(f, ...extra) {
  const r = spawnSync("bash", [INSTALL_SH, "--work-dir", f.work, "--tool-root", f.receiver, "--align-release-only", ...extra], { cwd: f.work, env: GIT_ENV, encoding: "utf8" });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr, kv: parse(r.stdout) };
}

function detachAt(f, tag, channel) {
  git(f.receiver, "fetch", "-q", "origin", "tag", tag);
  git(f.receiver, "checkout", "-q", "--detach", `refs/tags/${tag}`);
  if (channel) git(f.receiver, "config", "fleetest.channel", channel);
}

function cleanup(f) {
  rmSync(f.base, { recursive: true, force: true });
}

test("update-check: release チャンネルで旧タグ → update-available(最新は 0.10.0・remote_head は注釈付きタグの指すコミット)", (t) => {
  const f = fixture();
  t.after(() => cleanup(f));
  detachAt(f, "0.9.0", "release");
  const r = updateCheck(f);
  assert.equal(r.status, 3, r.stdout);
  assert.equal(r.kv.channel, "release");
  assert.equal(r.kv.verdict, "update-available");
  assert.equal(r.kv.local_version, "0.9.0");
  assert.equal(r.kv.latest_version, "0.10.0", "0.10.0 > 0.9.0(文字列ソートにしない)");
  assert.equal(r.kv.remote_head, f.c10, "remote_head はタグオブジェクトでなくコミット(peeled)");
  assert.equal(r.kv.local_head, f.c9);
  assert.match(r.stdout, /New release 0\.10\.0 is available \(current 0\.9\.0\)/);
});

test("update-check: release チャンネルで最新タグ → up-to-date", (t) => {
  const f = fixture({ cloneAfterRelease: true });
  t.after(() => cleanup(f));
  detachAt(f, "0.10.0", "release");
  const r = updateCheck(f);
  assert.equal(r.status, 0, r.stdout);
  assert.equal(r.kv.verdict, "up-to-date");
  assert.equal(r.kv.local_version, "0.10.0");
});

test("update-check: ローカルの方が新しいタグにいても更新とは言わない", (t) => {
  const f = fixture({ cloneAfterRelease: true });
  t.after(() => cleanup(f));
  detachAt(f, "0.10.0", "release");
  git(f.receiver, "tag", "0.11.0");
  const r = updateCheck(f);
  assert.equal(r.kv.local_version, "0.11.0");
  assert.equal(r.kv.verdict, "up-to-date");
  assert.equal(r.status, 0);
});

test("update-check: detached で channel 未設定 → pinned", (t) => {
  const f = fixture();
  t.after(() => cleanup(f));
  detachAt(f, "0.9.0", null);
  const r = updateCheck(f);
  assert.equal(r.status, 0);
  assert.equal(r.kv.channel, "pinned");
  assert.equal(r.kv.verdict, "pinned");
});

test("update-check: ブランチ上は従来どおり追跡ブランチの先頭と比べる", (t) => {
  const f = fixture({ cloneAfterRelease: true });
  t.after(() => cleanup(f));
  let r = updateCheck(f);
  assert.equal(r.kv.channel, "branch");
  assert.equal(r.kv.verdict, "up-to-date");
  assert.equal(r.kv.remote_head, f.cMain);
  git(f.receiver, "reset", "-q", "--hard", f.c9);
  r = updateCheck(f);
  assert.equal(r.status, 3);
  assert.equal(r.kv.verdict, "update-available");
  assert.equal(r.kv.remote_head, f.cMain);
});

test("update-check --notes: 新しい注釈を新しい順に出し、クローンの refs と FETCH_HEAD を変えない", (t) => {
  const f = fixture();
  t.after(() => cleanup(f));
  detachAt(f, "0.9.0", "release");
  const snapshot = () => ({
    refs: git(f.receiver, "for-each-ref"),
    tags: git(f.receiver, "tag"),
    fetchHead: existsSync(path.join(f.receiver, ".git/FETCH_HEAD")) ? readFileSync(path.join(f.receiver, ".git/FETCH_HEAD"), "utf8") : null,
  });
  assert.ok(!snapshot().tags.split("\n").includes("0.10.0"), "前提: 受け手は 0.10.0 を持たない");
  const before = snapshot();
  const r = updateCheck(f, "--notes");
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^## 0\.10\.0$/m);
  assert.match(r.stdout, /notes for 0\.10\.0/);
  assert.ok(!/notes for 0\.9\.0/.test(r.stdout), "ローカル版以下の注釈は出さない");
  assert.ok(!/^fleetest 0\.10\.0$/m.test(r.stdout), "1行目の `fleetest X.Y.Z` は見出しと重複するので除く");
  assert.deepEqual(snapshot(), before);
});

test("update-check --notes: release チャンネル以外は no release notes で 0", (t) => {
  const f = fixture();
  t.after(() => cleanup(f));
  const r = updateCheck(f, "--notes");
  assert.equal(r.status, 0);
  assert.match(r.stdout, /no release notes/);
});

test("install.sh --align-release-only: 未導入の外部構成(main 上)→ moved で detached の最新リリース + channel=release", (t) => {
  const f = fixture();
  t.after(() => cleanup(f));
  const r = align(f);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(r.kv.release_align, "moved");
  assert.equal(r.kv.release_tag, "0.10.0");
  assert.match(r.stdout, /Re-read SKILL\.md: the clone now holds release 0\.10\.0/);
  assert.equal(spawnSync("git", ["symbolic-ref", "-q", "HEAD"], { cwd: f.receiver }).status, 1, "detached になっていない");
  assert.equal(git(f.receiver, "rev-parse", "HEAD"), f.c10);
  assert.equal(git(f.receiver, "config", "--get", "fleetest.channel"), "release");
  // 2回目は動かさない
  const again = align(f);
  assert.equal(again.kv.release_align, "unchanged");
  assert.equal(again.kv.release_tag, "0.10.0");
  assert.ok(!/Re-read/.test(again.stdout));
});

test("install.sh --track-branch: リモートランナー向け。リリース追従をせずブランチのまま(channel も立てない)", (t) => {
  const f = fixture();
  t.after(() => cleanup(f));
  const r = align(f, "--track-branch");
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(r.kv.release_align, "skipped");
  assert.equal(git(f.receiver, "symbolic-ref", "--short", "HEAD"), "main");
  assert.equal(spawnSync("git", ["config", "--get", "fleetest.channel"], { cwd: f.receiver }).status, 1);
});

test("install.sh --align-release-only: 導入済み(.build/debug/fleetest が在る)なら何もしない", (t) => {
  const f = fixture();
  t.after(() => cleanup(f));
  mkdirSync(path.join(f.receiver, ".build/debug"), { recursive: true });
  writeFileSync(path.join(f.receiver, ".build/debug/fleetest"), "#!/bin/sh\n");
  chmodSync(path.join(f.receiver, ".build/debug/fleetest"), 0o755);
  const r = align(f);
  assert.equal(r.status, 0);
  assert.equal(r.kv.release_align, "skipped");
  assert.equal(r.kv.release_tag, "");
  assert.equal(git(f.receiver, "symbolic-ref", "--short", "HEAD"), "main");
  assert.equal(spawnSync("git", ["config", "--get", "fleetest.channel"], { cwd: f.receiver }).status, 1);
});

test("install.sh --align-release-only: ローカルの方が新しいタグなら下げない・手で固定した detached は触らない", (t) => {
  const f = fixture({ cloneAfterRelease: true });
  t.after(() => cleanup(f));
  detachAt(f, "0.10.0", "release");
  git(f.receiver, "tag", "0.11.0");
  let r = align(f);
  assert.equal(r.kv.release_align, "unchanged");
  assert.equal(r.kv.release_tag, "0.11.0");
  git(f.receiver, "config", "--unset", "fleetest.channel");
  git(f.receiver, "checkout", "-q", "--detach", "refs/tags/0.9.0");
  r = align(f);
  assert.equal(r.kv.release_align, "skipped");
  assert.equal(git(f.receiver, "rev-parse", "HEAD"), f.c9);
});

test("install.sh --align-release-only: 作業フォルダが無いクローン(TOOL_ROOT 無し)は skipped で終わる(clone しない)", (t) => {
  const f = fixture();
  t.after(() => cleanup(f));
  const missing = path.join(f.base, "nowhere");
  const r = spawnSync("bash", [INSTALL_SH, "--work-dir", f.work, "--tool-root", missing, "--align-release-only"], { cwd: f.work, env: GIT_ENV, encoding: "utf8" });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(parse(r.stdout).release_align, "skipped");
  assert.ok(!existsSync(missing), "clone してしまった");
});

/** `name() {` から最初の行頭 `}` までの関数本文。 */
function functionBody(file, name) {
  const source = readFileSync(file, "utf8");
  const begin = source.indexOf(`\n${name}() {`);
  assert.ok(begin >= 0, `${path.basename(file)} に ${name} が無い`);
  const end = source.indexOf("\n}\n", begin);
  assert.ok(end > begin, `${name} の終端が見つからない`);
  return source.slice(begin + 1, end + 3);
}

test("latest_release_tag / semver_newer は install.sh と update-check.sh で同一本文(片方だけ変えない)", () => {
  for (const name of ["latest_release_tag", "semver_newer"]) {
    assert.equal(functionBody(INSTALL_SH, name), functionBody(UPDATE_CHECK_SH, name), `${name} が食い違っている`);
  }
  assert.equal(functionBody(INSTALL_SH, "semver_newer"), functionBody(UPDATE_SH, "semver_newer"), "update.sh の semver_newer が食い違っている");
});

test("latest_release_tag: semver 最大を選ぶ(X.Y.Z 以外と ^{} 行は無視)", () => {
  const body = functionBody(INSTALL_SH, "latest_release_tag");
  const lines = [
    "aaa\trefs/tags/0.9.0", "bbb\trefs/tags/0.10.0", "ccc\trefs/tags/0.10.0^{}",
    "ddd\trefs/tags/0.2.0", "eee\trefs/tags/v9.0.0", "fff\trefs/tags/1.0.0-rc1", "",
  ].join("\n");
  const r = spawnSync("bash", ["-c", `${body}\nlatest_release_tag`], { input: lines, encoding: "utf8" });
  assert.equal(r.stdout.trim(), "0.10.0");
  const none = spawnSync("bash", ["-c", `${body}\nlatest_release_tag`], { input: "aaa\trefs/tags/v1\n", encoding: "utf8" });
  assert.equal(none.stdout.trim(), "");
  const sv = functionBody(INSTALL_SH, "semver_newer");
  const newer = (a, b) => spawnSync("bash", ["-c", `${sv}\nsemver_newer ${a} ${b}`]).status;
  assert.equal(newer("0.10.0", "0.9.0"), 0);
  assert.equal(newer("0.9.0", "0.10.0"), 1);
  assert.equal(newer("0.9.0", "0.9.0"), 1);
});
