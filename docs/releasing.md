# リリース手順(git タグ発行と mint 配布)

受け手は ftester を [mint](https://github.com/yonaskolb/Mint) で導入する(docs/getting-started.md 付録)。
mint は **git タグ(semver)**を参照するため、配布 = **タグを発行して push すること**。

## 版は3つ(独立)

| 版 | 置き場所 | いつ上げる | 参照する側 |
|---|---|---|---|
| **git タグ**(例 `0.1.0`) | `git tag` | ftester 本体(CLI/Swift パッケージ)をリリースするたび | mint の `@<ver>` / `ftester init --ftester-version` |
| **拡張の version** | `vscode-ftester/package.json` | 拡張の挙動を変えたとき | VSIX(別途 publish。Marketplace 等) |
| **プロトコル版** | `Sources/FTCore/ProtocolVersion.swift` | 拡張↔CLI の JSON/NDJSON 契約を**後方非互換に**変えたときだけ +1 | 起動時の版照合(compatCheck.ts) |

これらは**別系統**。git タグを切っても拡張の version は変わらない(逆も同様)。プロトコル版は
契約が壊れるときだけ動かす(CLAUDE.md「ビルド・検証」参照)。

タグは **`v` プレフィックス無しの semver**(`0.1.0`)。SPM の `from:` / mint の `@0.1.0` が解釈できる形。

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
mint install wave1008/foundation-tester@0.1.0
~/.mint/bin/ftester --help | head -3
```

受け手の利用フローは docs/getting-started.md「付録: `ftester init` で自分のパッケージにする」を参照。
`ftester init --ftester-version <ver>` の `<ver>` は、その受け手が使う CLI(mint)と**同じタグ**にする
(ブリッジと scenario runtime の版一致のため)。

## まだ手動なもの(未整備)

- **拡張の Marketplace / Open VSX 公開**: publisher アカウントと PAT が要る(`vsce publish` / `ovsx publish`)。
  リポジトリ側のメタデータ(`repository` フィールド等)は整備済み。
- **リリース CI**: 上記を GitHub Actions 等で自動化していない(タグ push を起点にする想定)。
