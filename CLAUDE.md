# foundation-tester

## 読者の分岐(最初に判定する)

- **このツールを「使う」だけ**(自分のアプリのシナリオを書いて実行したい。ツール本体は改造しない):
  `/ftester-setup` スキルに従ってセットアップする。手順の全体像は docs/getting-started.md。
  **以下の保守者向けルール(委譲方針・コメント規約・i18n・ソース分割等)は適用しない。**
- **このツール本体を「改造する」保守者**: 以下すべてが適用対象。

## ドキュメント

- 受け手向けの導入(事前準備・インストール・更新・アンインストールだけ。使い方は README とスキル): docs/getting-started.md
- 受け手の状態判定: `Scripts/preflight.sh`(引数なし・読み取りのみ。カレントを見て
  ready=0 / installed=2 / blocked=1 を返す。SKILL.md ステップ0・0.5 と 1:1)
- 受け手の一括導入: `Scripts/install.sh`(clone〜検証ゲートを冪等に実行)。**各手順は
  `.claude/skills/ftester-setup/SKILL.md` のステップ番号と 1:1**(失敗時に「→ SKILL.md ステップ N」を
  出してエージェントを手作業手順へ戻す設計)。**片方だけ変えない** — 手順の追加・番号の変更は両方に入れる
  (`installStepSync.test.mjs` が「install.sh が指すステップが SKILL.md に実在するか」を検出)。
  **スキルからは curl 形で呼ぶ**(クローン側の Scripts/ は pull されるまで古く、新しい引数は
  「不明なオプション」で落ちる)。全出力は `<WORK_DIR>/.ftester/install-<日時>.log` に残る。
  **pull 後は自分自身を再 exec する**(2026-08-06 追加)。**bash は実行中にファイルが差し替わっても
  古い内容を最後まで実行する**(git は rename で置換するので開いた fd は旧 inode を指し続ける。
  実験で確認)。この再 exec が無いと、update.sh 経由で入った**新しいステップはその回に1つも
  実行されず**、次回は update.sh が up-to-date で即終了するので**永久に実行されない**
  (実害: ステップ7.6 の CLAUDE.md 生成が版だけ上がって一度も走らなかった)。
  条件は「実行中のファイル = pull したクローンの `Scripts/install.sh` 自身」かつ HEAD が動いたときだけ。
  **`update.sh` にも同じ再 exec がある**(2026-08-06。install.sh から戻った時点で HEAD が動いていたら
  やり直す)。一度は「委譲が中心だから影響は小さい」と残したが、**直後に利用者向けの修正
  (project sync を外部構成でも走らせる)が update.sh 側へ入り、受け手が2回更新しないと
  直らない状態を作った**。2周目は `FT_UPDATE_REEXEC` で up-to-date の早期終了を通さない
  (直前に pull しているので必ず up-to-date になり、素通しだと project sync とプラグイン更新が飛ぶ)。
  **画面は各ステップ1行(逐次)+ 集計だけ・生ログはファイルへ**(`--verbose` で従来。54KB 出すと
  エージェント側で切られ、結果を探す grep が承認を増やす)。**逐次表示は人のためのもの** ——
  数分の無音は「止まった」と誤解され中断される。最後の再掲は warn/fail だけ(全行だと表が2つ並ぶ)。**外部構成ではクローンのローカル変更を自動破棄**
  (reset --hard + `clean -fd`。`-x` は付けない = .build/ を消さない。`--keep-local` で従来)。
  **WORK_DIR の `CLAUDE.md` にマーカー付きで入口を4行置く**(ステップ7.6。`.mcp.json` も
  `settings.json` も「設定として効く」だけでエージェントが読む物ではないため、これが無いと
  導入の翌週にスキルの description しか手掛かりが無くなる)。**使い方の解説は書かない** ——
  ツール説明と二重管理になり必ずズレる。受け手の資産なのでマーカーの内側だけ差し替え、
  嫌う受け手には `--skip-claude-md`。
  **ここは受け手のファイルを書き換える唯一の箇所**なので、**マーカーが begin/end ちょうど1組で
  なければ1バイトも書かない**(片方だけ・2組以上・逆順は `damaged` で warn 止まり)。
  素朴に「最初の begin 〜 最初の end」を置換すると、end だけ壊れた CLAUDE.md で
  **1回目に2つ目のブロックを追記 → 2回目に間に挟まれた利用者の記述ごと削除**する
  (2026-08-06 に実際に消して確認)。`installClaudeMdBlock.test.mjs` が
  install.sh から python を抜き出して実行し、この3形を守る。
  **クローンが git 管理しているファイルには書かない**(2026-08-07 に自己破壊を実再現)——
  clone 構成では受け手の CLAUDE.md はクローン自身の追跡ファイルで、書くとツリーが dirty になり
  **2回目以降の更新が pull ガードで必ず止まる**。`git reset --hard` で戻しても次の更新が
  同じブロックを書くので堂々巡りになる。判定はレイアウトではなく
  **`git ls-files --error-unmatch` で追跡の有無**。同型は packageLockSync(npm install が
  lock を書き換える)。**受け手のフローに「クローンの中を書く」工程を足すときは必ず追跡を見る**
  **毎回 `ftester api ensure-settings` で Bash 許可リストを補修する**(init 経由だけだと
  `--skip-project` の更新で既存の受け手に永久に届かない)
