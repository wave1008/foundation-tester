// リポジトリ座標(owner/repo)のドリフト検出。
// 契約: 配布経路の座標は**すべて同じ slug を指す**。唯一の可変点は
// `Scripts/install-skill.sh` の `REPO=` で、リポジトリを引っ越すときはそこを書き換えてから
// 全域を置換し、このテストで取り残しを落とす(手順は docs/releasing.md「リポジトリの引っ越し」)。
//
// 座標は clone より前・ビルドより前に走るシェルと、受け手が読む docs と、プラグイン manifest に
// 散っており、**唯一の定義元を持てない**(シェルは Swift を呼べず、docs の URL は読者が読むので
// リテラルである必要がある)。だから「1箇所に集める」のではなく「全部書いてあるが一致を機械で
// 強制する」形にしてある。agentIntegration.test.mjs(規約位置の手写しのドリフト検出)と同じ型。
//
// process.cwd() は npm test 実行時に vscode-fleetest ルート。

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

const ROOT = path.join(process.cwd(), "..");

/** 正典の slug(唯一の可変点)。ここを読めているかがこのテストの前提。 */
function canonicalSlug() {
  const sh = readFileSync(path.join(ROOT, "Scripts/install-skill.sh"), "utf8");
  const m = sh.match(/^REPO="([^"]+)"$/m);
  assert.ok(m, "Scripts/install-skill.sh の REPO=\"<owner>/<repo>\" 行が見つかりません(唯一の可変点)");
  return m[1];
}

// 上流(依存ライブラリ・外部ツール)の URL。**正典と別で正しい**ものだけをここに列挙する。
// 新しい依存を足して落ちたら、上流だと確認してから足す —— 素通しにすると
// 「引っ越しで取り残された自分の座標」と区別が付かなくなる。
const UPSTREAM_SLUGS = new Set([
  "apple/swift-argument-parser",
  "apple/swift-protobuf",
  "borisyankov/DefinitelyTyped",
  "gradle/gradle",
  "grpc/grpc-swift",
  "grpc/grpc-swift-2",
  "grpc/grpc-swift-nio-transport",
  "grpc/grpc-swift-protobuf",
  "microsoft/vscode-debugadapter-node",
  "react-native-community/cli",
  "swiftlang/swift-syntax",
  "yonaskolb/XcodeGen",
]);

// 走査対象は **git が追跡しているファイルだけ**。作業ツリーを歩くと、依存の展開先
// (`E2EAppRN/ios/Pods/` の podspec 数十本など)が上流 URL を大量に持ち込み、
// 「引っ越しの取り残し」と区別できなくなる。配るのは追跡しているものだけなので走査もそこに揃える。
// 追跡していても外すのは、上流 URL が数百行入るロックファイルと、**受け手資産の TestProjects/**
// (ユーザーのシナリオと、受け手が持ち込んだ docs のコピー)。
const SKIP_FILES = new Set(["package-lock.json", "Package.resolved"]);
const SKIP_PREFIXES = ["TestProjects/", "third_party/"];
const TEXT_EXT = new Set([
  ".md", ".sh", ".json", ".swift", ".ts", ".mjs", ".js", ".yml", ".yaml",
  ".toml", ".txt", ".properties", ".xcconfig", ".gradle", ".kts",
]);

const SLUG_RE = /(?:github\.com|raw\.githubusercontent\.com)\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)/g;

// 引っ越しで**取り残された古い座標**。移転したら旧 slug をここへ足す —— URL 形も裸の形
// (`claude plugin marketplace add <owner>/<repo>`)も、どこに残っていても落ちる。
// 空でよいのは一度も移転していない間だけ。
const LEGACY_SLUGS = [];

/** 裸の `<owner>/<repo>` 形(プラグイン導入コマンドがこの形)。URL 形と別に見る必要がある。 */
function bareSlugRegex(repoName) {
  const escaped = repoName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // owner の直前がパス区切り・英数字なら**ファイルシステムのパス**(`~/github/foundation-tester`・
  // `/tmp/x/foundation-tester`・`../foundation-tester`・`$BASE/foundation-tester`)であって
  // 座標ではない。URL 形は SLUG_RE が見るので、ここで拾うのは行中に素で置かれた形だけ。
  return new RegExp(`(?<![\\w./$-])([A-Za-z0-9][A-Za-z0-9_.-]*)\\/${escaped}(?![A-Za-z0-9_.-])`, "g");
}

