# リリース手順(git タグ発行)

**受け手の配布口は「最新リリース」**。リリース = `X.Y.Z`(`v` 無しの semver)の git タグ、最新 = semver 最大。
`main` は開発線で、受け手には直接届かない(壊れた途中状態を受け手が引かないため)。

- 導入はプロンプト(「隣に clone して `../foundation-tester/.claude/skills/fleetest-setup/SKILL.md` に
  従ってセットアップして」)。clone 直後は `main` だが、SKILL.md ステップ0 の最初に
  `install.sh --align-release-only` を実行し、クローンを最新リリースへ移してから**手順書を読み直す**
  (手順書・スクリプト・ビルドを同じリリースに揃える。`main` の手順書のまま進むと、リリースの
  スクリプトが知らない引数を渡して落ち得る)。
- 外部構成(作業フォルダとクローンが別)のクローンは、最新リリースタグに detached で置かれ、
  `.git/config` の `fleetest.channel=release` で「リリース追従」と記録される(追跡ファイルではないので
  クローンを汚さない)。`install.sh` / `update.sh` は毎回このクローンを最新リリースへ移す
  (ローカルの方が新しいタグなら下げない)。`update.sh` は版が変わったら間のリリースノートを
  「What's new」として表示する。
- 更新の通知は `Scripts/update-check.sh`(読み取りのみ)。`channel=release|branch|pinned` を出し、
  release では `local_version` / `latest_version` を比べて新しいリリースがあれば `update-available`。
  `--notes` でリリースノートを表示する(クローンを触らない)。VSCode 拡張は1日1回これを呼び、
  「変更内容」ボタンでリリースノートを OUTPUT に出す。
- clone 構成(保守者がクローンの中で作業)は `channel=branch`(ブランチ追従のまま)。受け手が手で別のタグを
  checkout したクローン(`fleetest.channel` 未設定の detached)は `pinned` で、動かさない。
- リモートランナー(`fleetest remote setup` / `Scripts/align.sh`)は手元のコミットへ揃える(リリース追従の対象外)。`remote setup` は手元の install.sh を送るので `--track-branch` を渡してリリースタグへ移さない(移すと「手元のスクリプト + リリースのバイナリ」になり新しい引数が通じない。`RemoteSetupPlan.installArgs`)。

配布そのものは git clone + `swift build` / `npm run install-local`(docs/user-docs/quick-start_ja.md)。
プラグインと `install-skill.sh` は廃止済み(理由は docs/maintainer-notes.md §2.3)。既定フローは
`fleetest init --fleetest-path`(隣の clone)なので、SPM の `from:` を使う版指定は通らない。

## 版は3つ(独立)

| 版 | 置き場所 | いつ上げる | 参照する側 |
|---|---|---|---|
| **git タグ**(例 `0.1.0`) | `git tag` | 受け手へ届けたい変更をまとめてリリースするたび | 受け手の配布口(最新 = semver 最大)。注釈 = リリースノート。`update-check.sh` / `install.sh` / `update.sh` が参照 |
| **拡張の version** | `vscode-fleetest/package.json` | 拡張の挙動を変えたとき | VSIX(別途 publish。Marketplace 等) |
| **プロトコル版** | `Sources/FTCore/ProtocolVersion.swift` | 拡張↔CLI の JSON/NDJSON 契約を**後方非互換に**変えたときだけ +1 | 起動時の版照合(compatCheck.ts) |

これらは**別系統**。git タグを切っても拡張の version は変わらない(逆も同様)。プロトコル版は
契約が壊れるときだけ動かす(CLAUDE.md「ビルド・検証」参照)。

タグは **`v` プレフィックス無しの semver**(`0.1.0`)。

## 手順

```bash
# 1. リリースしたい変更をすべてコミット済みにする(作業ツリーをクリーンに)
# 2. リリースノートを書く(Markdown。受け手が読む —— 何が変わったかを平易に)
# 3. ヘルパーでビルド+テスト→タグ作成(push はしない)
Scripts/release.sh 0.1.0 --notes-file /path/to/notes.md

# 4. 問題なければ push(= 公開。受け手の次の更新から届く)
git push origin 0.1.0
#   または最初から: Scripts/release.sh 0.1.0 --notes-file /path/to/notes.md --push
```

