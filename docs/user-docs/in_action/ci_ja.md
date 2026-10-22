# CI で回す

[in English](ci.md)

シナリオは LLM なしの決定的実行なので CI に向いています(exit code と JUnit XML の両方で
機械的に処理できます)。このページは、テストプロジェクトを CI で回せるようになるまでの手順です。
Jenkins を例にしていますが、手順 1〜3 は他の CI でも同じです。

## 1. CI マシンを用意する

- **サポートするのは self-hosted の Mac だけ**(Jenkins 常駐機・AWS EC2 Mac インスタンス等)。
  iOS Simulator / Android Emulator には macOS が必須のため、GitHub ホストランナー
  (`macos-*`)はサポート外です(実体が macOS VM のため Apple Intelligence が使えず、
  この経路の動作検証もしていません)。
- **ログイン済みの GUI セッションのユーザーで実行してください**(Simulator 実行の一般則です)。
  ヘッドレスの `LaunchDaemon` や ssh 直のセッションでは Simulator が不安定になります。
- Xcode(Android を回すなら Android SDK も)がランナーに導入済みであること。
- **`scripts/compose.yaml` を持つプロジェクトを回すなら**([サービス宣言](../reference/writing/services_ja.md)):
  CI 機に Apple Container か Docker が要ります。自分でビルドしたイメージは CI 機でビルドするか `fleetest services load <tar>` で載せてください
  (取得は起きません)。レジストリのイメージは初回に取得するので外へのネットワークが要ります。
  Docker の API を TCP(2375 / 2376)で公開していると run が始まりません。
- **Apple Intelligence は不要です。** 無くても決定的実行と自己修復は動きます(違いは末尾の「知っておくこと」)。

成功するとこう見える: CI のジョブと同じユーザーのターミナル(ログイン済みの GUI セッション)で `xcodebuild -version` が版を表示します。

## 2. fleetest を入れる

CI では拡張・MCP は不要です。次のコマンドは冪等で、2回目以降はほぼ skip します。

```bash
bash foundation-tester/Scripts/install.sh --work-dir "$PWD" --skip-extension --skip-mcp --no-doctor
```

成功するとこう見える: 各手順が1行ずつ出て、2回目以降は大半が skip になります。

## 3. ジョブに実行コマンドを書く

```bash
# 実行: --quiet でステップ行を抑制、--junit で JUnit XML を書く
fleetest run --profile ios-run --quiet --junit reports/junit.xml
```

- **exit code**: `0` = 全シナリオ成功 / `1` = 失敗あり(JUnit は失敗時も書かれます)。
  シナリオが1本も始まる前に落ちた run でも JUnit は書かれます。デバイスの準備で落ちたときは各シナリオが失敗として載り、
  シナリオのビルドで落ちたときは `build` という名前の失敗が1件だけ載ります。コマンドラインの誤り(存在しないシナリオ名・
  フォルダ名)では JUnit は書かれません。
- デバイスの供給(Simulator 起動・ブリッジ)は `--profile` 実行が自動で行います。連続ジョブでは
  稼働中のブリッジが再利用され、コールドスタートは初回だけです。
- **失敗の調査**: `TestProjects/<name>/reports/` に失敗ごとの Markdown レポート(要素一覧・
  スクリーンショット・自己修復の提案)が出ます。ビルド成果物として保存しておくと、JUnit の
  `report:` 行から辿れます。

成功するとこう見える: 全シナリオが通ればコマンドは exit code `0` で終わり、`reports/junit.xml` ができています。
1本でも落ちれば exit code `1` ですが、`reports/junit.xml` は書かれています。

## 4. JUnit を読ませる

`<testsuite>` がシナリオクラス、`<testcase>` がシナリオに対応します。失敗には
最初の失敗ステップの要約・全失敗ステップとソース位置・Markdown レポートのパス・実行した
worker が入ります。**inconclusive**(`verify` のアサーション0個)は、シナリオの**全ステップ**
が inconclusive のときだけ `<skipped>` になり、通常のステップと混在する場合は passed の
`<testcase>` に埋もれます(実行ログと Markdown レポートの ❓ と修正提案で気付けます)。