function trackedTextFiles() {
  const out = execFileSync("git", ["ls-files", "-z"], { cwd: ROOT, encoding: "utf8" });
  return out
    .split("\0")
    .filter(Boolean)
    .filter((rel) => !SKIP_FILES.has(path.basename(rel)))
    .filter((rel) => !SKIP_PREFIXES.some((p) => rel.startsWith(p)))
    .filter((rel) => TEXT_EXT.has(path.extname(rel)))
    // 削除済みだが未コミットのファイルは ls-files に残る(コミット前のローカルで落ちない)
    .filter((rel) => existsSync(path.join(ROOT, rel)))
    // シンボリックリンクは実体を別途走査するので読まない
    .filter((rel) => !lstatSync(path.join(ROOT, rel)).isSymbolicLink());
}

test("正典の slug が <owner>/<repo> の形で読める", () => {
  const slug = canonicalSlug();
  assert.match(slug, /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, `slug の形が不正: ${slug}`);
});

test("座標を持つ全ファイルが正典の slug を指している", () => {
  const canon = canonicalSlug();
  const [canonOwner, canonRepo] = canon.split("/");
  const bareRe = bareSlugRegex(canonRepo);
  const offenders = new Set();
  for (const rel of trackedTextFiles()) {
    const src = readFileSync(path.join(ROOT, rel), "utf8");
    src.split("\n").forEach((line, i) => {
      const at = `${rel}:${i + 1}`;
      for (const m of line.matchAll(SLUG_RE)) {
        const slug = `${m[1]}/${m[2].replace(/\.git$/, "")}`;
        // sponsors/<user> は npm の funding URL(リポジトリ座標ではない)
        if (m[1] === "sponsors") continue;
        if (slug === canon || UPSTREAM_SLUGS.has(slug)) continue;
        offenders.add(`${at}  ${slug}`);
      }
      // URL 形でない裸の slug(`claude plugin marketplace add <owner>/<repo>`)
      for (const m of line.matchAll(bareRe)) {
        if (m[1] === canonOwner) continue;
        offenders.add(`${at}  ${m[1]}/${canonRepo}`);
      }
      for (const legacy of LEGACY_SLUGS) {
        if (line.includes(legacy)) offenders.add(`${at}  ${legacy} (旧座標)`);
      }
    });
  }
  assert.deepEqual(
    [...offenders],
    [],
    `正典(${canon})でも上流でもない座標があります。引っ越しの取り残しなら置換し、`
      + `新しい上流なら UPSTREAM_SLUGS へ足してください:\n  ${[...offenders].join("\n  ")}`,
  );
});

// 引っ越しで**書き換え忘れると沈黙で壊れる**面。座標を含まなくなった時点で落とし、
// 「置換したつもりで対象から漏れていた」を検出する。
const MUST_CARRY_SLUG = [
  "README.md",
  "Scripts/install.sh",
  "Scripts/install-skill.sh",
  "Scripts/preflight.sh",
  "Scripts/update.sh",
  "Sources/FTCore/ProjectScaffold.swift",
  "vscode-fleetest/package.json",
  ".claude/skills/fleetest-setup/SKILL.md",
  ".claude/skills/fleetest-mcp/SKILL.md",
  ".claude/skills/fleetest-update/SKILL.md",
  "docs/user-docs/getting-started.md",
  "docs/user-docs/getting-started_ja.md",
];

test("配布経路の各ファイルが正典の slug を実際に持っている", () => {
  const canon = canonicalSlug();
  for (const rel of MUST_CARRY_SLUG) {
    const src = readFileSync(path.join(ROOT, rel), "utf8");
    assert.ok(src.includes(canon), `${rel} に座標 ${canon} がありません(引っ越しの置換漏れ?)`);
  }
});

test("marketplace の owner が正典の owner と一致する", () => {
  const canon = canonicalSlug();
  const owner = canon.split("/")[0];
  const marketplace = JSON.parse(
    readFileSync(path.join(ROOT, ".claude-plugin", "marketplace.json"), "utf8"),
  );
  assert.equal(marketplace.owner?.name, owner, "marketplace.json の owner.name が正典の owner と不一致");
});