- MCP サーバの起動口: `Scripts/mcp-server.sh`(`.mcp.json` はこれを exec するだけ)。
  **シェル式を `.mcp.json` へ直書きしない** —— 起動のたびに no-op でも約8秒の `swift build` を払い、
  失敗すると `>/dev/null` で**理由が分からないまま起動しない**(2026-08-06 の外部フィードバック)。
  ランチャが守るのは3つ: **鮮度でだけ建てる**(`find Sources Package.swift -newer <bin>`。
  存在チェックに戻さない = InAppLauncher と同じ規律。建てた直後に `touch` するのは、
  無変更のソースを触っただけだと再リンクされず毎回建て直しになるため)/
  **stdout は JSON-RPC 専用**(診断は stderr・ビルド出力はログファイル)/
  **cwd を変えない**(cwd は受け手パッケージの特定に使う。ビルドはサブシェルで行う)
- 受け手の更新: `Scripts/update.sh`(install.sh を再実行 + project sync + プラグイン更新と版照合。
  `.claude/skills/ftester-update/SKILL.md` と 1:1)。**先に update-check.sh を呼び up-to-date なら
  即終了**(全工程は更新が無くても約30秒。入れ直しは `--force`)。**ログの場所は最後の
  「次にやること」にも出す**(install.sh には `--no-next-steps` を渡すため、こちらで案内しないと
  人が後から詳細を確認できない)。doctor は既定で出さない
  (`--doctor`。結果表と情報が重複し8秒かかる)。**スキルのステップ0は `.ftester/state.json` の
  Read で TOOL_ROOT を採る**(コマンドを打たない = 承認が要らない。無ければ preflight に落ちる)
- 更新の有無だけ判定: `Scripts/update-check.sh`(読み取りのみ。**fetch せず `git ls-remote`** で
  upstream と比較し up-to-date=0 / update-available=3 / pinned=0 / unknown=1。取り込みはしない)。
  VSCode 拡張が起動時に1日1回呼ぶ(`src/updateCheck.ts`・設定 `ftester.updateCheck`)。
  **手動コマンド `ftester.checkForUpdate` は間隔・却下・設定 off を無視して必ず結果を返す**
  (自動は更新があるときだけ喋る。明示操作で黙るのは誤動作に見えるため。両者の差はここだけ)。
  **更新の実行口はモニターの「設定」タブ1箇所**(`src/monitorUpdateController.ts`。判定も取り込みも
  スクリプトに委譲し、拡張は結果を出すだけ)。通知は手順を書かず「設定タブを開く」で誘導する。
  **実行ログは webview に持たせず OUTPUT へ**(検索・コピーが標準UIで済み、パネルを閉じても残る)。
  進行は状態行/ボタンのスピナー + `withProgress`(見出し行 `==>` だけ report する)。
  **webview で `window.confirm` は効かない** — 破壊的操作の確認はホスト側の
  `showWarningMessage({modal:true})`(プロファイル削除と同じ方式)。
  **`reason=` は ja/en どちらでも英語**(拡張の通知に素通しするため。枠だけ訳す)。
  **TOOL_ROOT の解決規則は preflight.sh / update.sh / `src/toolRootResolve.ts` と同じ**(4箇所。片方だけ変えない。
  `toolRootContract.test.mjs` が規則の3語(クローン判別マーカー・既定の隣・Package.swift の宣言)の欠落を検出)
