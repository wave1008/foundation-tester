# Claude Code のスキル

[in English](claude_code_skills.md)

fleetest は、導入・プロファイル設定・シナリオ作成を自動化する Claude Code
スキル群を備えています。いずれも人が手で打つのと同じスクリプト・CLI コマンドを裏で呼び出し、
検証ゲートと、判断や承認が本当に人手を要する箇所だけの人間チェックポイントを備えています。

他のエージェント(Codex・Cline など)でも同じ runbook が動きます — MCP サーバの登録と
手順書の渡し方は[Claude Code 以外の AIアシスタント](./other_agents_ja.md)を参照してください。

## スキルの導入

スキルはインストーラ(`install.sh`)が作業フォルダの `.claude/skills/` へコピーします。導入は
[はじめに](../../getting-started_ja.md)の手順(AIアシスタントに頼む)で行い、更新のたびに
コピーも更新されます(コピーを更新したあとは Claude Code を再起動してください)。
呼び出しは `/fleetest-scenario` のように名前だけで行います。

配布口は `main` の1本です(版を固定する導線はありません)。更新の取り込みは
[更新](../../update_ja.md)の手順か `/fleetest-update` で行います。

## スキル一覧

| スキル | コマンド | 役割 |
|---|---|---|
| `fleetest-setup` | `/fleetest-setup` | 初回導入一式(未クローンなら clone・ビルド・環境検証・VSCode 拡張のインストール。テストプロジェクトとプロファイルは作らない = `fleetest-profiles`) |
| `fleetest-update` | `/fleetest-update` | upstream の更新取り込み(git pull → `TestProjects/`/`Package.swift` の再整合 → 再ビルド → VSCode 拡張の再インストール → 反映) |
| `fleetest-profiles` | `/fleetest-profiles` | アプリ/実行プロファイルを1回のフローでまとめて作成(iOS/Android の確認、アプリの表示名/アプリID を聞き、デバイスは既存を選ぶか新規作成) |
| `fleetest-scenario` | `/fleetest-scenario` | セットアップ済みプロジェクトに Swift DSL のシナリオ(`.swift`)を1本作成(ライブ探索からコンパイル検証まで) |
| `fleetest-mcp` | `/fleetest-mcp` | MCP サーバ(`fleetest-mcp`)だけを Claude Code に登録(VSCode 拡張・プロジェクト作成・プロファイル設定は行わない) |
| `fleetest-remote-setup` | `/fleetest-remote-setup` | 別の Mac をランナー機として用意し、手元から SSH 経由でシナリオをディスパッチできるようにする |

`fleetest-setup` が初回導入の入口で、他のスキルはこれ(または同等の手動セットアップ)が
済んでいることを前提にしています。

## `fleetest-scenario` の流れ

`/fleetest-scenario` は次の順で進みます。

1. **対象アプリ(アプリプロファイル)を確認** — 人間チェックポイント。
2. **デバイスを用意してライブ探索**し、動いているアプリから実セレクタを採取する。
3. **シナリオ(`.swift`)を書く**。
4. **コンパイル検証ゲート。**
5. **dry-run ゲート** — デバイス不要・数秒。
6. **デバイスで実行し、意図通りか確認** — 人間チェックポイント。

書いてすぐデバイス実行に進むと、誤りに気付くのはデバイス実行1回分の待ち時間の後になります。
コンパイルと dry-run のゲートを挟むことで、ほとんどの誤りを数秒で捕まえられます。

## 更新

[更新](../../update_ja.md)の手順(モニターの「更新する」ボタン・
`/fleetest-update`・`bash <TOOL_ROOT>/Scripts/update.sh`)で、スキルのコピーも更新されます。
反映には Claude Code の再起動が必要です。

### Link
- [index](../../index_ja.md)