### AIへの指示文

ジョブの定義(Jenkinsfile など)は AI に書かせられます。

```text
このリポジトリに Jenkinsfile を作って。ステージは「install.sh で fleetest を冪等に導入」→「fleetest run --profile ios-run --quiet --junit reports/junit.xml」。post で junit を集計し、失敗時は reports/junit.xml と TestProjects/*/reports/ を成果物に残して。
```

<details>
<summary><b>手動で書く場合(クリックで詳細表示)</b></summary>

Jenkins の例です。

```groovy
pipeline {
  agent { label 'mac' }   // ログイン済み GUI セッションのユーザーで動くエージェント
  stages {
    stage('Install / update') {
      steps { sh 'bash ../foundation-tester/Scripts/install.sh --work-dir "$PWD" --skip-extension --skip-mcp --no-doctor' }
    }
    stage('Run scenarios') {
      steps { sh '../foundation-tester/.build/debug/fleetest run --profile ios-run --quiet --junit reports/junit.xml' }
    }
  }
  post {
    always  { junit 'reports/junit.xml' }
    failure { archiveArtifacts artifacts: 'reports/junit.xml, TestProjects/*/reports/**', allowEmptyArchive: true }
  }
}
```

</details>
<br>

成功するとこう見える: ジョブの結果ページにシナリオクラスごとのテスト結果が並びます。失敗したジョブでは、
`reports/junit.xml` とレポートがビルド成果物に残り、JUnit の `report:` 行からレポートを開けます。

## 5. 定期実行にして、ジョブの間を掃除する

ジョブを定期的に起動するようにします(Jenkins なら `triggers { cron('H 2 * * *') }`。毎回回す分と夜に回す分の分け方は
[スモークと回帰を分けて回す](../tutorial/smoke_and_regression_ja.md))。連続して回すときは、次の3点を決めておきます。

- **1台の Mac で同時に走る実行は1本です。** 同じエージェントで2本目の `fleetest run` は開始せず、
  `another fleetest run is already running on this Mac` で止まります。同じエージェントを使う
  ジョブが重ならないようにするか、失敗させずに順番待ちさせる `--wait-lock <秒>` を付けてください
  ([並列実行](../reference/running/parallel_execution_ja.md)参照)。
- run はブリッジを止めません。ブリッジは最後のリクエストから一定時間(`FT_BRIDGE_TTL`。既定 2 時間)
  通信が無いと自動で終了し、終了したブリッジの作業ファイルは次のジョブの開始時に削除されます。
  iOS のブリッジの作業ファイルは**動いている間ずっと増えます**(操作中は 1 本あたり毎時 120〜240MB 程度)。
  夜間などジョブが 2 時間以上空く運用なら掃除は不要です。**24 時間ジョブが途切れない運用では**、
  定期的に `fleetest devices down` を実行してください。
- ジョブ間で環境を掃除したい場合は、ジョブ末尾に `fleetest devices down`(全ブリッジ停止 +
  Simulator/Emulator 全終了)を置きます。プロファイル無しの `devices down` は、登録簿にある全ランナー機にも同じ掃討を投げます。
  CI 機にランナーの登録があると他のマシンの Simulator まで止めるので、`--profile` を付けるか、登録簿を持たないでください。同じ Mac で別のテスト実行がデバイスを使っている間は、
  実行中のテストを止めないよう何も停止せずに終了コード 1 で終わります。同じ Mac でジョブが
  重なりうる場合は、他のジョブが動いていない時間帯に掃除を置いてください。

### AIへの指示文

```text
Jenkinsfile に毎晩 2 時の定期実行を足して。fleetest run には --wait-lock 1800 を付け、ジョブの末尾で fleetest devices down --profile ios-run を実行して。
```

