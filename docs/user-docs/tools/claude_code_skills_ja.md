# Claude Code スキル

fleetest プラグインは、導入・プロファイル設定・シナリオ作成を自動化する Claude Code
スキル群を提供します。いずれも人が手で打つのと同じスクリプト・CLI コマンドを裏で呼び出し、
検証ゲートと、判断や承認が本当に人手を要する箇所だけの人間チェックポイントを備えています。

Codex を使う場合も同じ runbook が動きます — [Codex](./codex_skills_ja.md) を参照してください。

## プラグインの導入

```bash
claude plugin marketplace add wave1008/foundation-tester
claude plugin marketplace update foundation-tester
claude plugin install fleetest@foundation-tester --scope user
```

`marketplace update` が効くのは、マーケットプレイスが既に追加済みの場合です。そのとき `add` は
何も取得しないため、古いキャッシュのまま install すると
`Plugin "fleetest" not found in marketplace` で失敗します。一度も追加していない機械では no-op です。

配布口は `main` の1本です(版を固定する導線はありません)。更新の取り込みは
[更新](../getting-started_ja.md)の手順か `/fleetest:fleetest-update` で行います。

プラグイン機構が無い環境では、同等のスキル群を直接インストールできます。

```bash
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install-skill.sh | sh
```

## スキル一覧

| スキル | コマンド | 役割 |
|---|---|---|
| `fleetest-setup` | `/fleetest:fleetest-setup` | 初回導入一式(未クローンなら clone・ビルド・環境検証・プロジェクト作成・マシン/アプリのプロファイル設定・VSCode 拡張のインストール) |
| `fleetest-update` | `/fleetest:fleetest-update` | upstream の更新取り込み(git pull → `TestProjects/`/`Package.swift` の再整合 → 再ビルド → VSCode 拡張の再インストール → 反映) |
| `fleetest-profiles` | `/fleetest:fleetest-profiles` | マシン/アプリ/実行プロファイルを1回のフローでまとめて作成(iOS/Android の確認、アプリの表示名/アプリID を聞き、デバイスは既存を選ぶか新規作成) |
| `fleetest-scenario` | `/fleetest:fleetest-scenario` | セットアップ済みプロジェクトに Swift DSL のシナリオ(`.swift`)を1本作成(ライブ探索からコンパイル検証まで) |
| `fleetest-mcp` | `/fleetest:fleetest-mcp` | MCP サーバ(`fleetest-mcp`)だけを Claude Code に登録(VSCode 拡張・プロジェクト作成・プロファイル設定は行わない) |
| `fleetest-remote-setup` | `/fleetest:fleetest-remote-setup` | 別の Mac をランナー機として用意し、手元から SSH 経由でシナリオをディスパッチできるようにする |

`fleetest-setup` が初回導入の入口で、他のスキルはこれ(または同等の手動セットアップ)が
済んでいることを前提にしています。

## `fleetest-scenario` の流れ

`/fleetest:fleetest-scenario` は次の順で進みます。

1. **対象アプリ(アプリプロファイル)を確認** — 人間チェックポイント。
2. **デバイスを用意してライブ探索**し、動いているアプリから実セレクタを採取する。
3. **シナリオ(`.swift`)を書く**。
4. **コンパイル検証ゲート。**
5. **dry-run ゲート** — デバイス不要・数秒。
6. **デバイスで実行し、意図通りか確認** — 人間チェックポイント。

書いてすぐデバイス実行に進むと、誤りに気付くのはデバイス実行1回分の待ち時間の後になります。
コンパイルと dry-run のゲートを挟むことで、ほとんどの誤りを数秒で捕まえられます。

## 更新

```bash
claude plugin marketplace update foundation-tester
claude plugin update fleetest@foundation-tester
```

どちらも必要です(マーケットプレイスの一覧を更新するだけでは、導入済みのプラグインは
更新されません)。反映には Claude Code の再起動が必要です。

### Link
- [index](../index_ja.md)
