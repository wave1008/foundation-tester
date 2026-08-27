# リリース手順(git タグ発行)

**受け手の配布口は `main` の1本だけ**(2026-08-27 決定)。プラグインも `install-skill.sh` も
スキル本文の curl も既定ブランチを引き、**版を固定する導線は受け手に案内しない**。
理由は「案内していたピンが実効していなかった」こと —— プラグインを `#<tag>` で固定しても
スキル本文が引く install.sh と初回 clone は `main` のままで、*タグのスキル + main のツール* に
なっていた。既定フローは `fleetest init --fleetest-path`(隣の clone)なので、SPM の
`from:` を使う版指定もそもそも通らない。

git タグ(semver)は**履歴の目印**として発行する —— 事故のときに「あの時点」へ戻る手掛かりで、
受け手向けの導線ではない。配布そのものは git clone + `swift build` / `npm run install-local`
(docs/user-docs/getting-started_ja.md)。

**受け手が自分で `git checkout <tag>` した clone は壊さない**: install.sh の detached ガードと
`update-check.sh` の `pinned` verdict は残してある(案内しないことと、固定された状態を
勝手に動かさないことは別)。壊れた `main` を引いた受け手を個別に逃がすときは、保守者が
`FLEETEST_REF=<1つ前の sha>` を渡す(下記「保守者だけが使う口」)。

## 版は3つ(独立)

| 版 | 置き場所 | いつ上げる | 参照する側 |
|---|---|---|---|
| **git タグ**(例 `0.1.0`) | `git tag` | fleetest 本体(CLI/Swift パッケージ)をリリースするたび | 保守者だけ(履歴の目印。受け手向けの導線には出さない) |
| **拡張の version** | `vscode-fleetest/package.json` | 拡張の挙動を変えたとき | VSIX(別途 publish。Marketplace 等) |
| **プロトコル版** | `Sources/FTCore/ProtocolVersion.swift` | 拡張↔CLI の JSON/NDJSON 契約を**後方非互換に**変えたときだけ +1 | 起動時の版照合(compatCheck.ts) |

これらは**別系統**。git タグを切っても拡張の version は変わらない(逆も同様)。プロトコル版は
契約が壊れるときだけ動かす(CLAUDE.md「ビルド・検証」参照)。

タグは **`v` プレフィックス無しの semver**(`0.1.0`)。

## 手順

```bash
# 1. リリースしたい変更をすべてコミット済みにする(作業ツリーをクリーンに)
# 2. ヘルパーでビルド+テスト→タグ作成(push はしない)
Scripts/release.sh 0.1.0

# 3. 問題なければ push(= 公開)
git push origin 0.1.0
#   または最初から: Scripts/release.sh 0.1.0 --push
```

`Scripts/release.sh` がやること: semver 検証 → 作業ツリーがクリーンか確認 → タグ重複チェック →
`swift build` + `swift test`(合否は exit code) → 注釈付きタグ作成 →(`--push` 時のみ)push。

## 発行後の確認

```bash
git clone https://github.com/wave1008/foundation-tester.git /tmp/fleetest-check
cd /tmp/fleetest-check && git checkout 0.1.0 && swift build && .build/debug/fleetest --help | head -3
```

受け手の利用フローは docs/user-docs/getting-started_ja.md を参照。

## 保守者だけが使う口(`FLEETEST_REF`)

`FLEETEST_REF=<tag/branch/sha>` は**未マージのブランチを受け手経路で検証するための口**で、
受け手向けの版固定手段ではない(README・user-docs には出さない)。渡さないと
**スキルはブランチ・install.sh と clone は `main`** になり、「直したはずの挙動を確認できない」。
取得の鎖(スキル取得 → install.sh 取得 → clone)はこの1つの ref で揃う。

```bash
FLEETEST_REF=feat/my-branch \
  curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/feat/my-branch/Scripts/install-skill.sh | sh
```

壊れた `main` を引いた受け手を個別に逃がすときも同じ口を使う(`FLEETEST_REF=<1つ前の sha>`)。

## まだ手動なもの(未整備)

- **拡張の Marketplace / Open VSX 公開**: publisher アカウントと PAT が要る(`vsce publish` / `ovsx publish`)。
  リポジトリ側のメタデータ(`repository` フィールド等)は整備済み。
- **リリース CI**: 上記を GitHub Actions 等で自動化していない(タグ push を起点にする想定)。