- DSL コマンドリファレンス(全コマンドの引数・挙動。利用者向け): docs/commands.md。
  **機械可読な索引は `Sources/FTDSL/CommandIndex.swift`**(`ftester api dsl-commands` が出す。
  読者はコードを生成する側で、名前の存在確認に使う)。**コマンドを足す/消す/改名したら索引も直す**
  (`CommandIndexSyncTests` が Commands.swift / ValueAssertions.swift / FTElement と突き合わせる)。
  **置いていない名前は `Sources/FTDSL/UnavailableCommands.swift` で受け止める**(他ツールの名前・
  対称性から実在すると誤解される別名。`cannot find in scope` の代わりに正しい書き方を出す)
- Shirates(Classic)との対応表(何が揃っていて何を持たないか・意図的に持たないものの理由・
  OS で挙動が割れるもの・足す価値がある残り): docs/shirates-parity.md。
  **コマンドを足す/名前を変えるときは必ずここも更新する**(準拠漏れの一覧を含む)
- CI 連携(`ftester run --junit` の JUnit 出力・GitHub Actions 例・flaky 方針): docs/ci.md
- リリース(git タグ発行と版ピンの関係。配布はソースビルド前提): docs/releasing.md(`Scripts/release.sh`)
- 設計書(アーキテクチャ・Swift DSL 仕様・セレクタ記法・プロファイル): docs/design.md
- 性能チューニング(調整ノブ・不採用施策と再検討条件・計測手順): docs/performance-tuning.md
- 検証の詳細(flake/性能の判定規律・ベータ整合・全滅時の切り分け・e2e.sh のオプション): docs/verification.md
- ftester 自身の E2E: **UI フレームワークごとに SUT が5つ**ある(画面・`#id`・ラベルは全 SUT 共通契約):

  | SUT | 実装 | プロジェクト | 対象 OS |
  |---|---|---|---|
  | `E2EAppCMP/` | Compose Multiplatform | TestProjects/E2E-CMP | ios + android |
  | `E2EAppIOS/` | SwiftUI + 一部 UIKit | TestProjects/E2E-iOS | ios |
  | `E2EAppAndroid/` | View/XML + 一部 Compose | TestProjects/E2E-Android | android |
  | `E2EAppFlutter/` | Flutter | TestProjects/E2E-Flutter | ios + android |
  | `E2EAppRN/` | React Native | TestProjects/E2E-RN | ios + android |

  **要素の testTag/`#id`/ラベルの唯一の正は `E2EAppCMP/docs/ui-contract.md`**(全 SUT とシナリオがこれを参照。
  片方だけ変えない。`uiContractSync.test.mjs` が「SUT 側の `#id` が母体に実在するか」を検出)。
  **型語彙・OS/フレームワーク固有の罠だけ**は各 SUT の `<SUT>/docs/ui-contract.md` に置く
  (同じ `#id` でも型は SUT ごとに違う。例: ボタンは CMP/Android で `Cell`、View/XML なら `Button`)。
  **5 SUT のシナリオはほぼ同内容だが共通化しない**(2026-07-29 ユーザー決定・可読性優先。
  RN 追加後も同じ)。DSL 変更のたび5箇所を編集することになるが、共通化すると
  SUT 固有の差(型語彙・フレームワーク固有の罠)が表現しにくくなる。**共通化を再提案しない**
- **ディープリンクの URL スキームは SUT ごとに固有**(`fte2ecmp`/`fte2eios`/`fte2eandroid`/
  `fte2eflutter`/`fte2ern`。契約は `E2EAppCMP/docs/ui-contract.md` §ディープリンク)。
  iOS は同一スキームを複数アプリが登録していても解決先を1つしか選ばず、E2E のシミュレータには
  iOS の SUT が4つ同居するため共有スキームでは配送先が端末ごとに揺れる(実測で別アプリへ
  配送された)。`Tests/FTesterTests/DeepLinkSchemeSyncTests.swift` が契約表との一致と
  SUT 間の重複を検出する

## ビルド・検証

**検証の詳細な罠と判定規律(flake/性能の判定・macOS/Xcode ベータ整合・常駐プロセス掃除・
「Application is not running」全滅時の切り分け・`Scripts/e2e.sh` の各オプション)は docs/verification.md**。
以下は毎回効く最重要ゲートだけ。