成功するとこう見える: 重なったジョブは、`--wait-lock` を付けていれば順番に実行され、付けていなければ上の文言で止まります。

## 知っておくこと

### Apple Intelligence を CI で使う(任意)

Apple Intelligence が無い CI では、変わることが2つあります。**`screenLooksLike` は判定されずに通ります**。
**テキストの可視性検証は OCR だけで判定します**([テキストの可視性検証](../reference/testclass/text_visibility_check_ja.md))。
起動時に `⚠️` が1行出ます。画面照合を CI でも効かせたい場合は、次を見てください。

Apple Intelligence は、ランナーの実体が物理 Mac(ベアメタル)のときだけ使えます。macOS の VM
(Tart・Anka など)では有効化できないため、使えない前提で組んでください。

- 物理 Mac(Jenkins 常駐機など): 使えます。
- AWS EC2 Mac(ベアメタル): 原理的には使えるはずですが、未検証です。
- macOS の VM: 使えません。`screenLooksLike` は判定されずに通り、テキストの可視性検証は OCR だけで判定します。

ベアメタルで有効にするときの条件です。

- Apple silicon で macOS 27 以上(`screenLooksLike` とテキストの可視性検証は画像を FM に渡すので、macOS 26 では使えません)。
- 有効化は GUI で1回行います(システム設定 → Siri で Siri をオン(Siri が Apple Intelligence を使います)。画面の無いマシンは画面共有経由。
  モデルのダウンロードが走ります)。EC2 Mac は素の AMI から作り直すと設定が消えるので、有効化したあとにカスタム AMI を作るか、
  プロビジョニングに有効化を含めてください。
- ジョブの先頭で `fleetest doctor --fm-only` を実行し、終了コードで確かめてください。設定画面の表示が「使える」でも
  実際には呼べないことがあるため、doctor は実際に推論して確かめます。
- FM はその Mac 全体で共有される資源で、同時に使えるのは1つずつです。`screenLooksLike` を多用するスイートは実行時間が伸びます。
- 自己修復(ロケータの指紋照合)は FM を使わないので、Apple Intelligence とは無関係に CI で動きます。
- 自己修復が働くと、直ったセレクタはチェックアウトしたシナリオのソースへ書き戻されます(ツールはコミットしません)。
  チェックアウトを汚したくないときは `--set heal=false` を付けるか、そのまま無視してください。

### flaky シナリオの扱い(リトライ機構は意図的に無い)

CI 用のシナリオ単位リトライは実装していません。自動リトライは不安定さを隠して腐らせるためです。
代わりに次を使います。

- **検出**: `fleetest results flaky` が pass/fail 混在のシナリオを不安定度順に出します
  (`fleetest results insights` は回帰・アサーション以外の失敗・セレクタ陳腐化も検出します)。
- **ローカル再現**: `fleetest run --failed` が前回失敗したシナリオだけを再実行します。
- デバイス凍結などインフラ起因の失敗は、**run の内部で自動的に振り直されます**(結果を取り消し、
  再実行)。JUnit には最終結果だけが載ります。これはリトライではなく回復処理です。
- **振り直しはシナリオを最初から実行し直します**(同じデバイスのことも、別のデバイスのこともあります)。
  デバイスの表示が止まっていたと確定したときは、そのデバイスで直前に**成功した**シナリオも、結果を捨てて実行し直します
  (止まった画面で判定していたため)。送信・購入・登録のような取り消せない操作を含むシナリオは、
  1回の run の中で2回実行されることがあります。振り直しを止める設定はありません。
  **シナリオは丸ごと再実行される前提で作ってください**([壊れにくいシナリオの書き方](../reference/writing/writing_robust_scenarios_ja.md))。
  取り消せない操作は、2回実行されても困らない環境(テスト用の決済・ステージングのサーバー)に向けてください。

見つけたら[壊れにくいシナリオの書き方](../reference/writing/writing_robust_scenarios_ja.md)に沿って直し、同じシナリオを数回続けて回して確かめます。

### Link
- [index](../index_ja.md)
