# CI で回す

シナリオは LLM なしの決定的実行なので CI に向いています(exit code と JUnit XML の両方で
機械的に処理できます)。このページは受け手パッケージを CI で回すための要点だけをまとめたもので、
詳細は [docs/ci.md](../../ci.md) を参照してください。

## 前提

- **サポートするのは self-hosted の Mac だけ**(Jenkins 常駐機・AWS EC2 Mac インスタンス等)。
  iOS シミュレータ / Android エミュレータには macOS が必須のため、GitHub ホストランナー
  (`macos-*`)はサポート外です(実体が macOS VM のため Apple Intelligence が使えず、
  この経路の動作検証もしていません)。
- **ログイン済みの GUI セッションのユーザーで実行してください**(シミュレータ実行の一般則です)。
  ヘッドレスの `LaunchDaemon` や ssh 直のセッションではシミュレータが不安定になります。
- **Apple Intelligence は不要です。** 無くても自己修復・`screenLooksLike`・偽陽性検証は
  自動的にスキップされるだけで(起動時に `⚠️` が1行出ます)、決定的実行(タップ・検証)は
  そのまま全機能動きます。**ただし `screenLooksLike`・`requireVisible` を使うシナリオは、
  この場合は検証されずに素通り(pass)します**(run 末尾の FM 警告がその旨を出します)。
  画面照合を CI でも効かせたい場合は [docs/ci.md](../../ci.md) の「Apple Intelligence を
  CI で使う」を参照してください。
- Xcode(Android を回すなら Android SDK も)がランナーに導入済みであること。

## 実行と結果の取り出し

```bash
# 導入(冪等。2回目以降はほぼ skip)。CI では拡張・MCP は不要
bash foundation-tester/Scripts/install.sh --work-dir "$PWD" --skip-extension --skip-mcp --no-doctor

# 実行: --quiet でステップ行を抑制、--junit で JUnit XML を書く
ftester run --profile ios-xcuitest --quiet --junit reports/junit.xml
```

- **exit code**: `0` = 全シナリオ成功 / `1` = 失敗あり(JUnit は失敗時も書かれます)。
- **JUnit XML**: `<testsuite>` がシナリオクラス、`<testcase>` がシナリオに対応します。失敗には
  最初の失敗ステップの要約・全失敗ステップとソース位置・Markdown レポートのパス・実行した
  worker が入ります。**inconclusive**(`verify` のアサーション0個)は、シナリオの**全ステップ**
  が inconclusive のときだけ `<skipped>` になり、通常のステップと混在する場合は passed の
  `<testcase>` に埋もれます(実行ログと Markdown レポートの ❓ と修正提案で気付けます)。
- **失敗の調査**: `TestProjects/<name>/reports/` に失敗ごとの Markdown レポート(要素一覧・
  スクリーンショット・FM トリアージ)が出ます。ビルド成果物として保存しておくと、JUnit の
  `report:` 行から辿れます。

## Jenkins の例

```groovy
pipeline {
  agent { label 'mac' }   // ログイン済み GUI セッションのユーザーで動くエージェント
  stages {
    stage('Install / update') {
      steps { sh 'bash ../foundation-tester/Scripts/install.sh --work-dir "$PWD" --skip-extension --skip-mcp --no-doctor' }
    }
    stage('Run scenarios') {
      steps { sh '../foundation-tester/.build/debug/ftester run --profile ios-xcuitest --quiet --junit reports/junit.xml' }
    }
  }
  post {
    always  { junit 'reports/junit.xml' }
    failure { archiveArtifacts artifacts: 'reports/junit.xml, TestProjects/*/reports/**', allowEmptyArchive: true }
  }
}
```

- デバイスの供給(シミュレータ起動・ブリッジ)は `--profile` 実行が自動で行います。連続ジョブでは
  稼働中のブリッジが再利用され、コールドスタートは初回だけです。
- ジョブ間で環境を掃除したい場合は、ジョブ末尾に `ftester devices down`(全ブリッジ停止 +
  シミュレータ/エミュレータ全終了)を置きます。

## flaky シナリオの扱い(リトライ機構は意図的に無い)

CI 用のシナリオ単位リトライは実装していません。自動リトライは不安定さを隠して腐らせるためです。
代わりに次を使います。

- **検出**: `ftester results flaky` が pass/fail 混在のシナリオを不安定度順に出します
  (`ftester results insights` は回帰・インフラ起因の失敗・セレクタ陳腐化も検出します)。
- **ローカル再現**: `ftester run --failed` が前回失敗したシナリオだけを再実行します。
- デバイス凍結などインフラ起因の失敗は、**run の内部で自動的に振り直されます**(結果を取り消し、
  別デバイスで再実行)。JUnit には最終結果だけが載ります。これはリトライではなく回復処理です。

### Link
- [index](../index_ja.md)