- 拡張: `cd vscode-ftester && npm run compile`(esbuild+tsc)/ `npm test`。挙動を変えたら
  **`npm version --no-git-tag-version <新版>` で版を上げて** `npm run install-local`
  (反映は VSCode の Reload Window **+パネル開き直し**。Reload だけでは効かないことがある。code CLI は PATH に無い)。
  **package.json だけ手で書き換えない** — lock も version を内包しており、放置すると受け手の
  `npm install` が lock を書き換えてクローンが dirty になり、**次の更新が pull ガードで止まる**
  (実害。`packageLockSync.test.mjs` が検出。既にズレたら `npm install --package-lock-only`)
- Swift: `swift build --build-tests` / **`swift test --parallel`**(実測 127s → 34s。直列も緑のままだが、
  毎回の待ちが4倍違う)。**合否は exit code で見る**(パイプすると grep 等の exit code に化けて失敗を握りつぶす実害)。
  **並列はテストプロセスを分けるので、ホストの共有資源に触るテストは自分で隔離する** ——
  既定のパスを直接見に行くと、無関係なテストの後始末と競合して落ちる(2026-08-10 に `FMBreaker` で実際に発生。
  状態ファイルがホスト単位なのは仕様なので、**テスト側が差し替え口でプロセスごとの一時パスへ逃がす**。
  「どこに置くか」は I/O 抜きで別に表明する)。同型は `.ftester/` の台帳・`DiagnosticReports` の走査・simctl/adb
  を呼ぶテスト。**隔離できないホストの実体**(simctl/adb・起動中の Simulator/Emulator・固定パス)は
  `Sources/FTTestSupport/SharedResource.swift` の `SharedResource.<key>.locked { }` で資源キーごとに
  直列化する(隔離が使えないときの下位の手段。詳細は docs/verification.md)
- **長時間ジョブ(E2E 等)の完了を「プロセスの生死」で待たない**(2026-08-09 の実害)。
  `pgrep -f <文字列>` は自分自身こそ除外するが、**同じ文字列を含む他のシェルは拾う** ——
  待機コマンド自身のコマンドラインにその文字列が載るので、待機を2つ以上同時に走らせると
  **互いを「まだ実行中」と見て全員が止まらない**。実際 E2E の待機が3つ残り、次のスイートが
  1本も起動しないまま「実行中」と表示され続けた(実験で機構を確認済み)。
  **ジョブ自身が出す成果物で待つ**:
  `nohup bash -c '<job> > log 2>&1; echo "exit=$?" > log.done' &` で起動し `log.done` を待つ。
  併せて **起動を報告する前にログの実在を確かめる** —— 「開始しました」は観測ではなく期待になりやすい
- 実行ファイル差し替えは `swift build --product <名>`。`--target` はリンクせず旧バイナリを実行する(事故実績)
- **DSL コマンド・`StepExecutor`・ドライバ・ブリッジ(`InAppBridge`/`Runner`/`AndroidRunner`)・
  セレクタ/スナップショット/ヒール(`FTAgent`)を変えたら `Scripts/e2e.sh`**(ユニットテストはデバイス
  境界のバグを1つも捕まえない)。**ブリッジのスナップショット/型写像と、StepExecutor の
  操作合成(タップ/ドラッグ/スクロール探索の終端処理)を触ったら SUT を絞らず全部**回す
  (フレームワーク差の退行は SUT を跨がないと出ない。実害: 探索終端の空打ちドラッグは CMP では
  無害・SwiftUI ではタブバーが反応し、E2E-iOS を回すまで 5/5 の回帰に気付けなかった)。
  **入力・キー・IME 系を触ったら `--ios-inapp` も回す**(既定の e2e.sh は iOS を xcuitest でしか
  回さないが、**利用者の既定エンジンは hybrid = in-app 優先**。実害: pressEnter のバグ2件が
  既定スイートでは最後まで表面化しなかった)。詳細は docs/verification.md。
  **この漏れは e2e.sh が検出する**(2026-08-10)—— in-app ブリッジの入力集合
  (`BridgeSourceSet.inApp`)の digest を、`--ios-inapp` が**全部成功したときだけ**
  `.ftester/inapp-e2e-verified` に記録し、既定スイートの開始時と終了時に食い違いを警告する
  (`ftester api bridge-sources --set inapp --digest`。一覧は BridgeSourceSet が唯一の定義元)。
  **落とさず警告だけ**(検知は警告から始める)。実害: in-app/xcuitest 両方のスナップショット生成を
  変えた回の E2E 254 本が全部 engine=xcuitest で、in-app 側は1度も動かないまま緑になった
