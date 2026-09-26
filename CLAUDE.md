# fleetest mobile

## 読者の分岐(最初に判定する)

- **このツールを「使う」だけ**(自分のアプリのシナリオを書いて実行したい。ツール本体は改造しない):
  `/fleetest-setup` スキルに従ってセットアップする。手順の全体像は docs/user-docs/getting-started_ja.md。
  **以下の保守者向けルール(委譲方針・コメント規約・i18n・ソース分割等)は適用しない。**
- **このツール本体を「改造する」保守者**: 以下すべてが適用対象。

**この文書は規則だけを持つ。**「なぜその形なのか」「一度実際に壊した記録」は
**docs/maintainer-notes.md**(規則を緩めたくなったときに読む)。subsystem の設計・計測は
各 docs が正典。

## ドキュメント

### 利用者向け

- **利用者向けドキュメント(Shirates 流の en/ja 対)は docs/user-docs/**。入口は `index.md` /
  `index_ja.md`。1ページ = `<name>.md`(英)+ `<name>_ja.md`(日)で**片方だけ変えない**
  (`userDocsIntegrity.test.mjs` が対の欠落・切れたリンク・言語の混線・index 未掲載を検出)。
  DSL の挙動を変えたら docs/commands.md と併せて該当ページも直す
- 受け手向けの導入(事前準備・インストール・更新・アンインストールだけ): docs/user-docs/getting-started_ja.md
- DSL コマンドリファレンス(全コマンドの引数・挙動): docs/commands.md
- CI 連携(`fleetest run --junit` の JUnit 出力・GitHub Actions 例・flaky 方針): docs/ci.md
- リリース(git タグ発行。**受け手の配布口は main の1本**で版固定の導線は案内しない。
  `FLEETEST_REF` は保守者のブランチ検証口): docs/releasing.md(`Scripts/release.sh`)

### 設計・検証

- 設計書(アーキテクチャ・Swift DSL 仕様・セレクタ記法・プロファイル): docs/design.md
- **UI フレームワーク別の差異の索引**(揃えている / 揃っていない / 経路だけ違う、の3区分で横に並べる):
  docs/framework-differences.md。**フレームワークで挙動が割れる変更を入れたら表に1行足す**
- 検証の詳細(flake/性能の判定規律・ベータ整合・全滅時の切り分け・e2e.sh のオプション): docs/verification.md
- 性能チューニング(調整ノブ・不採用施策と再検討条件・計測手順): docs/performance-tuning.md
- Shirates(Classic)との対応表(何が揃っていて何を持たないか・意図的に持たないものの理由・
  OS で挙動が割れるもの・足す価値がある残り): docs/shirates-parity.md。
  **コマンドを足す/名前を変えるときは必ずここも更新する**
- 保守者向けの事故台帳(規則の由来): docs/maintainer-notes.md

### 失敗の記録と操作の規律

- **失敗の記録に置くのは事実だけ** —— フェーズ(`section`)・コマンド名(`command`)・
  経路(`failureKind`)・注記(`notes`)。**「環境要因の失敗」という分類は置かない**
  (アプリが重いのかマシンが混んでいるのかツールには区別できず、推測は誤った緑・赤を作る。
  ユーザー方針)。**言えないときは欄ごと省く**(「その他」に丸めない)。
  `command` を description から切り出さない・`failureKind` をエラー文言の一致で決めない
  (どちらも書式を変えた瞬間に静かに壊れる。仕分けは `DriverError` の case で行う)。
  渡し忘れは `CommandNamePlumbingTests` がソース走査で落とす
- **割り込みに吸われた操作は撃ち直さない**(届いていた場合に二重実行 = 送信・購入で取り返しが
  つかない)。ツールが閉じるのは**ステップ開始時点で出ている割り込み**まで。**間に湧いた分の
  復帰はシナリオ側**(docs/commands.md §割り込みが「操作を吸った」ときの扱い)。
  **自動リトライを再提案しない**

### fleetest 自身の E2E(SUT)

**UI フレームワークごとに SUT が5つ**ある(画面・`#id`・ラベルは全 SUT 共通契約):

| SUT | 実装 | プロジェクト | 対象 OS |
|---|---|---|---|
| `E2EAppCMP/` | Compose Multiplatform | TestProjects/E2E-CMP | ios + android |
| `E2EAppIOS/` | SwiftUI + 一部 UIKit | TestProjects/E2E-iOS | ios |
| `E2EAppAndroid/` | View/XML + 一部 Compose | TestProjects/E2E-Android | android |
| `E2EAppFlutter/` | Flutter | TestProjects/E2E-Flutter | ios + android |
| `E2EAppRN/` | React Native | TestProjects/E2E-RN | ios + android |


## 領域ごとの規律(`.claude/rules/`)

**領域に固有の規律は `.claude/rules/<領域>.md` にある**。その領域のファイルを **Read ツールで**読むと
自動で読み込まれる(サブエージェントにも届く。2026-09-26 に実地で確認)。**読み込まれないのは3つの場合** ——
grep やシェル(`cat`)で見るだけのとき・新しいファイルを読まずに書くとき・設計や方針を相談するとき。
**そのときは該当する規則ファイルを先に Read する**。

**リポジトリ直下の `AGENTS.md` は Codex など AGENTS.md を読むエージェント向けの入口**で、CLAUDE.md と
規則ファイルへ誘導するだけ(規則の本文は書かない。Claude Code は CLAUDE.md があると既定では読まない。
`claudeRulesIndex.test.mjs` が本文の写し込み・索引と規則ファイルの食い違い・当たらない `paths:` を落とす)。

**規則を足すときの置き場**: どの作業でも効く規則(検証の進め方・判断の規律・コメント規約・
「どこであれ新しいものを足すとき」の規律)だけをこのファイルに置き、特定の領域のファイルを触るときに
効く規律は該当する `.claude/rules/<領域>.md` へ足す(frontmatter の `paths:` がその領域のファイルを
指しているか確かめる)。**このファイルを肥大させない** —— 全セッションと全サブエージェントが毎回読む
(2026-09-26 の計測: 移す前は起動時の読み込みが約 85k トークン・移した後は約 43k)。

| 規則ファイル | 領域 |
|---|---|
| `.claude/rules/android.md` | Android(Play Protect・テキスト注入) |
| `.claude/rules/app-framework-scroll.md` | UI フレームワーク判定・容器推定・スクロールの端 |
| `.claude/rules/bridge-provision.md` | ブリッジ(版・ポート・供給) |
| `.claude/rules/device-health.md` | デバイスの健康状態(凍結) |
| `.claude/rules/dsl-commands.md` | DSL コマンド(索引・引数名・スクロール指定・操作の待ち) |
| `.claude/rules/e2e-sut.md` | fleetest 自身の E2E(SUT) |
| `.claude/rules/executor.md` | StepExecutor(実行時設定・失敗の文言・システムアラート) |
| `.claude/rules/fm-occlusion.md` | FM・テキストの視覚検証(occlusion-guard / OCR) |
| `.claude/rules/gesture.md` | ピンチ・座標ジェスチャ |
| `.claude/rules/installer-agents.md` | 受け手フローのスクリプト・エージェント連携・配布 |
| `.claude/rules/live-control.md` | ライブ操作 |
| `.claude/rules/mcp.md` | MCP サーバ(ft_*)と Bench |
| `.claude/rules/process-lifecycle.md` | プロセスの生存管理(終了猶予・Shell.run・台帳) |
| `.claude/rules/profile.md` | 実行プロファイルの --set |
| `.claude/rules/remote.md` | リモート(SSH ディスパッチ・監視の fan-out・ロックと待機列・占有) |
| `.claude/rules/results-retention.md` | 結果 JSON・run ボード・保持容量の掃除・LPT |
| `.claude/rules/selector-snapshot.md` | セレクタ・スナップショット・自己修復(指紋照合) |
| `.claude/rules/vision.md` | 画像(findImage / checkIsON / 画像分類) |
| `.claude/rules/vscode-i18n.md` | VSCode 拡張(ビルド・ソース分割・i18n) |
| `.claude/rules/webview-dom.md` | WebView / ブラウザの DOM |

**どこであれ新しいものを足すときの規律**(ファイルが決まらないので読み込まれない。詳細は各規則ファイル):
- 子プロセスを起こす経路を足す → 中断のリレー(`InterruptRelay`)・fleetest を起こすなら
  `ParentDeathWatch.childEnvironment()`・ssh 越しなら非対話 PATH の補正・`-tt` の ssh は
  `ParentBoundCommand` で包む(process-lifecycle.md / remote.md)
- 子プロセスのパイプを読む → `readDataToEndOfFile` を使わない・`availableData` のループは
  `autoreleasepool` で区切る・生死判定は `ProcessLiveness.isAlive`(process-lifecycle.md)
- FM を呼ぶ → `FMGate` を通す・オンデバイスだけ(fm-occlusion.md)
- MCP のツール・引数を足す → `ArgumentBounds` に載せる・ツールの集合を固定するテスト
  (`MCPToolCallTests` の driverBackedTools 等)を更新する・DSL と同じ判定は共有する(mcp.md)
- ブリッジの挙動・エンドポイントを変える → 版を上げる(iOS `bridgeProtocolVersion` / Android
  `VERSION_CODE`。`BridgeContractTests` が落ちたらそこで上げる)・XCUITest を触ったら `--ios-xcuitest`
  (bridge-provision.md)
- 実行時設定を足す → `ScenarioExecutionSettings` の1箇所(executor.md)
- DSL コマンドを足す・改名する → 索引 `CommandIndex`(`CommandIndexSyncTests`)・docs/commands.md と
  user-docs・docs/shirates-parity.md・`ft_batch` のキー・引数名は `waitSeconds:` 等の規律(dsl-commands.md)
- 受け手のフロー(install.sh・スキル)を変える → SKILL.md のステップ番号と 1:1(`installStepSync.test.mjs`)・
  受け手のファイルを書くのはステップ7.6 の入口だけ(installer-agents.md)
- iOS Simulator を起動する経路を足す → 起動の**前に** `SimulatorPosterCache.purge(udid:)`
  (`SimulatorPosterCachePurgeWiringTests`。docs/design.md §12.4.2)
- モニターの周期に計測を足す → 周期の中で待たない(裏で回して控えを読むだけ。`DeviceStorageSampler`)
  → maintainer-notes §55

## ビルド・検証

**検証の詳細な罠と判定規律(flake/性能の判定・macOS/Xcode ベータ整合・常駐プロセス掃除・
「Application is not running」全滅時の切り分け・`Scripts/e2e.sh` の各オプション)は docs/verification.md**。
以下は毎回効く最重要ゲートだけ。

### Swift

- **`swift test --parallel` だけでよい**(実測 127s → 34s)。**前に `swift build --build-tests` を
  打たない** —— `swift test` が同じビルドをやり直すので**無変更でも 12.3 秒を二重に払う**。
  **5 SUT のシナリオも `swift test` で型チェックされる**ので、DSL の改名・シグネチャ変更の
  追随漏れもこれで捕まる。別途ビルドが要るのは変異テストの直後に製品バイナリを作り直すときだけ
  (`swift build --product <名>`)
- **合否は exit code で見る**(パイプすると grep 等の exit code に化けて失敗を握りつぶす)
- **並列はテストプロセスを分けるので、ホストの共有資源に触るテストは自分で隔離する**
  → maintainer-notes §4.9。**隔離できないホストの実体**(simctl/adb・起動中の Simulator/Emulator・
  固定パス)と、`.fleetest/` の台帳・`DiagnosticReports` の走査は
  `Sources/FTTestSupport/SharedResource.swift` の `SharedResource.<key>.locked { }` で
  資源キーごとに直列化する(詳細は docs/verification.md)
- 実行ファイル差し替えは `swift build --product <名>`。`--target` はリンクせず旧バイナリを実行する

### デバイス実行(E2E)

- **`fleetest bridge down --all` を頻繁に打たない**。1回ごとに XCUITest ランナーの `xcodebuild` が
  全台ぶん走り、他セッションや監視が使う端末も巻き添えにする。**打たずに済む順序で組む**:
  **①ブリッジに触る編集を全部終えてから版を1回だけ上げる** / **②建て直しは使う端末だけ**
  (`bridge down --port <N>`)/ **③版ガードに弾かせる**(古いブリッジは明示的に落ちるので
  **弾かれたポートだけ**建て直す)/ **④建て直しの要らない段から検証する**(単体テスト →
  dry-run → 生きているブリッジ1台での MCP 確認 → 最後にデバイス実行)。
  **ワイヤ形式(DTO の enum・フィールド)を変えたら必ず版を上げる**
- **1シナリオの確認にフリート全台を用意しない**。`ProfileRunner` は回す本数から台数を絞る
  (`ResolvedProfile.deviceKeepCount` = 本数 + 予備1台)。実測で iOS の1本実行が 21.8s → 9.3s。
  **予備1台は必須**(用意した台が blank/frozen で弾かれると run ごと落ちる)。
  **例外は `--broadcast`** —— 各台で1回ずつ回すのが目的なので絞らない(分配だけ
  `ScenarioDispatch.broadcast` に差し替え、他は同じ経路)。`fleetest api run` は
  シナリオ一覧をビルドと並行に解決するので一覧を待てない —— 確定している `--scenario` の指定
  だけで判断する(`ApiRun.exactScenarioCount`)
- **E2E 実行中に `swift build` / `swift test` を打たない** → maintainer-notes §4.1。
  **E2E を投げたらビルドを伴う作業は止める**
- **モニターを止めるのは性能を測るときだけ**(ユーザー決定。合否を見るだけの実行では止めない)。
  **止めるのは `fleetest monitor pause [--for <分>]` / 再開は `resume`**(kill では止まらない ——
  拡張が数秒で再起動する。効くのはこの機械だけ。docs/verification.md §モニターと E2E)。
  拡張が動いていないときの旧手段は pkill 3連打(`fleetest api monitor` /
  `fleetest-androidstream` / `screenrecord --output-format=h264`)。
  **中途半端に止めた対照は誤った結論を出す**。
  **捨ててはいけない実測**: 8台すべてに配信を張った状態のフル E2E は Android が**実際に赤になった**
  (3/4 プロファイル失敗・接続断11件 → 完全停止で 4/4・接続断0)。遅くなるだけでなく**落ちる**。
  **赤が出たら真っ先に配信の有無を疑う**(判定材料: run.json の `workerAnomalies` に
  `degraded` / `requeued` が出ているか)
- **長時間ジョブ(E2E 等)の完了を「プロセスの生死」で待たない** → maintainer-notes §4.2。
  **ジョブ自身が出す成果物で待つ**:
  `nohup bash -c '<job> > log 2>&1; echo "exit=$?" > log.done' &` で起動し `log.done` を待つ。
  併せて**起動を報告する前にログの実在を確かめる**(「開始しました」は観測ではなく期待になりやすい)

### e2e.sh を回す条件

- **DSL コマンド・`StepExecutor`・ドライバ・ブリッジ(`InAppBridge`/`Runner`/`AndroidRunner`)・
  セレクタ/スナップショット/自己修復(指紋照合)/FM 呼び出し(`FTFoundationModels`)を変えたら `Scripts/e2e.sh`**
  (ユニットテストはデバイス境界のバグを1つも捕まえない)。**ブリッジのスナップショット/型写像と、
  StepExecutor の操作合成(タップ/ドラッグ/スクロール探索の終端処理)を触ったら SUT を絞らず全部**
  回す(フレームワーク差の退行は SUT を跨がないと出ない)→ maintainer-notes §4.4.1
- **既定の e2e.sh は iOS を in-app エンジンで回す**(**利用者の既定エンジンは hybrid = in-app 優先**
  なので、既定スイートが見るべきはそちら)。**フル E2E は引数なしの `Scripts/e2e.sh` だけ**
  (xcuitest は含めない)。**XCUITest ブリッジを触ったときだけ `--ios-xcuitest` を的を絞って回す**。
  エンジン指定(`--ios-inapp` / `--ios-xcuitest`)は **iOS だけを回す**(Android にエンジンの
  選択肢は無いので既定スイートと同一の実行を二度払うだけ)。OS の絞り込みは `--ios` / `--android`
- **この漏れは e2e.sh が検出する** —— **回さなかった側**のブリッジ入力集合(`BridgeSourceSet`)の
  digest を、そのエンジンの実行が**全部成功したときだけ** `.fleetest/<engine>-e2e-verified` へ
  記録し、開始時と終了時に食い違いを警告する(`fleetest api bridge-sources --bridge inapp|xcuitest --digest`)。**落とさず警告だけ**
  —— **xcuitest の警告は 2026-08-30〜09-14 のあいだ鳴りっぱなしだった**(既知の打鍵中抜け2本で
  E2E-RN が赤 → 全緑が条件の印が更新されなかった)。**v104 で中抜けを直した**(`TypeReadback.plan`
  の `.retype`。打ち直しは1回まで・ヒント欄では前方一致の説明を先に採る)。経緯は
  docs/verification.md の該当節
  → maintainer-notes §4.5

**e2e の実行範囲はリスクとコストで決める**(上のゲートは「最低限ここまでは回す」の下限で、
常に全部回す意味ではない。フルスイートは10分超かかるので、**何も足さない実行はしない**):

| 変更の性質 | 範囲 |
|---|---|
| 改名・シグネチャ変更・型に閉じたリファクタ | **`swift test --parallel` だけ**。追随漏れは必ずコンパイルエラーになる |
| ホスト側ロジック(`StepExecutor` の分岐・セレクタ解決) | `swift test` + **該当シナリオ1〜2本** |
| ブリッジの挙動(注入・スナップショット・型写像) | 該当 SUT の**1プロファイル**。フレームワーク差が絡むなら全 SUT |
| 入力・キー・IME 系 | 上記 + **`--ios-xcuitest`**(既定は in-app なので、もう片方のエンジン) |
| **幾何・容器推定・整定**(実ジェスチャの慣性で挙動が変わるもの) | 上記 + **`--ios-xcuitest`**。**in-app は慣性を持たない**ので、この種の退行は既定スイートでは原理的に出ない(maintainer-notes §4.5.1) |
| flake 調査・性能 | 該当プロファイルを**反復10周**(docs/verification.md) |
| run 制御(再キュー・ワーカー離脱など。シナリオ実行の中身を触らない) | `swift test` + **その経路を強制的に通す陽性対照**。緑の run では1度も実行されないのでフルは情報ゼロ |
| リリース前・大きな統合の締め | **フルスイート = `Scripts/e2e.sh`(引数なし)だけ** |

**回す前に「それで何が検証できるか」を言えること**。判定はひとつ ——
**その変更は緑の run で1度でも実行されるか**。実行されないなら、フルは 10 分を捨てるだけで、
代わりに要るのは**経路を強制的に通す陽性対照**。

### 判定の規律

- **受け手が受け取る経路も一度は通す** —— **コードの正しさと、それが受け手へ届くことは別に
  確かめる** → maintainer-notes §4.6
- **flake の修正は1回グリーンで判定しない・単発の観測で性能を断じない**(反復+負荷で叩く。
  手順は docs/verification.md)
- **「読む回数を減らす」最適化は、その読みが担っている砦を先に列挙する**。**節約できるのは
  誰も見ていない読みだけ** → maintainer-notes §4.7。**読みを新しくする最適化も同じ** —— 待ちが担っていた
  「次の読みも追いついている」を消す(Android の迂回はキャッシュを更新しない。`nextResolveBypassesCache`)→ §38
- **単体テストが緑でも実データで1回動かすまで信用しない**(テストは書いた本人の前提を共有するので、
  前提が誤っていると実装とテストが同じ誤りを持ったまま緑になる。実害3件は docs/verification.md)
- **定数を置くときは根拠・単位・尽きたときの発話を書く**(ユーザー方針「根拠のない定数は排除したい」)。
  書けないなら数字を調整するのではなく**数字への依存を消す**(観測可能な事象を待つ・デバイスの
  応答が要らない情報源から導く)。**片方の文脈で詰めた値を別の文脈へ流用しない** —— 読み手の
  予算・シミュレータの実測・pt で測った床は、読み手のいない経路・実機・px の木では
  **遅くなるのではなく黙って誤る**(実例と直し方は docs/verification.md)。残す数字は名前を付けて
  1箇所に置く。**既定値はリテラルで固定するテストを置く** —— 他のテストが差し替え口で値を
  明示していると production の既定を1度も通らず、既定を戻す変更が緑のまま通る
  (`FMLockTests.testDefaultConcurrencyIsPinned`)。**既定を変える変更は、その既定に依存している
  テストを1件ずつ見る** —— 落ちずに「素通り」して検証をやめる型がある
- **共有資源の枠(並列度)は「平均利用率」で決めない** —— 需要がバーストなら利用率が容量の半分でも
  待ち行列はできる。**待ちそのものを測る**(FM なら結果 JSON の `fm.gateWait*`)。さらに
  **掃引だけで決めない**: スループットの膝と実 run の最適は一致しない ——
  判断軸は**「待ち + 実働」の和**で、片方だけ見ると必ず誤る(実測は
  docs/performance-tuning.md §3.5)
- **陽性対照は pass/fail でなく出力の文言まで読む** → maintainer-notes §4.14
- **回復の操作(建て直し・再起動)は、効いたかを直後に測る**。効かなければ同じ操作を繰り返さず、
  測った事実を 1 行言う(`RunnerRestartFutility`。XCUITest ランナーの建て直しが緑のたびに約 10 秒ずつ
  空振りしていた)。**遅さ・失敗の帰属は、それを分ける測定をしたときだけ書く** —— 検知の入力から
  導けない帰属を文言に入れない(遅いレーンの警告と供給時プローブが同じ台に正反対の帰属を出した)
  → maintainer-notes §29
- **失敗の帰属は「HEAD での対照」で決める**(`git stash push -u` → HEAD で1シナリオ →
  `git stash pop`。3〜4分。docs/verification.md)
- **「差が出ない」ときは仮説より先に実験系を疑う**。**陽性対照を先に通す**(マーカーを書くだけの版で
  差し替えが効くことを確認してから本番)。判定に使うシナリオは **`clearAppData()` から始める**
  → maintainer-notes §4.8
- **不具合を直したら「同じ型が他に無いか」を機械的に掃討する**(grep で同じ呼び出し形・同じ定数・
  同じ既定実装依存を列挙してから潰す)。同じ型はほぼ必ず複数ある(→ maintainer-notes §4.6.1)。**再現しない同型でも、
  失敗モードが沈黙(誤った成功)なら塞ぐ価値がある**(その場合は「再現していない」と明記する)。
  可能なら**同型の再発を落とすテスト**まで足す(`SwipeForScrollForwardingTests` = ソース走査 /
  `BridgeRouterStatusContractTests` = 本数固定 / `AppDriverDefaultDispatchTests` = 宣言の突き合わせ)
- **`AppDriver` に既定実装を足すときはプロトコル要件にも宣言する**。存在型越しの呼び出しは
  要件でなければ**静的ディスパッチで既定実装に落ち**、ドライバ側の実装が呼ばれないまま黙って
  既定値が返る(ビルドもテストも通る。`snapshot(bypassingCache:)` で実際に踏んだ)。`AppDriverDefaultDispatchTests` が検出する

### 検知を足すとき

- **新しい検知(警告・lint・修正提案)は「既存資産の全数に当てて誤検知0」まで確認する**。
  dry-run はデバイス不要なので全数が安い(レシピと実例は docs/verification.md)。
  **ただしスナップショットの検知(遮蔽・積み重なり・ghost)は自前 SUT では代表できない**
  (木が要るので dry-run では当てられない)。**「出ない」ことを設計の根拠にするなら、
  コーパスとデバイス実行の両方で確かめる**
  → maintainer-notes §4.10
- **実アプリのスナップショットは `Tests/Fixtures/RealAppSnapshots/` に固定してあり、
  `SweepHarnessTests` が `swift test` で毎回当てる**(件数の基準値+タップ対象に対する警告率の上限)。
  **基準値を上げるのは増えた分を1件ずつ見て真陽性だと確かめてから** —— 黙って上げるとこの砦は
  現状の追認装置になる。採り直しは `FT_SWEEP_BASELINE=1`
- **凍結・a11y 異常など「意図的に起こせない事象」の検知には注入口を用意する**
  (`FrozenInjection` / `FT_FAKE_FROZEN_KEYS`)。**陰性(誤検知0)の確認は「常に false を返す
  検出器」と区別できない** → maintainer-notes §4.11。注入は**観測と公表の経路だけ**を通し、
  回復・除外のような**デバイスを触る動作は撃たない**(`FrozenVerdict.isInjectedOnly`)
- **「観測」と「配信(表示の最適化)」を同じループに書かない**。抑制は配信段だけに効かせ、
  観測は cadence を落として続ける(`ApiMonitorCommand.capturePlan` = 純粋関数)
- **新しい検知はまず警告から**入れる

### テストを足すとき

- **新しいテストは「破ったら落ちる」ことを1回確かめる**。変異は **`Scripts/mutation-check.sh` で
  git worktree 並列**(本線のツリーには書かないので復元忘れが起きない)。手で1件だけやるときは
  壊して実行→復元(**復元に `git checkout <file>` を使わない** = 未コミットの変更ごと消える)
- **検知の類は両方向に掛ける**(出さなくする変異 / 常に出す変異)—— 片方だけだと
  「常に空を返す」変異を「空を期待するテスト」に当てて素通しする
- **テストが production の関数を通っているかも見る**(→ maintainer-notes §4.13)。検出できない変異が出たらテストを境界へ
  寄せる(要素数を増やす・既定値でなく限界値で呼ぶ)
- **テストが production の代わりに正規化・整形していないか** → maintainer-notes §4.13.1
- **変異が生き残ったら、まずテストの置き場所とフィルタを疑う** → maintainer-notes §4.12。
  **「殺せた」も exit code で数えない** —— 変異がコンパイルエラーでも exit 1 になる。狙ったテスト名の失敗行で取る

### 版と契約の同期(片方だけ変えない)

- `fleetest api` の JSON/NDJSON 契約を後方非互換に変えたら `Sources/FTCore/ProtocolVersion.swift` と
  `vscode-fleetest/src/protocolVersion.ts` の版を +1(両者一致必須・`protocolVersion.test.mjs` が
  検出。拡張は起動時に照合し不一致を警告)。**後方互換の読み替えは置かない**
  (ユーザー方針 2026-09-20)—— 欄を足すときも `decodeIfPresent ?? 既定値` で古い形を吸わず、
  **必須にして版を +1** する。リモートは `Scripts/align.sh` で毎回全機を同じコミットへ揃える運用で、
  版がずれた状態は存在しない(ずれていれば適合チェックが止める)。互換を入れると、その経路は
  テストでしか踏まれずに腐り、**沈黙する縮退**(decode 失敗で機械1台ぶんの行が消える等)を作る
- **`fleetest run` と `fleetest api run` はオプションも配線も別々に持つ2実装**。片方だけに足した
  変更はどちらの経路も緑のまま通る(実行されるのは足したほうだけ)。**意図した差分は
  `RunCommandFlagParityTests` が等号で固定する** —— 片側にフラグを足すと落ちるので、
  「両方に足す」か「片側だけでよい理由を表へ書く」かを必ず選ぶ。**フラグの集合だけでなく
  「併用不可・必須」の検査規則も両方に揃える** —— フラグ名が同じでも検査が片方に無いと、
  同じ打鍵が片方で通り片方で落ちる(実際にそうなっていた: `--profile` + `--port` が `run` では
  黙って無視され `api run` ではエラーだった)

### 判定は1箇所に置く


- **判定は MCP と DSL で共有する**。「手前かどうか」は `FTCore.PaintOrder`、「撃つと別の物に
  当たるか」は `FTCore.TapTargetGeometry`(合成チェーンは `occlusionAdvisory`)と
  `FTCore.OcclusionGeometry`(中心を覆う最前面の名指し。`OcclusionSuspicion.covering` とは
  判定軸が別 = 面積比 vs 中心点。統合しない理由は両型の doc)、「絵が古いか」は
  `FTCore.StaleFrameDetector`、焦点待ちの定数は `FTCore.FocusWait` の1箇所だけに置き、
  `RefGuard`/MCP は転送する。別々に持つと**同じ画面で MCP と DSL の判断が食い違う**
  (実例は maintainer-notes §5)。移設したときは**掃討ゲート(`SweepHarnessTests`)が
  実アプリのコーパスで等価性を検証する**
- **前面にあると観測しただけの相手へ、画面を動かす操作を撃たない**。セッションの向け直しは
  `AppDriver.attach`(前面確認だけ・非破壊)で、**activate は使わない** —— Spotlight のような
  SpringBoard の拡張を activate すると**ホーム画面が描画を失って真っ黒になり**、自アプリなら
  in-app の既定実装から launch = 注入付きの再起動へ落ちる(実測 2026-09-22 → maintainer-notes §40)。
  `attach` の既定実装は activate へ倒さず 501 を投げる(向け直せないことより画面を壊すほうが害が大きい)
- **FM の失敗トリアージ(分類・要約・修正案)は置かない**(ユーザー決定 2026-09-15)。照合相手の無い自由文で、
  実レポート 30 件のうち要約 13 件が事実を誤り(数の向き・引用・帰属)、分類は環境の問題を `appBug` にし
  (ブリッジ不達 5/6・a11y 無効 3/3)、修正案は別要素への差し替えを勧めた。「環境の問題」と「アプリの不具合」を
  分けること自体、ツールには判定できない(失敗の記録に分類を置かないのと同じ理由)。起きたことはレポートに
  事実として並ぶ(失敗文言・要素一覧・スクリーンショット)。`FMTriageRemovedTests` が Sources への再混入を落とす。
  **戻すなら §21 の測り方で誤りの率を測ってから** → maintainer-notes §21
- **FM によるロケータ自己修復(FM ヒール)とヒールキャッシュは置かない**(ユーザー決定 2026-09-15)。採用門
  (自己申告 confidence == "high")が実測で1度も開かず(日英 272 件で high 0 件・E2E の witness は全 run で却下)、
  confidence は正誤と相関しない(正解に low・誤答に medium/high)ので門の置き場が無い。典型的なドリフト(id だけ
  変わりラベル不変)は指紋照合が決定的に拾う。**`heal` は指紋照合だけのスイッチで、FM を使わないので FM の
  トグルと独立**(ユーザー決定)。`FMHealRemovedTests` が Sources への再混入を落とす。
  **戻すなら §21 の測り方で誤りの率を測ってから** → maintainer-notes §22
- **共有するのは「判定」であって「文言」ではない**。正しい形は**①判定・順序・当たり判定を
  FTCore に1つ ②文言は呼び手ごとに持つ**。**呼び手は中核を呼んで写すだけ**にする。中核は `TapTargetGeometry.advisoryKind` /
  `FTCore.SimilarLabels` / `FTCore.BackEffect` / `FTCore.SnapshotTruncation.remedy` /
  `TapTargetGeometry.offscreenScrollGateCentre`。**天井まで来ていたら「上げろ」と言わない**。
  **FM に訊いて答えが無かったステップは `visibility-guard-skipped`** を立てる。
  **判定に文言を埋め込んだら、呼び手が増えた日に他人の対処文が出る** ——
  `BridgeIdentityCheck.verdict` は「レーンの port が奪われた・worker を建て直せ」という
  **run 向けの対処文を detail に持っていた**ため、ライブ操作に共有した瞬間に
  「lane / worker」の無い文脈でその文が出た(2026-09-22 のレビュー)。**対処文は `remedy` として
  呼び手が渡す**(既定値を置かない = 新しい呼び手の渡し忘れをコンパイルで止める。run の4経路が
  共有する文は `BridgeIdentityCheck.runLaneRemedy` の1箇所)。**detail が要らない呼び手には
  `matches(expected:status:)`** を使わせる(文言を作らないので remedy も要らない)

### 個別の規律

- **PCC(Private Cloud Compute)は完全に禁止**(ユーザー決定 2026-09-07)。FM で使ってよいのは
  **オンデバイスの `SystemLanguageModel` だけ** —— `PrivateCloudComputeLanguageModel` を使うと
  アプリの画面情報が Mac の外へ出る。受け手向けドキュメント(docs/user-docs/overview/
  environments・about の en/ja)が「画面情報は Mac の外に出ない」と**断定している**ので、
  これは表現ではなく不変条件。**利用者向けのトグルも置かない**(選べる形にしない)。
  **守っているのは型ではなく `LanguageModelSession` の init の既定値** —— `model:` を省くと
  `SystemLanguageModel = .default` に束縛されるが、**汎用 init(`model: some LanguageModel`)には
  既定値が無い**ので `model:` を1つ書くだけでクラウドへ出られる。門は
  `PrivateCloudComputeProhibitionTests` のソース走査(①PCC の型名を名指ししない
  ②セッションに `model:` を明示的に渡さない ③走査が Sources に届いていることの確認)。
  **PCC のインスタンスは型名を書かずに得られない**ので①だけで経路は閉じ、②は二重の備え。
  経緯と SDK の実地調査は docs/design.md §1.1 末尾

## 受け手フローの設計方針(スキル・スクリプト・CLI の分担)


## 実装の委譲

- 原則、実装タスクは Sonnet サブエージェントに委譲する(メインセッションは計画・プロンプト設計・レビュー・検証を担当)
- ユーザーの指示があればそちらを優先する
- 小さな修正や、レビュー中に見つけた直しなど、直接編集した方が良いと判断できる場合は委譲せず直接編集してよい

## 並列一括作業(サブエージェント委譲)

- 全域一括の機械的変更は、ファイル集合が互いに素になるようバッチ分割して並列委譲する(コメント量・行数で均等化)
- サブエージェントに swift build / npm build を実行させない(SPM ビルドロック・出力の競合)。ビルド・テストはメインで全バッチ完了後に一括実行。軽量な per-file チェック(node --check 等)は各エージェントで可
- 「コメントのみ」「移動のみ」を謳う変更は、diff の全変更行を機械検証(全 +/- 行がコメント/空行か、末尾コメント編集はコード部分が同一か)してからコミットする
- TestProjects/ 配下のシナリオ(.swift)はユーザー資産(一部は explore 生成)。リポジトリ全域の一括整形・コメント編集の対象に含めない

## ソース分割の方針

保守者は Claude Code。目安: 1ファイル約2,000行以下(一度の Read で収まる)、1タスクで編集するのは1〜2ファイルに収まる構成を保つ。超えたら分割を検討する(人間向け可読性は目的ではない)。


## 国際化(i18n・日英切替)

拡張の UI 文字列は日英切替対応(設定 `fleetest.language`: auto/ja/en、auto は VSCode 表示言語に追従。モニター「設定」タブからも変更可)。UI 文字列を追加/変更するとき:

- **CLI(`fleetest`)の表示文字列は英語だけ**(ユーザー決定 2026-07-30。切替機構は入れない)。
  コメント・docs・SKILL.md・拡張 UI は日本語のまま。**`Sources/` の文字列リテラル**は
  `CLIEnglishStringsScanTests` が走査し、日本語を正しく持つファイルだけを理由付きの表で通す
  (ステップ説明の日英生成・日本語入力の照合表・FM の `@Guide`・生成物・受け手の Package.swift へ
  書くマーカー)。**中黒 `・` を日本語と数えない**(英語の出力でも箇条書きに使う)
  → maintainer-notes §44.3

## コメント規約

コメントの読者は人間ではなく Claude Code。目的は「編集時の事故を防ぐ」「再調査を不要にする」の2つだけ。それに寄与しないコメントはトークンの無駄なので書かない・見つけたら消す。

残す(最小の行数に圧縮して):
- コードから導出できない制約・不変条件・順序依存(例:「acquireVsCodeApi は1回しか呼べない」「stdin EOF が終了指示」)
- ファイル間・言語間で同期が必要な契約(postMessage のメッセージ型、NDJSON プロトコル、ブリッジ HTTP API)と、同期相手のファイルへのポインタ
- 一見単純化・削除できそうに見えるが、すると壊れる箇所の理由(1-2行)
- 数値・チューニング値の意味(単位・上限・根拠)

書かない・削除する:
- 識別子・型・import から分かる「何をするか」の説明
- 設計経緯・履歴(移動元、旧仕様との比較、日付・指示・要件タグ)
- UI・見た目の意図の散文(結果は CSS/コードにある)
- 同じ内容の重複(契約はどちらか1箇所に置き、他方は参照)
- 長い設計解説の散文(要点だけ箇条書きに圧縮)

迷ったら: 契約・制約・罠は残す、説明・散文は削る。

**用語**: 「実機」は**物理端末(本物の iPhone / Android)だけ**を指す。仮想デバイスは
**「仮想デバイス」「デバイス」「Simulator」「Emulator」**と書く(「実デバイス」も使わない ——
実機と紛らわしい)。デバイス上での実行一般は「デバイス実行」「デバイス上」でよい。
**「デバイスで動かした」と書きたくなった瞬間に、何の上で動かしたかを確認する**
→ maintainer-notes §7

**用語(モニターのペイン)**: 「デバイスモニター」タブは上から**ラインビュー**(タイルの並び)・
**グリッドビュー**(選択した台の拡大表示)・**実行ログビュー**(選択した台の実行ログ)の
**常設の3ペイン**(ユーザー決定 2026-09-17、3ペイン化は 2026-09-21。**契約は
docs/design.md §12.6 が唯一の定義元**)。**両ビューに出るのはラインビューで選択した台だけ**で、
**全体レーン(`__overall__`)だけは選択に関わらず実行ログビューに残す**(供給の進行の受け皿)。
**ちょうど1台選択のときだけ**グリッドビューの中に「拡大表示 | 実行ログの複製」を並べ、その間は
実行ログビューを自動で畳む。ペインを「フリート」と呼ばない —— **「フリート」は複数機械・
`run --fleet` の製品概念**に取っておく。見出しの文言は中身を表す(「デバイス一覧」「選択したデバイス」「実行ログ」)

**用語(陽性/陰性)**: **「陽性/陰性」は検知の語彙**(発火したかどうか)で、**判定の結果(緑/赤)には
使わない**。occlusion-guard だけが「発火すると赤になる検知」なので、同じ事象を検知として語るか
判定として語るかで極性が反転し、`偽陽性` の一語が両側に跨っていた。使う語は5つ ——
**真陽性**(検知が正しく発火)/ **誤検知**(検知が誤って発火)/ **見逃し**(発火すべきなのにしなかった。
幾何の原理的限界は「取りこぼし」)/ **誤った緑・誤った赤**(判定そのものの誤り)/
**誤反転**(occlusion-guard が可視な要素を反転)。**`偽陽性`・`偽陰性` は書かない**
(`VocabularyPolarityTests` がソース走査で落とす)。**陽性対照**は1語の固有名詞として残す
(単独の「陽性」は書かない)。**例外は置かない** —— occlusion guard の利用者向けの名前は
**「テキストの視覚検証」**(英語 "text visual verification")、キーは **`fmTextOcclusionCheck` /
`ocrTextOcclusionCheck`**(ユーザー決定 2026-09-15。拡張のチェックボックス・キー・CLI フラグ
`--no-fm-text-occlusion-check`・docs・コメントとも。OCR 段は「OCR を使ったテキストの視覚検証」)。**走査は受け手向けの面(docs/user-docs/・拡張の i18n 文字列)も含む** ——
どちらも対の英語があるので、直すときは ja/en を同時に直す。**対象外は TestProjects/(ユーザー資産)と
reports/(.gitignore 済み。Apple へ提出済みの資料)だけ** → maintainer-notes §11
