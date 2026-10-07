# CI で回す

[in English](ci.md)

シナリオは LLM なしの決定的実行なので CI に向いています(exit code と JUnit XML の両方で
機械的に処理できます)。このページは、テストプロジェクトを CI で回すための要点をまとめたものです。

## 前提

- **サポートするのは self-hosted の Mac だけ**(Jenkins 常駐機・AWS EC2 Mac インスタンス等)。
  iOS Simulator / Android Emulator には macOS が必須のため、GitHub ホストランナー
  (`macos-*`)はサポート外です(実体が macOS VM のため Apple Intelligence が使えず、
  この経路の動作検証もしていません)。
- **ログイン済みの GUI セッションのユーザーで実行してください**(Simulator 実行の一般則です)。
  ヘッドレスの `LaunchDaemon` や ssh 直のセッションでは Simulator が不安定になります。
- **Apple Intelligence は不要です。** 無くても(起動時に `⚠️` が1行出ます)、決定的実行(タップ・検証)と
  自己修復(ロケータの指紋照合。FM を使いません)はそのまま動きます。変わるのは2つです。
  **`screenLooksLike` は判定されずに通ります**。**テキストの視覚検証は OCR だけで判定します**
  ([テキストの視覚検証](../reference/testclass/text_visual_check_ja.md))。
  画面照合を CI でも効かせたい場合は、下の「Apple Intelligence を CI で使う」を見てください。
- Xcode(Android を回すなら Android SDK も)がランナーに導入済みであること。

## 実行と結果の取り出し

```bash
# 導入(冪等。2回目以降はほぼ skip)。CI では拡張・MCP は不要
bash foundation-tester/Scripts/install.sh --work-dir "$PWD" --skip-extension --skip-mcp --no-doctor

# 実行: --quiet でステップ行を抑制、--junit で JUnit XML を書く
fleetest run --profile ios-xcuitest --quiet --junit reports/junit.xml
```

- **exit code**: `0` = 全シナリオ成功 / `1` = 失敗あり(JUnit は失敗時も書かれます)。
- **JUnit XML**: `<testsuite>` がシナリオクラス、`<testcase>` がシナリオに対応します。失敗には
  最初の失敗ステップの要約・全失敗ステップとソース位置・Markdown レポートのパス・実行した
  worker が入ります。**inconclusive**(`verify` のアサーション0個)は、シナリオの**全ステップ**
  が inconclusive のときだけ `<skipped>` になり、通常のステップと混在する場合は passed の
  `<testcase>` に埋もれます(実行ログと Markdown レポートの ❓ と修正提案で気付けます)。
- **失敗の調査**: `TestProjects/<name>/reports/` に失敗ごとの Markdown レポート(要素一覧・
  スクリーンショット・自己修復の提案)が出ます。ビルド成果物として保存しておくと、JUnit の
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
      steps { sh '../foundation-tester/.build/debug/fleetest run --profile ios-xcuitest --quiet --junit reports/junit.xml' }
    }
  }
  post {
    always  { junit 'reports/junit.xml' }
    failure { archiveArtifacts artifacts: 'reports/junit.xml, TestProjects/*/reports/**', allowEmptyArchive: true }
  }
}
```

- デバイスの供給(Simulator 起動・ブリッジ)は `--profile` 実行が自動で行います。連続ジョブでは
  稼働中のブリッジが再利用され、コールドスタートは初回だけです。
- run はブリッジを止めません。ブリッジは最後のリクエストから一定時間(`FT_BRIDGE_TTL`。既定 2 時間)
  通信が無いと自動で終了し、終了したブリッジの作業ファイルは次のジョブの開始時に削除されます。
  iOS のブリッジの作業ファイルは**動いている間ずっと増えます**(操作中は 1 本あたり毎時 120〜240MB 程度)。
  夜間などジョブが 2 時間以上空く運用なら掃除は不要です。**24 時間ジョブが途切れない運用では**、
  定期的に `fleetest devices down` を実行してください。
- ジョブ間で環境を掃除したい場合は、ジョブ末尾に `fleetest devices down`(全ブリッジ停止 +
  Simulator/Emulator 全終了)を置きます。同じ Mac で別のテスト実行がデバイスを使っている間は、
  実行中のテストを止めないよう何も停止せずに終了コード 1 で終わります。同じ Mac でジョブが
  重なりうる場合は、他のジョブが動いていない時間帯に掃除を置いてください。
- **1台の Mac で同時に走る実行は1本です。** 同じエージェントで2本目の `fleetest run` は開始せず、
  `another fleetest run is already running on this Mac` で止まります。同じエージェントを使う
  ジョブが重ならないようにするか、失敗させずに順番待ちさせる `--wait-lock <秒>` を付けてください
  ([並列実行](../reference/running/parallel_execution_ja.md)参照)。

## Apple Intelligence を CI で使う(任意)

Apple Intelligence は、ランナーの実体が物理 Mac(ベアメタル)のときだけ使えます。macOS の VM
(Tart・Anka など)では有効化できないため、使えない前提で組んでください。

- 物理 Mac(Jenkins 常駐機など): 使えます。
- AWS EC2 Mac(ベアメタル): 原理的には使えるはずですが、未検証です。
- macOS の VM: 使えません。`screenLooksLike` は判定されずに通り、テキストの視覚検証は OCR だけで判定します。

ベアメタルで有効にするときの条件です。

- Apple silicon で macOS 26 以上。`screenLooksLike` とテキストの視覚検証(画像入力)は macOS 27 以上が必要です。
- 有効化は GUI で1回行います(macOS 27 は システム設定 → Siri で Siri をオン(Siri が Apple Intelligence を使います)、macOS 26 は システム設定 → Apple Intelligence と Siri で「Apple Intelligence」をオン。画面の無い機械は画面共有経由。
  モデルのダウンロードが走ります)。EC2 Mac は素の AMI から作り直すと設定が消えるので、有効化したあとにカスタム AMI を作るか、
  プロビジョニングに有効化を含めてください。
- ジョブの先頭で `fleetest doctor --fm-only` を実行し、終了コードで確かめてください。設定画面の表示が「使える」でも
  実際には呼べないことがあるため、doctor は実際に推論して確かめます。
- FM はその Mac 全体で共有される資源で、同時に使えるのは1つずつです。`screenLooksLike` を多用するスイートは実行時間が伸びます。
- 自己修復(ロケータの指紋照合)は FM を使わないので、Apple Intelligence とは無関係に CI で動きます。

## flaky シナリオの扱い(リトライ機構は意図的に無い)

CI 用のシナリオ単位リトライは実装していません。自動リトライは不安定さを隠して腐らせるためです。
代わりに次を使います。

- **検出**: `fleetest results flaky` が pass/fail 混在のシナリオを不安定度順に出します
  (`fleetest results insights` は回帰・アサーション以外の失敗・セレクタ陳腐化も検出します)。
- **ローカル再現**: `fleetest run --failed` が前回失敗したシナリオだけを再実行します。
- デバイス凍結などインフラ起因の失敗は、**run の内部で自動的に振り直されます**(結果を取り消し、
  別デバイスで再実行)。JUnit には最終結果だけが載ります。これはリトライではなく回復処理です。

### Link
- [index](../index_ja.md)