- **e2e の実行範囲はリスクとコストで決める**(上のゲートは「最低限ここまでは回す」の下限で、
  常に全部回す意味ではない。フルスイートは10分超かかるので、**何も足さない実行はしない**):

  | 変更の性質 | 範囲 |
  |---|---|
  | 改名・シグネチャ変更・型に閉じたリファクタ | **ビルド+`swift test` だけ**。追随漏れは必ずコンパイルエラーになる(4 SUT のシナリオも Package のターゲットなので型チェックされる) |
  | ホスト側ロジック(`StepExecutor` の分岐・セレクタ解決) | `swift test` + **該当シナリオ1〜2本** |
  | ブリッジの挙動(注入・スナップショット・型写像) | 該当 SUT の**1プロファイル**。フレームワーク差が絡むなら全 SUT(上のゲート) |
  | 入力・キー・IME 系 | 上記 + **`--ios-inapp`** |
  | flake 調査・性能 | 該当プロファイルを**反復10周**(docs/verification.md) |
  | run 制御(再キュー・ワーカー離脱など。シナリオ実行の中身を触らない) | `swift test` + **その経路を強制的に通す陽性対照**。緑の run では1度も実行されないのでフルは情報ゼロ |
  | リリース前・大きな統合の締め | フルスイート(既定 + `--ios-inapp`) |

  **回す前に「それで何が検証できるか」を言えること**(2026-08-06 指示。惰性で回して指摘された)。
  判定はひとつ —— **その変更は緑の run で1度でも実行されるか**。実行されないなら、
  フルは 10 分を捨てるだけで、代わりに要るのは**経路を強制的に通す陽性対照**。

- **受け手が受け取る経路も一度は通す**(2026-08-07 の実害)。9コミット積んだ後で
  `Scripts/update.sh` を実際に走らせたら、**2回目以降の更新が必ず失敗する**欠陥が出た。
  3ラウンドの実アプリ監査でも単体テストでも1度も出ていない ——
  **コードの正しさと、それが受け手へ届くことは別に確かめる**
- **flake の修正は1回グリーンで判定しない・単発の観測で性能を断じない**(反復+負荷で叩く。実害と
  手順は docs/verification.md)
- **単体テストが緑でも実データで1回動かすまで信用しない**。テストは書いた本人の前提を共有するので、
  前提が誤っていると実装とテストが同じ誤りを持ったまま緑になる(実害3件は docs/verification.md)
- **「差が出ない」ときは仮説より先に実験系を疑う**。差が出ないことは、**変更が無効だったこと**と
  **実験が無効だったこと**を区別しない。実行の実体は `ftester` ではなく
  **`ftester-scenarios-<project>` サブプロセス**なので、A/B で `ftester` を差し替えても
  base と fix が同一コードを走る(2026-08-03 に性能の A/B と修正案2件を取り違えた)。
  **陽性対照を先に通す**(マーカーを書くだけの版で差し替えが効くことを確認してから本番)。
  判定に使うシナリオは **`clearAppData()` から始める** —— E2E アプリは状態を launch を跨いで
  永続し、前の run の残留を読むと壊れていても通る。詳細は docs/verification.md
  §「切り分けは『実験系が効いているか』を先に確かめる」
- **不具合を直したら「同じ型が他に無いか」を機械的に掃討する**(grep で同じ呼び出し形・同じ定数・
  同じ既定実装依存を列挙してから潰す)。同じ型はほぼ必ず複数ある —— 2026-07-31 の1セッションで
  4回掃討して4回とも見つかった(Android の読み前 `refresh()` 漏れが3経路目にも / `forScroll` を
  落とすラッパー群 / ランナーの 409 多重定義 / 整定の打ち切りを黙る3層)。
  **再現しない同型でも、失敗モードが沈黙(誤った成功)なら塞ぐ価値がある**(その場合は
  「再現していない」と明記する)。可能なら**同型の再発を落とすテスト**まで足す
  (`SwipeForScrollForwardingTests` = ソース走査 / `BridgeRouterStatusContractTests` = 本数固定 /
  `AppDriverDefaultDispatchTests` = 宣言の突き合わせ)
- **`AppDriver` に既定実装を足すときはプロトコル要件にも宣言する**。存在型越しの呼び出しは
  要件でなければ**静的ディスパッチで既定実装に落ち**、ドライバ側の実装が呼ばれないまま
  黙って既定値が返る(ビルドもテストも通る)。2026-08-01 に `snapshot(bypassingCache:)` で実際に踏んだ。
  `AppDriverDefaultDispatchTests` が検出する
