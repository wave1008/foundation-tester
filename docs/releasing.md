# リリース手順(git タグ発行)

git タグ(semver)は**版ピン用**に使う(clone 時の `git checkout <tag>` や `ftester init --ftester-version`)。
配布そのものは git clone + `swift build` / `npm run install-local`(docs/getting-started.md)であり、
タグは必須ではないが、特定版に固定したい受け手のために発行する。

## 版は3つ(独立)

| 版 | 置き場所 | いつ上げる | 参照する側 |
|---|---|---|---|
| **git タグ**(例 `0.1.0`) | `git tag` | ftester 本体(CLI/Swift パッケージ)をリリースするたび | `git checkout <tag>` / `ftester init --ftester-version` |
| **拡張の version** | `vscode-ftester/package.json` | 拡張の挙動を変えたとき | VSIX(別途 publish。Marketplace 等) |
| **プロトコル版** | `Sources/FTCore/ProtocolVersion.swift` | 拡張↔CLI の JSON/NDJSON 契約を**後方非互換に**変えたときだけ +1 | 起動時の版照合(compatCheck.ts) |

これらは**別系統**。git タグを切っても拡張の version は変わらない(逆も同様)。プロトコル版は
契約が壊れるときだけ動かす(CLAUDE.md「ビルド・検証」参照)。

タグは **`v` プレフィックス無しの semver**(`0.1.0`)。SPM の `from:` が解釈できる形。

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
git clone https://github.com/wave1008/foundation-tester.git /tmp/ftester-check
cd /tmp/ftester-check && git checkout 0.1.0 && swift build && .build/debug/ftester --help | head -3
```

受け手の利用フローは docs/getting-started.md を参照。特定版に固定したい場合は clone 後に
`git checkout <tag>` してからビルドする。

## まだ手動なもの(未整備)

- **拡張の Marketplace / Open VSX 公開**: publisher アカウントと PAT が要る(`vsce publish` / `ovsx publish`)。
  リポジトリ側のメタデータ(`repository` フィールド等)は整備済み。
- **リリース CI**: 上記を GitHub Actions 等で自動化していない(タグ push を起点にする想定)。