`Scripts/release.sh` がやること: semver 検証 → **既存の最新より大きい版かの確認(小さい・同じ版は断る)** →
作業ツリーがクリーンか確認 → タグ重複チェック → `swift build` + `swift test --parallel`(合否は exit code) →
注釈付きタグ作成(**注釈 = `--notes-file` の中身 = リリースノート**)→(`--push` 時のみ)push。

## 発行後の確認

```bash
git clone https://github.com/wave1008/foundation-tester.git /tmp/fleetest-check
cd /tmp/fleetest-check && git checkout <version> && swift build && .build/debug/fleetest --help | head -3
git tag -l --format='%(contents)' <version>   # 注釈がリリースノートとして読めること
# (update-check.sh --notes はリリース追従のクローン = fleetest.channel=release でしか注釈を出さない)
```

受け手の利用フローは docs/user-docs/quick-start_ja.md を参照。

## 保守者だけが使う口(`FLEETEST_REF`)

`FLEETEST_REF=<tag/branch/sha>` は**未マージのブランチを受け手経路で検証する・特定版へ退避する保守者の口**で、
受け手向けの手段ではない(README・user-docs には出さない)。指定すると `fleetest.channel` は外れる(タグ・SHA を渡したクローンは以後 pinned として留まる。ブランチは外部構成では次の `FLEETEST_REF` 無しの実行で最新リリースへ戻るので、検証中は毎回渡す)。ブランチの手順書を検証するには、
**そのブランチを clone してその SKILL.md を読ませ**、install.sh にも同じ ref を渡す。
揃えないと **手順書はブランチ・clone は最新リリース** になり、「直したはずの挙動を確認できない」。

```bash
git clone --branch feat/my-branch https://github.com/wave1008/foundation-tester.git ../foundation-tester
FLEETEST_REF=feat/my-branch bash ../foundation-tester/Scripts/install.sh --work-dir <作業フォルダ>
```

## 壊れたリリースを出したとき

**正道は修正版のパッチリリースを打つこと**(例 `0.1.1`)。最新 = semver 最大なので、受け手は次の更新で
修正版へ移る。タグを消して打ち直さない(すでに取り込んだ受け手のクローンは、ローカルの方が新しいタグなので
下げられず、修正が届かない)。受け手を個別に逃がす必要があるときだけ、保守者が `FLEETEST_REF=<sha>` を渡す。

## リポジトリの引っ越し(owner / repo 名を変える)

座標(`<owner>/<repo>`)は **clone 前・ビルド前に走るシェル**と、**受け手が読む docs** に
散っていて、唯一の定義元を持てない(シェルは Swift を呼べず、docs の URL は読者が読むので
リテラルである必要がある)。そこで「1箇所に集める」のではなく
**唯一の可変点 + 機械での一致強制**にしてある。

1. `Scripts/install.sh` の `REPO_URL` 既定値(`https://github.com/<owner>/<repo>.git`)を新しい座標へ
   書き換える(可変点はここ)
2. 全域を置換する(`git grep -l '<旧座標>' | xargs sed -i '' 's|<旧座標>|<新座標>|g'`)。
   **URL 形と裸の形の両方**がある
3. `vscode-fleetest/test/repoSlug.test.mjs` の `LEGACY_SLUGS` へ**旧座標を足す**
4. `cd vscode-fleetest && npm test` —— 取り残しがあれば `file:line` で全部出る
   (旧座標・URL 形・裸の形を見る)
5. **既存の受け手には周知が要る**。クローンの `origin` は旧 URL のままなので、リダイレクトが
   切れた時点で黙って更新されなくなる。引っ越し直後に旧 URL からの `git pull` を実測する。

## まだ手動なもの(未整備)

- **拡張の Marketplace / Open VSX 公開**: publisher アカウントと PAT が要る(`vsce publish` / `ovsx publish`)。
  リポジトリ側のメタデータ(`repository` フィールド等)は整備済み。
- **リリース CI**: 上記を GitHub Actions 等で自動化していない(タグ push を起点にする想定)。
