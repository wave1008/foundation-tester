# CI で回す(JUnit 出力と GitHub Actions の例)

シナリオは LLM なしの決定的実行なので CI に向く(exit code と JUnit XML で結果を機械処理できる)。
このドキュメントは**受け手パッケージを CI で回す**ための最小構成。

## 前提

- **macOS ランナーが必要**(iOS シミュレータ / Android エミュレータが要るため)。
  実運用の主想定は self-hosted の Mac(Jenkins 常駐機・AWS EC2 Mac インスタンス等)。
  シミュレータだけなら GitHub ホストの macOS ランナーでも動く。
  いずれも**ログイン済みの GUI セッションのユーザーで実行する**(シミュレータ実行の一般則。
  LaunchDaemon や ssh 直のヘッドレス実行はシミュレータが不安定になる)
- **Apple Intelligence は不要**。CI に無くても heal・screenIs・偽陽性検証が自動スキップされるだけで、
  決定的実行(タップ・検証)は全機能動く(`ftester run` が起動時に ⚠️ を1行出す)。
  **ただし `screenIs`・`requireVisible` を使うシナリオは、FM 無しでは検証されずに素通り(pass)になる**
  (run 末尾の FM 警告が申告する)。画面照合を CI でも効かせる場合は
  下の「Apple Intelligence を CI で使う」
- Xcode・(Android を回すなら)Android SDK がランナーに導入済みであること。
  状態判定は `Scripts/preflight.sh`(読み取りのみ)

## 実行と結果の取り出し

```bash
# 導入(冪等。2回目以降はほぼ skip)。CI では拡張・MCP は不要
bash foundation-tester/Scripts/install.sh --work-dir "$PWD" --skip-extension --skip-mcp --no-doctor

# 実行: --quiet でステップ行を抑制、--junit で JUnit XML を書く
ftester run --profile ios-xcuitest --quiet --junit reports/junit.xml
```

- **exit code**: 0 = 全シナリオ成功 / 1 = 失敗あり(JUnit は**失敗時も書かれる**)
- **JUnit XML**: `<testsuite>` = シナリオクラス、`<testcase>` = シナリオ。
  失敗には最初の失敗ステップの要約(message)・全失敗ステップとソース位置・
  Markdown レポートのパス・実行 worker が入る
- **失敗の調査**: `Projects/<name>/reports/` に Markdown レポート(失敗時の要素一覧・
  スクリーンショット・FM トリアージ)が出る。**artifact に上げておく**と JUnit の
  `report:` 行から辿れる

## GitHub Actions の例(self-hosted macOS)

```yaml
jobs:
  e2e:
    runs-on: [self-hosted, macOS]
    steps:
      - uses: actions/checkout@v4            # 受け手パッケージ(Projects/ を含む)
      - name: Install / update foundation-tester
        run: |
          bash ../foundation-tester/Scripts/install.sh \
            --work-dir "$PWD" --skip-extension --skip-mcp --no-doctor
      - name: Run scenarios
        run: |
          ../foundation-tester/.build/debug/ftester run \
            --profile ios-xcuitest --quiet --junit reports/junit.xml
      - name: Publish test report
        uses: mikepenz/action-junit-report@v4    # 任意の JUnit 取り込みアクションで可
        if: always()
        with:
          report_paths: reports/junit.xml
      - name: Upload failure evidence
        uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: ftester-reports
          path: |
            reports/junit.xml
            Projects/*/reports/
```

- デバイスの供給(シミュレータ起動・ブリッジ)は `--profile` 実行が自動で行う。
  連続ジョブでは稼働中ブリッジが再利用される(コールドスタートは初回だけ数分)
- ジョブ間で環境を掃除したいときは `ftester devices down`(全ブリッジ停止 + シミュレータ/
  エミュレータ全終了)をジョブ末尾に置く

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
    failure { archiveArtifacts artifacts: 'reports/junit.xml, Projects/*/reports/**', allowEmptyArchive: true }
  }
}
```

## Apple Intelligence を CI で使う(任意)

self-hosted の Mac(Jenkins 常駐機・AWS EC2 Mac = 実 Apple silicon)なら Apple Intelligence を
有効化でき、screenIs・偽陽性検証・heal・失敗時トリアージが CI でも動く。条件と罠:

- Apple silicon + macOS 26+。**screenIs・偽陽性検証(画像入力)は macOS 27+**
- **システム言語が日本語だと Apple Intelligence 自体が出現しない**(macOS 27 beta 実測)。
  CI 機のシステム言語は英語にする
- 有効化は GUI で1回(システム設定 → Apple Intelligence と Siri。ヘッドレス機は画面共有経由。
  モデルのダウンロードが走る)。**EC2 Mac は素の AMI から再作成すると設定が消える**ので、
  有効化後にカスタム AMI を焼くか、プロビジョニングに有効化を含める
- **確認はジョブ先頭に `ftester doctor --fm-only`(exit code)**。availability フラグは
  「使える」と嘘をつくことがあるため、doctor は実呼び出しで確認する
- FM はホスト全体で直列化される(約1回/秒)。screenIs を多用するスイートは壁時計が伸びる
- heal を CI で有効にするかはチーム方針: 有効なら UI 変更起因の失敗は減るが、セレクタ陳腐化が
  隠れやすい。延命中のシナリオは `ftester results insights` が検出する

## flaky の扱い(リトライ機構は意図的に無い)

CI 用のシナリオ単位リトライは**実装していない**。自動リトライは flake を隠して腐らせるため。
代わりに:

- **検出**: `ftester results flaky` が pass/fail 混在のシナリオを不安定度順に出す
  (`ftester results insights` は回帰・インフラ起因失敗・セレクタ陳腐化も検出)
- **ローカル再現**: `ftester run --failed` が前回失敗したシナリオだけを再実行する
- デバイス凍結など**インフラ起因の失敗は run 内で自動で振り直される**(結果取り消し+
  別デバイスで再実行。JUnit には最終結果だけが載る)。ここはリトライではなく回復処理

## 関連

- 検証の詳細な罠(flake 判定の規律・ベータ整合): [docs/verification.md](verification.md)
- 結果 DB の分析コマンド: `ftester results --help` / [docs/commands.md](commands.md)
- 導入・更新の詳細: [docs/getting-started.md](getting-started.md)