- **新しい検知(警告・lint・修正提案)は「既存資産の全数に当てて誤検知0」まで確認する**。
  単体テストは想定した形しか試さないので緑のまま通る。dry-run はデバイス不要なので全数が安い
  (レシピと実例は docs/verification.md。実際に誤検知2件と**実バグ1件**が出た)。
  **ただしスナップショットの検知(遮蔽・積み重なり・ghost)は自前 SUT では代表できない** ——
  木が要るので dry-run では当てられず、しかも 4 SUT 掃討が誤検知0でも**実アプリで出る**
  (2026-08-06 に5形、2026-08-07 に3形。どちらも自前 SUT は0件)。
  **実アプリのスナップショットは `Tests/Fixtures/RealAppSnapshots/` に固定してあり、
  `SweepHarnessTests` が `swift test` で毎回当てる**(件数の基準値+タップ対象に対する
  警告率の上限)。**基準値を上げるのは増えた分を1件ずつ見て真陽性だと確かめてから** ——
  黙って上げるとこの砦は現状の追認装置になる。採り直しは `FT_SWEEP_BASELINE=1`
  (貼り付け用の1行と、何が発火したかの明細が出る)
- **新しいテストは「破ったら落ちる」ことを1回確かめる**(production を1行壊して実行→復元。
  **復元に `git checkout <file>` を使わない** = 未コミットの変更ごと消える。実害あり)。
  この確認だけで無力なテストが4件見つかった実績がある。
  **検知の類は両方向に掛ける**(出さなくする変異 / 常に出す変異)—— 片方だけだと
  「常に空を返す」変異を「空を期待するテスト」に当てて素通しする(2026-08-07 に2回)。
  **テストが production の関数を通っているかも見る** —— 掃討ハーネスが `!e.enabled` を
  自前で書いていたため、`RefGuard.disabledWarning` を壊しても落ちなかった。検出できない変異が出たらテストを境界へ
  寄せる(要素数を増やす・既定値でなく限界値で呼ぶ)。詳細は docs/verification.md
- **LPT の実績 run 数の既定値は3箇所(`LPTOrdering.defaultHistoryRuns` / `package.json` の
  `ftester.lptHistoryRuns.default` / `monitorPanel.ts` が webview へ送る default)で一致必須**
  (`lptDefaultSync.test.mjs` が検出。設定タブは default を初期値として入力欄に入れ、空欄・不正値の
  ときもそこへ戻すので、ズレると表示された件数と実際に走る件数が食い違う)
- `ftester api` の JSON/NDJSON 契約を後方非互換に変えたら `Sources/FTCore/ProtocolVersion.swift` と `vscode-ftester/src/protocolVersion.ts` の版を +1(両者一致必須・`protocolVersion.test.mjs` が検出。拡張は起動時に照合し不一致を警告)
- **ブリッジの挙動・エンドポイントを変えたら版を上げる**(上げないと**稼働中の旧ブリッジが再利用され、変更が反映されないまま緑になる**。実害2回)。iOS = `Sources/FTCore/BridgeDTO.swift` の `bridgeProtocolVersion`(in-app dylib と XCUITest ランナーの共通定数)/ Android = `AndroidRunner/build.sh` の `VERSION_CODE` と `AndroidBridge.swift` の `expectedBridgeVersionCode` を**同時に**(`AndroidBridgeVersionSyncTests` が定数間の不一致と、**コミット済み `prebuilt/ftbridge.apk` が
  定数と別版のまま=APK 作り直し忘れ**を検出)。**実装ソースを変えたら `BridgeContractTests` が落ちる**
  ので、そこで版を上げてから期待値を貼り替える(貼り付け用のリテラルは失敗メッセージが出す)。
  検出は2段: ルート表(エンドポイントの増減)+ ソース指紋(**ルートが同じでハンドラだけ変えた場合も
  落ちる**)。**版を上げること自体は強制できない**ので最後は人間の規律。
  **ブリッジの入力ファイル一覧は `Sources/FTCore/BridgeSourceSet.swift` が唯一の定義元**
  (`InAppLauncher` の dylib 再ビルド判定も同じ一覧を使う。片方だけ変えない)。
  指紋の性質(コメント編集でも落ちる理由)・保留中の代替案は docs/verification.md
- **判定は MCP と DSL で共有する**(2026-08-07)。「手前かどうか」は `FTCore.PaintOrder`、
  「撃つと別の物に当たるか」は `FTCore.TapTargetGeometry` の1箇所だけに置き、
  `RefGuard` は転送する。別々に持つと**同じ画面で MCP と DSL の判断が食い違う**。
  移設したときは**掃討ゲート(`SweepHarnessTests`)が実アプリのコーパスで等価性を検証する**
- **MCP(`ft_*`)は DSL と別経路なので、鮮度・防御を DSL 側に入れただけでは届かない**。
  `StepExecutor` が持つ知見(キャッシュを捨てた snapshot・ghost の掴み直し・整定)を足したら、
  **MCP にも同じものが要るかを必ず見る**(2026-08-06 に3件まとめて踏んだ: スクロール後の古い木・
  容器外 ghost への座標タップ・pressEnter の焦点待ち。いずれも DSL 側では対処済みだった)。
  **ただし同じ判定をそのまま強い挙動へ流用しない** —— DSL の「掴み直して送り直す」合図を
  MCP で**タップ拒否**に格上げしたら、実アプリで誤検知が5形出て警告へ後退した
  (docs/design.md の ghost の節)。**新しい検知はまず警告から**入れる。
  探索ロジックは**MCP に2つ目の実装を書かず `StepExecutor` へ委ねる**(`ft_scroll_to`)
- **エラーの status はホストの分岐契約**(表は docs/design.md §「エラーの status」)。
  とくに **XCUITest ランナーの 409 は `requireApp()` の1箇所だけ** — ホストはこの経路の 409 を
  無条件に「セッション消失」と読んで activate を撃つ。「セッションはあるが今は無理」は **422**
  を使う(`BridgeRouterStatusContractTests` が 409/503/501 の本数を数えて守る)。
  in-app ブリッジは逆に 409 を一時的競合へ広く使ってよい(あちらは包まれない)
- **Android のテキスト注入(`InputInjector`)を触ったら負荷10周で判定する**
  (`for i in $(seq 10); do Scripts/e2e.sh --cmp --android; done`)。**単独実行では出ない**
  flake がある(高負荷でだけ約40%)。守る規律 —「`ACTION_SET_TEXT` の `true` は受理であって
  反映ではない(必ず読み返す)」「`combined` は最初の読みから1回だけ作る(パスワード欄の読みは
  マスクされており、作り直すと伏せ字を書き込む・二重追記する)」「フォーカスが立つまで撃たない」
  「追跡は座標でなく resource-id」「**読む前に `refresh()` する**(a11y ノードはキャッシュ供給で、
  とくに WebView は DOM 変更を数秒遅れて出す。取り直さないと**入っているのに古い値を読み続けて**
  期限切れで 500 になる)」 — と不採用案(`ACTION_FOCUS`・ホスト側のキーボード回避)は
  docs/design.md §Android のテキスト注入の規律

## 受け手フローの設計方針(スキル・スクリプト・CLI の分担)

- **機械作業はスクリプト/CLI に寄せ、スキルには判断だけ残す**。エージェントに JSON を書かせる・
  値を集めさせると、実行のたびに結果が揺れる(machines と runs の名前不一致・指示していない
  プラットフォームの生成・二度聞き)。決まった手順は `Scripts/*.sh` か `ftester` のサブコマンドにする
- **承認回数はコストとして数える**。値の収集は preflight の出力に寄せ、デバイス選定は
  `profile setup --auto-device`、繰り返す実行は `.claude/settings.json` の許可(ftester 由来の
  コマンドのみ。`api ensure-settings` が毎回補修)で吸収する。**出力済みの情報を別コマンドで
  取り直さない**。承認は3方向から増えるので全部潰す:
  **①聞かなくてよい確認**(答えが決まっているならスクリプトが決める。例: 外部構成のクローンの
  ローカル変更 = 受け手の資産ではないので自動破棄)/ **②許可リストに無いコマンド**(スクリプトを
  足したら許可も足す)/ **③巨大な出力**(切られてエージェントが grep を打つ。生ログはファイルへ)
- **人に聞くのは AskUserQuestion(ダイアログ)だけ**。チャットに質問文を書くと見落とされてフローが止まる
- **生成したシナリオの検証は3段**(`.claude/skills/ftester-scenario/SKILL.md` ステップ4→4.5→5):
  コンパイル → **dry-run(デバイス不要・数秒)** → デバイス実行。真ん中を飛ばすと「コンパイルは通るが
  何も検証していない」をデバイス実行の時間で見つけることになる。**誤りは早い段の言葉で返す**のが方針
  (未知の名前 = コンパイラのメッセージ / 構文・アサーション不足・**撮った画面に無い `#id`** = dry-run /
  実挙動の確認 = デバイス実行)。**`#id` の実在照合は `ft_snapshot` が貯める台帳**が供給源
  (`SelectorInventory`。撮っていない画面については黙る = 誤検知を出さない側に倒す。docs/design.md)
- **デバイス(実機・シミュレータ/エミュレータ)が要る判断は純粋ロジックへ切り出して単体テストで固める**
  (例: `DevicePicker`・`ProfileWriter`・`ToolchainFingerprint`)。デバイス上でしか出ない部分だけを E2E に残す

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

- コントローラ分割は、必要なコールバックだけを束ねた狭い deps インターフェースをコンストラクタ注入し、サブコントローラ同士は直接参照しない(実例: monitorPanel.ts の MonitorPanelDeps)
- 可変状態は書き込み箇所と同じモジュールに置き、他モジュールへは読み取り専用で公開する(実例: src/webview/monitor/ の各モジュール)
- webview 資産(CSS/JS)はテンプレートリテラルに内蔵せず src/webview/ の実ファイル+esbuild バンドル(media/ 出力)にする
- エスケープ文脈が変わる逐語移動(テンプレートリテラル⇔実ファイル)では二重エスケープの残存を機械チェックする(`grep '\\\\[dswb]'` 等。過去に `\\d` が検証不能バグとして実害化)

## 国際化(i18n・日英切替)

拡張の UI 文字列は日英切替対応(設定 `ftester.language`: auto/ja/en、auto は VSCode 表示言語に追従。モニター「設定」タブからも変更可)。UI 文字列を追加/変更するとき:

- 辞書は `src/i18n/strings/<namespace>.ts` に `{ "ns.key": { ja, en } } satisfies MessageDict`。**ja は表示文字列と byte 一致**(未初期化時の既定 locale が "ja"・既存テストが日本語をアサートするため)。プレースホルダは名前付き `{name}` で ja/en 同集合。namespace とファイルは1対1。
- 拡張側: `import { t } from "./i18n"`(`MessageKey` 型で typo を tsc 検出)。activate 冒頭で `initI18n()`。webview 側: `import { t } from '../i18n.js'`(locale は `<html lang>` 経由)。静的 HTML(monitorHtml.ts 等)は拡張側 `t()` で描画する。
- **罠**: 拡張と webview の**両バンドルに入る .ts**(runReducer.ts/runLaneModel.ts 等。webview の import 連鎖で混入)は、vscode を引き込む `i18n/index.ts` を import できない(webview ビルドが壊れる)。vscode 非依存の別ランタイム `src/i18n/strings/lane.ts`(`tLane`/`setLaneLocale`、locale は両バンドルが注入)を使う。両バンドル共有の文字列を新たに i18n 化するときも同じ制約。
- **module-level の表示 const 禁止**(import 時=initI18n 前に "ja" で固定される)。関数化する(例 livePanelHtml.ts の `livePanelTitle()`)。
- package.json の contributes(コマンド名・設定説明)だけは別系統: `%key%` + `package.nls.json`(英)/`package.nls.ja.json`(日)で **VSCode 表示言語連動**(ftester.language ではない)。両 nls はキー集合一致。
- 検証は `test/i18n.test.mjs`(辞書パリティ・**残存日本語の AST 走査**[HTML コメントは除外]・webview/lane キー存在・nls 整合)。正当に日本語を残す文字列(非表示の内部 throw 等)は同ファイルの `RESIDUAL_ALLOWLIST` に登録。
- webview パネルの relocalize は未配線。`ftester.language` 変更時の反映はテストツリー再翻訳のみで、パネル・コマンド名・設定説明は Reload Window が必要(extension.ts が案内を出す)。

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
2026-08-05 に一斉修正(dry-run との対比で「実機の前に落とす」等と書いていた 20 箇所が、
実際は Simulator の話だった)。**翌 08-06 に再発**した —— Emulator 上の観測を
「実機で観測」とコメント・docs・コミットメッセージに書いた。**「デバイスで動かした」と
書きたくなった瞬間に、何の上で動かしたかを確認する**(プッシュ済みのメッセージは直せない)。
