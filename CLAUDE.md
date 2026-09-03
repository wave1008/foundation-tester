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
- 検証の詳細(flake/性能の判定規律・ベータ整合・全滅時の切り分け・e2e.sh のオプション): docs/verification.md
- 性能チューニング(調整ノブ・不採用施策と再検討条件・計測手順): docs/performance-tuning.md
- **結果 JSON のスキーマ**(run.json / scenarios/*.json の全欄・落ちた run の仕分けレシピ・
  **フレークの推移を run 横断で見るときに先に揃える4つ**(run の本数 / シナリオの集合 / 標本数 /
  デバイス構成)。揃えないと同じデータが改善にも悪化にも読める):
  docs/results-json.md(**唯一の定義元**。`results/` は .gitignore なので中に README を置いても
  受け手に届かない)。**`api results` の出力キャッシュ**(`<project>/.fleetest/results-cache/`。
  鍵は引数 + 実行ファイル + run ごとの stat 2回・`--since` は「窓から落ちた記録が無い」条件で厳密判定・
  確認は `--no-cache` との一致)も同ページ
- Shirates(Classic)との対応表(何が揃っていて何を持たないか・意図的に持たないものの理由・
  OS で挙動が割れるもの・足す価値がある残り): docs/shirates-parity.md。
  **コマンドを足す/名前を変えるときは必ずここも更新する**
- MCP 監査ラウンドの回し方(**1ラウンド = 初見の「形」1つ。アプリ名は軸ではない**。
  軸①画面の形 / 軸②セッションの形・拾ったものを**バグ / 自作機構の欠陥 / 言い回し**の3つに
  分ける規律・**増設と検分は交互**・停止規則・台帳): docs/mcp-audit-rounds.md。
  **地図の反復監査は閉じた。天気サイトはもう足さない**(→ maintainer-notes §9)
- MCP の使い勝手の計測(まっさらなエージェントがタスクを終えられたか・何手かかったか):
  Bench/README.md(`Scripts/mcp-bench.sh`)。**実 web ページの形も盤面で測れる**
  (`Bench/boards/` に HTML を置きホストで配信。**ライブの web は叩かない** = 盤面が毎日変わると
  手数の差が注記の効果と混ざる)。**手数は注記の有無で動かないと分かっている**ので
  (代替手段の無い盤面でも 5/5 完了。Bench/measurements.md)、**足す/消すの判断材料は
  note B(実現バイト)**。`NoteBudgetTests` の**本数と鍵の集合の等号固定**は
  引き続き効かせる(予算を動かすには根拠を台帳へ書く)
- 保守者向けの事故台帳(規則の由来): docs/maintainer-notes.md

### 受け手フローのスクリプト

- 受け手の状態判定: `Scripts/preflight.sh`(読み取りのみ。既定モードは引数なしでカレントを見て
  ready=0 / installed=2 / blocked=1。SKILL.md ステップ0・0.5 と 1:1)。
  **`--runner [--base <dir>]` はリモートランナー機としての判定**(ready=0 / needs-manual=2 /
  blocked=1。`fleetest remote setup` が scp して実行する)。**既定モードの出力は1バイトも変えない**
  (共通判定は関数に括り出して両モードから呼ぶ)。**判定を足すときは blocked/needs-manual の
  仕分けを間違えない** —— install.sh が自動導入するもの(xcodegen 等)を needs-manual にすると、
  `remote setup` が install.sh に到達できず「入れれば直るのに入れる工程まで進めない」で詰まる
- 受け手の一括導入: `Scripts/install.sh`(clone〜検証ゲートを冪等に実行)。
  - **各手順は `.claude/skills/fleetest-setup/SKILL.md` のステップ番号と 1:1**(失敗時に
    「→ SKILL.md ステップ N」を出す)。**片方だけ変えない**
    (`installStepSync.test.mjs` が「install.sh が指すステップが SKILL.md に実在するか」を検出)
  - **スキルからは curl 形で呼ぶ**(クローン側の Scripts/ は pull されるまで古い)。
    全出力は `<WORK_DIR>/.fleetest/install-<日時>.log` へ
  - **pull 後は自分自身を再 exec する**(条件は「実行中のファイル = pull したクローンの
    `Scripts/install.sh` 自身」かつ HEAD が動いたときだけ)。**`update.sh` にも同じ再 exec がある**
    (2周目は `FT_UPDATE_REEXEC` で up-to-date の早期終了を通さない)→ maintainer-notes §1.1
  - **画面は各ステップ1行(逐次)+ 集計だけ・生ログはファイルへ**(`--verbose` で従来)。
    最後の再掲は warn/fail だけ → maintainer-notes §1.4
  - **外部構成ではクローンのローカル変更を自動破棄**(reset --hard + `clean -fd`。`-x` は付けない
    = .build/ を消さない。`--keep-local` で従来)
  - **WORK_DIR の `CLAUDE.md` にマーカー付きで入口を4行置く**(ステップ7.6。`.mcp.json` も
    `.claude/settings.json` も「設定として効く」だけでエージェントが読む物ではないため、これが
    無いと導入の翌週にスキルの description しか手掛かりが無くなる)。
    **使い方の解説は書かない**(ツール説明と二重管理になり必ずズレる)。受け手の資産なので
    マーカーの内側だけ差し替え、嫌う受け手には `--skip-claude-md`。
    **ここは受け手のファイルを書き換える唯一の箇所**なので、**マーカーが begin/end ちょうど1組で
    なければ1バイトも書かない**(`installClaudeMdBlock.test.mjs` が3形を守る)→ maintainer-notes §1.2
  - **クローンが git 管理しているファイルには書かない**。判定はレイアウトではなく
    **`git ls-files --error-unmatch` で追跡の有無**。**受け手のフローに「クローンの中を書く」工程を
    足すときは必ず追跡を見る** → maintainer-notes §1.3
  - **毎回 `fleetest api ensure-settings` で Bash 許可リストを補修する**(init 経由だけだと
    `--skip-project` の更新で既存の受け手に永久に届かない)
- 受け手の更新: `Scripts/update.sh`(install.sh を再実行 + project sync + **Claude Code の
  プラグイン更新と版照合**(`marketplace update`→`plugin update`・版は `plugin list` の sha)。
  `.claude/skills/fleetest-update/SKILL.md` と 1:1)。**先に update-check.sh を呼び up-to-date なら
  即終了**(全工程は更新が無くても約30秒。入れ直しは `--force`)。**ログの場所は最後の
  「次にやること」にも出す**(install.sh には `--no-next-steps` を渡すため)。doctor は既定で
  出さない(`--doctor`)。**スキルのステップ0は `.fleetest/state.json` の Read で TOOL_ROOT を採る**
  (コマンドを打たない = 承認が要らない。無ければ preflight に落ちる)
- 更新の有無だけ判定: `Scripts/update-check.sh`(読み取りのみ。**fetch せず `git ls-remote`** で
  upstream と比較し up-to-date=0 / update-available=3 / pinned=0 / unknown=1)。
  VSCode 拡張が起動時に1日1回呼ぶ(`src/updateCheck.ts`・設定 `fleetest.updateCheck`)。
  **手動コマンド `fleetest.checkForUpdate` は間隔・却下・設定 off を無視して必ず結果を返す**
  (自動は更新があるときだけ喋る。両者の差はここだけ)。
  **更新の実行口はモニターの「設定」タブ1箇所**(`src/monitorUpdateController.ts`。判定も取り込みも
  スクリプトに委譲)。通知は手順を書かず「設定タブを開く」で誘導する。
  **実行ログは webview に持たせず OUTPUT へ**(検索・コピーが標準UIで済み、パネルを閉じても残る)。
  進行は状態行/ボタンのスピナー + `withProgress`(見出し行 `==>` だけ report する)。
  **webview で `window.confirm` は効かない** ——
  破壊的操作の確認はホスト側の `showWarningMessage({modal:true})`。
  **`reason=` は ja/en どちらでも英語**(拡張の通知に素通しするため。枠だけ訳す)。
  **TOOL_ROOT の解決規則は preflight.sh / update.sh / `src/toolRootResolve.ts` と同じ**(4箇所。
  片方だけ変えない。`toolRootContract.test.mjs` が規則の3語(クローン判別マーカー・既定の隣・
  Package.swift の宣言)の欠落を検出)

### エージェント連携・配布

- **インストーラが面倒を見るエージェントは Claude Code だけ**(規約位置の唯一の定義元は
  `Sources/FTCore/AgentIntegration.swift`。経緯と表は docs/design.md §15)。
  - **runbook 本体(`.claude/skills/<name>/SKILL.md`)は複製しない** —— Claude Code へは
    規約位置から正典を参照する薄いアダプタ(`.claude-plugin/`)だけを置く
  - **他のエージェント(Codex・Cline 等)向けの分岐をコードに戻さない**。案内は
    **docs/user-docs/tools/other_agents(.md/_ja.md) の1箇所**に集約する → maintainer-notes §2.1
  - **受け手のグローバル設定(`~/.codex/config.toml` 等)には1バイトも書かない**
    (`agentIntegration.test.mjs` / `agentAdapters.test.mjs` が落とす)
  - **正典をシンボリックリンクの側へ移さない** → maintainer-notes §2.4。
    **シェル(install.sh / install-skill.sh)は clone 前・ビルド前に走るので Swift を呼べず、
    規約位置を手で持つ** —— 片方だけ変えない
  - **SKILL.md に特定エージェント専用機能を前提として書かない**(`AskUserQuestion` は
    「選択ダイアログ(Claude Code なら AskUserQuestion)」の形で、実装ではなく意図を書く)
  - **Codex のサンドボックスはシェルだけを縛る**(`ft_*` は既定設定で全部動く。通らないのは
    シェル経由の導入・更新だけ)。**`network_access` / `writable_roots` を根拠に OK と言ってはいけない**
    → maintainer-notes §2.2
- MCP サーバの起動口: `Scripts/mcp-server.sh`(`.mcp.json` はこれを exec するだけ)。
  - **`.mcp.json` をリポジトリに置かない**(追跡外・`.gitignore` 済み)。登録は構成を問わず
    install.sh が**絶対パス**で WORK_DIR へ書く。**ルートに何か置くときは「プラグインに載って
    よいか」を必ず問う** → maintainer-notes §2.3
  - **シェル式を `.mcp.json` へ直書きしない**(起動のたび約8秒の `swift build` を払い、失敗すると
    `>/dev/null` で理由が分からないまま起動しない)
  - ランチャが守るのは3つ: **鮮度でだけ建てる**(`find Sources Package.swift -newer <bin>`。
    存在チェックに戻さない = InAppLauncher と同じ規律。建てた直後に `touch` するのは、
    無変更のソースを触っただけだと再リンクされず毎回建て直しになるため)/
    **stdout は JSON-RPC 専用**(診断は stderr・ビルド出力はログファイル)/
    **cwd を変えない**(cwd は受け手パッケージの特定に使う。ビルドはサブシェルで行う)
- **スキルを増やしたら `Scripts/install-skill.sh` の `SKILLS` を足す**(clone より前に走るので
  導出できず、**手書きの一覧はここだけ**。`update.sh` は TOOL_ROOT の正典から導出する)

### DSL コマンドの索引

- **機械可読な索引は `Sources/FTCore/CommandIndex.swift`**(`fleetest api dsl-commands` が出す)。
  **コマンドを足す/消す/改名したら索引も直す**(`CommandIndexSyncTests` が Commands.swift /
  CommandsVerify.swift / CommandsAppControl.swift / ValueAssertions.swift / FTElement と突き合わせる)
- **置いていない名前は `Sources/FTDSL/UnavailableCommands.swift` で受け止める**(他ツールの名前・
  対称性から実在すると誤解される別名。`cannot find in scope` の代わりに正しい書き方を出す)

### 失敗の記録と操作の規律

- **失敗の記録に置くのは事実だけ** —— フェーズ(`section`)・コマンド名(`command`)・
  経路(`failureKind`)・注記(`notes`)。**「環境要因の失敗」という分類は置かない**
  (アプリが重いのかマシンが混んでいるのかツールには区別できず、推測は誤った緑・赤を作る。
  ユーザー方針)。**言えないときは欄ごと省く**(「その他」に丸めない)。
  `command` を description から切り出さない・`failureKind` をエラー文言の一致で決めない
  (どちらも書式を変えた瞬間に静かに壊れる。仕分けは `DriverError` の case で行う)。
  渡し忘れは `CommandNamePlumbingTests` がソース走査で落とす
- **`tap` は対象が操作可能になるまで待ってから撃つ**(ユーザー決定「待って、それでも無効なら撃つ」)。
  **待ち切れなくても撃つ** = 無効な要素をわざと叩く書き方を壊さない。`&&enabled=` 明示の
  セレクタでは待たない。witness は `E2EAppAndroid` の `#btn_enables_late`(1.5 秒後に有効)
- **`tap(入力欄)` → `type("文字列")`(Shirates 伝統形)は支えるべき書き方**(ユーザー指示)——
  容器を叩いて焦点が立たなかったときは `InputFocusRescue` が入力欄を名指しして入れ直す
  (払うのはタップ直後の木1枚だけ・入れ先が一意に決まらなければ何もしない・注記
  `type-focus-recovered`)。**witness は `E2EAppAndroid` の `#field_wrapped`**
- **割り込みの自動クローズは止められる**(Shirates 準拠で4つ): `suppressHandler { }` /
  `useHandler { }`(ブロック形。出口で必ず戻る)と `disableHandler()` / `enableHandler()`
  (**CAE のブロックを跨げる唯一の形**。ブロック形は1つの CAE ブロックの内側にしか置けない)。
  **止まるのはツールが閉じることだけ**で、割り込みが出ること自体は変わらない。
  **抑止したまま落ちたときだけ**注記に出す(危険は「抑止したまま忘れる」)。
  witness は `TestProjects/E2E-iOS/scenarios/15_別ウィンドウのモーダル.swift` の S0050
- **割り込みに吸われた操作は撃ち直さない**(届いていた場合に二重実行 = 送信・購入で取り返しが
  つかない)。ツールが閉じるのは**ステップ開始時点で出ている割り込み**まで。**間に湧いた分の
  復帰はシナリオ側**(docs/commands.md §割り込みが「操作を吸った」ときの扱い)。
  **自動リトライを再提案しない**

### リモート

- **リモートの純粋ロジック(SSH ディスパッチ・登録簿の解決・dispatch.lock・占有・setup 計画)は
  `Sources/FTRemote`**(利用側は fleetest CLI だけ。受け手のシナリオ実行バイナリにはリンクしない)。
  **FTCore から FTRemote を参照しない**(循環)—— `LocalConfig` が持つ登録簿のスキーマ
  `RemoteHostEntry` だけが FTCore に居る。他の分割は保留(理由は maintainer-notes §10)
- **用語(ユーザー決定。全体で一貫させる)**: **host = ホスト名 / IP**(ネットワークの実体)、
  **machine = その host に対するローカルエイリアス**(この Mac の登録簿だけが知る名前)。
  定義と4つの規律(①エイリアスをリモートへ出さない ②記録の鍵は host ③プロファイルに ssh 実体を
  書かない ④**手元の台帳をランナーの視点で書かない** = 他機の台に `machine: "local"` と書くと、
  ディスパッチが手元へ落ち、監視では実在する手元の同名機が id 衝突で消える)は
  docs/remote-runner.md §0。**エイリアスは頻繁に変わりうるので記録・登録の鍵に
  しない**(例外はその machine 自身に関する構成)。JSON キーはプロファイル `devices[].machine`・
  登録簿 `machine`・記録 `host`。**拡張 ⇄ webview のメッセージと CLI ⇄ 拡張のワイヤも `machine`**
  (ProtocolVersion 9。同時配布なので旧キーは読まない = **型検査の効かない webview 境界は
  往復テストで縛る**)→ maintainer-notes §3.1。
  リモートへ送るプロファイルは `FTCore.RunnerProfileView` が「そのランナーから見た姿」へ畳む
  (自分の台は `machine: "local"`・他機の台は削除)ので、**転送物にも引数にもエイリアスは出ない**
- **リモートのデバイスの監視と配信**: 手元の `api monitor` は simctl/adb = **この機械しか観測
  できない**。別の機械のぶんは `RemoteMonitorFanout` が
  `remote exec <host> -- api monitor --device-machine local` を1本ずつ立てて合流させ、
  ライブ映像は**1デバイス = 1本の ssh**(`api device-stream` が向こうで宛先を解決し配信ヘルパーへ
  `execv` で化ける = stdout のバイト列が手元起動時と同一なので `StreamPipeline` をそのまま使える)。**多重化の枠は作らない**(却下理由は docs/remote-runner.md §13)。
  守る規律3つ: **①他の機械の台を走査しない**(仕分けは `ApiMonitorCommand.scope` が pure に持つ)/
  **②観測していない台は `state:"unknown"`** —— offline と別の値にする(同じにすると向こうで
  動いていても止まって見える。拡張の `MonitorDeviceState` と対)/ **③配信が張れなければ
  ポーリングへ落ちる**。**版が揃っていないと状態も映像も来ない**。
  **操作も同じ規律** —— 一括だけでなく**タイル1枚の起動・停止もその機械へ回す**
  (手元で `api device-up --name` を撃つと、同名の台が別の機械にも居るとき**別の機械の設定で
  この Mac にシミュレータが1台できる**。`findDevice` は (machine, name) で引き、
  `--device-machine` の既定は手元)。
  **中継する側が machine を埋める**(3経路とも: `RemoteMonitorFanout.ingest` /
  `RemoteDeviceFanout.machineStamped` / `ApiRunMachineFanout` の rehost)—— 子は
  `--device-machine local` で走るので自分の台を `machine:null` と名乗り、そのまま流すと拡張が
  **同名の手元のタイル**を書き換える(機械ごとに2台ずつ起きていても「全体で2台」に見える)。
  **自動修復(watchdog)はリモートの台を見ない**(修復手段が手元にしか効かず、記録が name 単位)。
  **ホストの負荷(MEM/CPU/GPU/FM)も同じ** —— 拡張が
  `remote exec <machine> -- api host-metrics` を機械ごとに立て、ツールバーのグラフを
  **機械ごとの行**にする(左端は手元が `local`・以降は機械名。1行のときはラベルを出さない)。
  **行の集合は直近の monitorDevices に居る機械で決める**(表示フィルタは通さない = ssh の churn を
  作らない)/ **消えた機械の行は捨てる**(古い値を出し続けない)/ **機械名は spawn した側が付ける**
  (サンプル自身は持たない)。**FM も同じ行に乗る**が、host-metrics は FM を自分では叩かない
  (測る対象を自分で消費してしまう)—— **FM を呼んだプロセスが
  `~/.fleetest/fm-usage/<pid>.json` に置いた控えを毎 tick 読む**(`FTCore.FMUsageLedger`。
  機械グローバル = `api host-metrics` に `--project` が無い性質を保つ / 生存判定は **pid だけで
  mtime を見ない** / **読めない(不明)は null・呼び出し 0 件は 0** で混ぜない / 初見の pid は
  増分 0)。**run のイベントからは供給しない** —— 拡張が起こした run しか見えず、CLI 実行や
  他人の run が 0 に見えるため
- **FM の「死活」は回数とは別の軸**(`FTCore.FMLiveness` が唯一の定義元。
  `~/.fleetest/fm-liveness.json`)。回数は「使われたか」しか言えないので、**誰も呼んでいない間は
  死んでいても 0 件と同じ絵**になる。守る規律5つ: **①生 / 死 / 不明の3値**(記録が無い・
  `freshSeconds`(120秒)より古いは不明。死と混ぜない)/ **②経路は text と vision で別に持つ**
  (**独立に死ぬ・戻る**実測。畳むと text だけ生きた機械で occlusion-guard の全滅を見落とす)/
  **③availability を書き手にしない**(`.available` のまま全滅する。`unavailable` の向きだけは
  信じてよい)/ **④単発の失敗で死と言わない**(連続 `FMBreaker.threshold` 回。閾値は増やさず
  ブレーカのものを共有する。**ただし数えるのは経路ごと** —— ブレーカのカウンタは経路を区別せず、
  text の成功が毎回戻すので vision の死を記録できない)/ **⑤プローブは `FMHealth` /
  `FMUsageLedger` に書かない**(書くと誰も run を回していないのに FM のレートが動く =
  測る対象を自分で消費して見せる)。
  **`api host-metrics --fm-probe` だけが「host-metrics は FM を叩かない」の例外**
  (拡張のモニターだけが渡す。既定 OFF)—— 撃つのは**台帳が古く、かつ誰も FM を使っていない**
  ときだけ(`FMLivenessProbe.refresh` の門①②③。FMLock は 1 秒で諦める = 実仕事を待たせない)。
  プローブ間隔 60 秒の根拠は `Scripts/fm-flap-monitor.swift` と同じ刻み。
  読み手は4つ: モニターの FM 行(NDJSON の `fmTextState`/`fmVisionState`/`fmDeadReason`/
  `fmCheckedAt`)/ run 開始前の警告(`ProfileRunner.warnIfFMDegraded`。**heal の有無で
  出し分けない** —— occlusion-guard・screenLooksLike・triage は heal を切っていても FM を引く)/
  run.json の `fmDead`・`fmDeadReason` / `ft_status`・`ft_doctor`・`fleetest doctor --fm-only`
  (**doctor は text と vision を両方 実呼び出しで確かめ、どちらが死んでも exit 1**)
- リモート実行(`run --machine` / `--host` の SSH ディスパッチ):
  - **ssh 越しに何かを起動する経路を新設したら非対話 PATH の補正
    (`/opt/homebrew:/usr/local/bin`)を必ず写す**(既存は `RemoteShell.remoteRunCommand`)
  - **子プロセスを spawn する経路を足したら中断のリレーも足す**(`InterruptRelay`)。
    **async 文脈でパイプを行読みするときは `FTRemote.PipeLinePump`**(semaphore の `wait` を
    async 文脈に書かない = Swift 6 でエラー。同期関数の既存2箇所は据え置き)。
    **SIGKILL へのエスカレートは ssh にだけ**。**シグナルソースは1プロセスに1組**
    → maintainer-notes §3.2。`fleetest remote unlock` は自分の死んだディスパッチのロックだけを外す(`RemoteDispatchUnlock`)
  - **`--machine M`(旧 `--host`)+ 明示 `--device` は M の台に限定**
    (`RemoteDispatchExplicitDeviceScope`)。**`--machine local` も同じ判定を通す**
    (run / api run の2経路。絞らないと別ホストのエントリの UDID を手元で探して
    `no simulator with that UDID` で止まる)
  - **LPT はリモートでも実績で回る**: 実績 JSON は on-demand でも常に回収・実績と観測窓は
    machine 別・フリート割り当ては facts キャッシュ(`.fleetest/remote-hosts/<host>.json`)で
    機械別に見積もる(実測は docs/performance-tuning.md §3.7)。**facts の machine 採取は
    relink より前** → maintainer-notes §3.3
  - 設計・却下案・セキュリティ前提は docs/remote-runner.md / **利用者向けの導入手順は
    docs/remote-runner-setup.md** / **エージェント向けは
    `.claude/skills/fleetest-remote-setup/SKILL.md`**(機械作業は `fleetest remote setup` に委ね、
    聞くこと・人手へ渡すこと・結果の読み方だけを持つ)。**片方だけ変えない** —— 手順に影響する
    変更(レイアウト・併用不可オプション・適合チェックの項目)は docs とスキルの両方に入れる
- **共有(複数ユーザー)の規律**(docs/remote-runner.md §18.7。M2 実装済み): **占有を知るために
  ssh を足さない** —— `dispatch.lock` はランナーのディスクにあるので、**向こうで走っている子
  (`api monitor` の fan-out)にローカルで読ませ**既存の NDJSON(`monitorLock`)に相乗りさせる
  (場所は `FT_RUNNER_BASE`・判定は `FTRemote.HostOccupancy` の1箇所)。守る規律4つ:
  **①「不明」と「空き」を混ぜない**(子が落ちたら `observed:false`。**控えは消さない** ——
  消すと「一度も聞いていない機械」= 配信してよい、と同じ形になり run の最中に配信が再開する。
  不明の間は**配信を畳んだまま・保持者は名乗らない**(`isConfirmedHeld` を通す)。
  不明を空きに倒すと破壊的操作の確認が「走っている run は無い」と誤って請け合う)/
  **②配信の退避は保持者を問わない**(自分の run でも干渉は同じ)**が、畳むのは配信だけで観測は続ける** /
  **③二重配信は拒否でなく事実で止める**(`FTCore.StreamLease` の控えを監視が読んで
  `streamedByOther` を配り、拡張が起こさない。**起こしてから断る形にすると ssh の再試行ループ**
  になる)/ **④他人の run を殺す操作はロックを読む**(`remote clean` は中止・
  `--ignore-lock` で押し切る。**読めないときは通す** = 掃除が永久にできなくなるほうが害が大きい)。
  **奪う口(`--force-lock`)を GUI に出さない**。
  **ssh 越しのコマンドにグロブを書かない**(相手は zsh。`for w in <マッチ無し>` は**シェルごと
  落ちて後続の文が全部消える**)—— 一覧は `find … 2>/dev/null` で作る → maintainer-notes §3.5
- **リモート制御(実行プロファイルの `remoteControl`)**: ワークスペース(資材の置き場)+
  **run 前後のスクリプト**(docs/remote-runner.md §17)。**スクリプトに宣言は無い** ——
  `<workspace>/scripts/setup.sh` / `teardown.sh` が**あれば実行、無ければ何もしない**
  (名前も置き場所も固定。拡張のフォームにも入力欄を置かない = ユーザー決定)。
  **呼ぶのは `ProfileRunner.run` と `ApiRunCommand` の2箇所** —— リモートの子は
  `fleetest run --host local` として向こうで同じコードを通るので `RemoteRunDispatcher` には
  足さない。守る規律3つ: **①setup の失敗は run を止める**(teardown の失敗は結果を変えない)/
  **②デバイスに触る前に撃つ** / **③片付けは defer だけに頼らない** —— setup の前に
  `.fleetest/hooks/<pid>.json` を置き、次の run 開始時と `fleetest hooks reap`(`remote clean` が撃つ)が死んだ pid の
  ぶんを代わりに実行する(**生存判定は pid だけ。mtime を見ない**)。
  **転送から外すのは `.fleetest-transfer-ignore`**(`FTCore.TransferIgnore`)。
  **rsync の `-F`(dir-merge)は使わない** → maintainer-notes §3.4。
  **3つの転送(run ディスパッチ・fan-out の `RemoteProjectSync`・プロジェクト外ミラー)が
  同じ走査を通る**(`rsyncArgs` の `ignore:` は既定値無し = 読み忘れはコンパイルで止まる)

### fleetest 自身の E2E(SUT)

**UI フレームワークごとに SUT が5つ**ある(画面・`#id`・ラベルは全 SUT 共通契約):

| SUT | 実装 | プロジェクト | 対象 OS |
|---|---|---|---|
| `E2EAppCMP/` | Compose Multiplatform | TestProjects/E2E-CMP | ios + android |
| `E2EAppIOS/` | SwiftUI + 一部 UIKit | TestProjects/E2E-iOS | ios |
| `E2EAppAndroid/` | View/XML + 一部 Compose | TestProjects/E2E-Android | android |
| `E2EAppFlutter/` | Flutter | TestProjects/E2E-Flutter | ios + android |
| `E2EAppRN/` | React Native | TestProjects/E2E-RN | ios + android |

- **iOS だけが持つ witness**: `E2EAppIOS/Sources/UI/OverlayWindow.swift` = **キーウィンドウに
  しない別 UIWindow のモーダル**(全画面 / 上部バナーの2形)と、診断画面の `#btn_request_photos`
  = **OS(SpringBoard)の権限アラートがアプリを覆う形**(別プロセスなので in-app の木に載らない。
  緑の回帰は `scenarios/16_システムアラート.swift`・**陽性対照は `_disabled/94_システムアラート.swift`**)。
  覆い・別ウィンドウに関わる変更は `TestProjects/E2E-iOS/scenarios/15_別ウィンドウのモーダル.swift`
  の4本で対照を取る(docs/verification.md)。**4本目は条件判定**(`ifCanSelect`)——
  **perform を通らないので操作・検証を直しても守られない**
- **要素の testTag/`#id`/ラベルの唯一の正は `E2EAppCMP/docs/ui-contract.md`**(全 SUT とシナリオが
  これを参照。片方だけ変えない。`uiContractSync.test.mjs` が「SUT 側の `#id` が母体に実在するか」を
  検出)。**型語彙・OS/フレームワーク固有の罠だけ**は各 SUT の `<SUT>/docs/ui-contract.md` に置く
  (同じ `#id` でも型は SUT ごとに違う。例: ボタンは CMP/Android で `Cell`、View/XML なら `Button`)
- **5 SUT のシナリオはほぼ同内容だが共通化しない**(ユーザー決定・可読性優先)。DSL 変更のたび
  5箇所を編集することになるが、共通化すると SUT 固有の差(型語彙・フレームワーク固有の罠)が
  表現しにくくなる。**共通化を再提案しない**
- **ディープリンクの URL スキームは SUT ごとに固有**(`fte2ecmp`/`fte2eios`/`fte2eandroid`/
  `fte2eflutter`/`fte2ern`。契約は `E2EAppCMP/docs/ui-contract.md` §ディープリンク)。
  iOS は同一スキームを複数アプリが登録していても解決先を1つしか選ばず、E2E のシミュレータには
  iOS の SUT が4つ同居するため共有スキームでは配送先が端末ごとに揺れる。
  `Tests/FleetestTests/DeepLinkSchemeSyncTests.swift` が契約表との一致と SUT 間の重複を検出する

## ビルド・検証

**検証の詳細な罠と判定規律(flake/性能の判定・macOS/Xcode ベータ整合・常駐プロセス掃除・
「Application is not running」全滅時の切り分け・`Scripts/e2e.sh` の各オプション)は docs/verification.md**。
以下は毎回効く最重要ゲートだけ。

### 拡張(vscode-fleetest)

- `cd vscode-fleetest && npm run compile`(esbuild+tsc)/ `npm test`。挙動を変えたら
  **`npm version --no-git-tag-version <新版>` で版を上げて** `npm run install-local`
  (反映は VSCode の Reload Window **+パネル開き直し**。code CLI は PATH に無い)
- **package.json だけ手で書き換えない** —— lock も version を内包しており、放置すると受け手の
  `npm install` が lock を書き換えてクローンが dirty になり、**次の更新が pull ガードで止まる**
  (`packageLockSync.test.mjs` が検出。既にズレたら `npm install --package-lock-only`)
- **jsdom を使う webview テストは `t.after(() => window.close())` で必ず閉じる**
  (`jsdomTeardown.test.mjs` がソース走査で落とし、`npm test` は `--test-force-exit` 付き)
  → maintainer-notes §4.3。**同型: `argumentHelpLiteral.test.mjs`**。
  **一般化: 「コンパイルで落ちる誤り」「テストが終わらない」型はソース走査で秒未満に落とす**

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
  セレクタ/スナップショット/ヒール(`FTFoundationModels`)を変えたら `Scripts/e2e.sh`**
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
  記録し、開始時と終了時に食い違いを警告する(`fleetest api bridge-sources --set inapp|xcuitest --digest`)。**落とさず警告だけ**
  —— **ただし xcuitest の警告は 2026-09-02 時点で鳴りっぱなし**(既知の打鍵中抜け2本で
  E2E-RN が赤 → 全緑が条件の印が永久に更新されない。**未検証の意味ではない**)。
  この警告を見たら回す前に docs/verification.md の該当節を読む
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
  誰も見ていない読みだけ** → maintainer-notes §4.7
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
- **変異が生き残ったら、まずテストの置き場所とフィルタを疑う** → maintainer-notes §4.12

### 版と契約の同期(片方だけ変えない)

- `fleetest api` の JSON/NDJSON 契約を後方非互換に変えたら `Sources/FTCore/ProtocolVersion.swift` と
  `vscode-fleetest/src/protocolVersion.ts` の版を +1(両者一致必須・`protocolVersion.test.mjs` が
  検出。拡張は起動時に照合し不一致を警告)
- **`fleetest run` と `fleetest api run` はオプションも配線も別々に持つ2実装**。片方だけに足した
  変更はどちらの経路も緑のまま通る(実行されるのは足したほうだけ)。**意図した差分は
  `RunCommandFlagParityTests` が等号で固定する** —— 片側にフラグを足すと落ちるので、
  「両方に足す」か「片側だけでよい理由を表へ書く」かを必ず選ぶ
- **ブリッジの挙動・エンドポイントを変えたら版を上げる** → maintainer-notes §4.4。
  iOS = `Sources/FTCore/BridgeDTO.swift` の `bridgeProtocolVersion`(in-app dylib と XCUITest
  ランナーの共通定数)/ Android = `AndroidRunner/build.sh` の `VERSION_CODE` と
  `AndroidBridge.swift` の `expectedBridgeVersionCode` を**同時に**
  (`AndroidBridgeVersionSyncTests` が定数間の不一致と、**コミット済み `prebuilt/ftbridge.apk` が
  定数と別版のまま = APK 作り直し忘れ**を検出)。**実装ソースを変えたら `BridgeContractTests` が
  落ちる**ので、そこで版を上げてから期待値を貼り替える(貼り付け用のリテラルは失敗メッセージが
  出す)。検出は2段: ルート表(エンドポイントの増減)+ ソース指紋(**ルートが同じで
  ハンドラだけ変えた場合も落ちる**)。**版を上げること自体は強制できない**ので最後は人間の規律。
  **試行的な変更ほどブリッジに入れない**。
  **ブリッジの入力ファイル一覧は `Sources/FTCore/BridgeSourceSet.swift` が唯一の定義元**
  (`InAppLauncher` の dylib 再ビルド判定も同じ一覧を使う。片方だけ変えない)
- **LPT の実績 run 数の既定値は3箇所(`LPTOrdering.defaultHistoryRuns` / `package.json` の
  `fleetest.lptHistoryRuns.default` / `monitorPanel.ts` が webview へ送る default)で一致必須**
  (`lptDefaultSync.test.mjs` が検出)

### 判定は1箇所に置く

- **判定は MCP と DSL で共有する**。「手前かどうか」は `FTCore.PaintOrder`、「撃つと別の物に
  当たるか」は `FTCore.TapTargetGeometry`(合成チェーンは `occlusionAdvisory`)と
  `FTCore.OcclusionGeometry`(中心を覆う最前面の名指し。`OcclusionSuspicion.covering` とは
  判定軸が別 = 面積比 vs 中心点。統合しない理由は両型の doc)、「絵が古いか」は
  `FTCore.StaleFrameDetector`、焦点待ちの定数は `FTCore.FocusWait` の1箇所だけに置き、
  `RefGuard`/MCP は転送する。別々に持つと**同じ画面で MCP と DSL の判断が食い違う**
  (実例は maintainer-notes §5)。移設したときは**掃討ゲート(`SweepHarnessTests`)が
  実アプリのコーパスで等価性を検証する**
- **木からは原理的に判定できない遮蔽は「ブリッジの申告」+ 専用の型** —— キーボードは
  `KeyboardOcclusion`(`keyboardFrame`)、**それ以外の別ウィンドウは
  `FTCore.OverlayWindowOcclusion`(`overlayWindowFrames`)**。Android の木の根は
  `getRootInActiveWindow()` = **アクティブウィンドウ1枚だけ**なので、手前に居る非フォーカスの
  ポップアップ(ツールチップ・テキスト選択のフローティングツールバー)は `elements` に1要素も
  載らず、覆われた要素を無警告で撃っていた。**申告由来の2つは木由来の警告より先に言う**
  (確度が最も高い)。**この2つの引数に既定値を置かない** —— 新しい呼び出し元の呼び忘れを
  コンパイルで止めるため(`OverlayWindowOcclusionWiringTests` が配線を、変異チェックが
  検知の生死を落とす)。**この検知は「出れば正しい」であって「出なければ覆いが無い」ではない**
- **共有するのは「判定」であって「文言」ではない**。正しい形は**①判定・順序・当たり判定を
  FTCore に1つ ②文言は呼び手ごとに持つ**。**呼び手は中核を呼んで写すだけ**にする。中核は `TapTargetGeometry.advisoryKind` /
  `FTCore.SimilarLabels` / `FTCore.BackEffect` / `FTCore.SnapshotTruncation.remedy` /
  `TapTargetGeometry.offscreenScrollGateCentre`。**天井まで来ていたら「上げろ」と言わない**。
  **FM に訊いて答えが無かったステップは `visibility-guard-skipped`** を立てる
- **type の読み返しの有無はドライバの能力**(`AppDriver.verifiesTypedText`。xcuitest ランナー/
  Android 注入器 = true・in-app = false で、false のときだけ `StepExecutor` がホスト側で読み返す)
- **デバイスの健康状態も同じ**: 「画面が凍結しているか」は `FTCore.FrozenVerdict` が唯一の定義元で、
  run 前トリアージとモニターは**根拠(`FrozenEvidence`)を束ねた同じ型**を配る。プロセスを跨ぐ
  受け渡しは `FTCore.DeviceFrozenStore`(`.fleetest/frozen-<key>.json`。RunLease と同じ
  pid 生存 + mtime)。**新しい根拠は `isConclusive=false`(警告)から入れる**
- **「木が画面を代表していない」判定は `FTCore.TreeCoverage` の1箇所**(webView の内側に大きな
  空白帯が残る形と、アドレス欄はあるのにページ本体が1要素も無い形)。**失敗の型は打ち切りと同じ**
  (不完全な木で否定アサーションが誤って成功する)ので、DSL の notExists/count も
  `StepNote.treeUnderreported` を運ぶ。**判定は変えず注記だけ** —— 幾何からの疑いであって
  申告された事実ではないので、断定すると空のページに対する正当な `notExist` が書けなくなる。
  同型で `FTCore.DuplicateRegion`(横スクロールで前後のコピーが両方 木に残る形。DSL の tap は
  `StepNote.staleDuplicateRegion`)—— こちらは `hasClampedCoordinates` では**発火し得ない**ので
  独立に持つ。どちらも固定コーパスで**発火する画面の集合を等号で固定**する
  (`TreeCoverageTests` / `DuplicateRegionTests`)
- **要素上限の撮り直しは肯定側にも要る**。`retakenAtElementLimitCeiling` は notExists/count
  (誤った成功)だけを塞いでいたが、操作側は**実在する要素で赤くなる**。操作側は**ドライバ切替と
  FM ヒールより前**に置く —— 切り詰められた木で FM に代わりを探させると、実在する本命が候補に
  無いまま別の要素へ「修復」し、それが `fleetest api apply-heal` で利用者の .swift へ書き戻される
- **「書けるセレクタ」の規則は `FTCore.SelectorNaming` の1箇所**(一意性(`picksOnlyOne`)・
  祖先スコープ・記法のエスケープ・耐久性の格付け)。**ヒール(自己修復)もここを通す**。
  (→ maintainer-notes §8)。書けるセレクタが無いときは**操作は続けて修復だけ成立させない**(`StepNote.healUnwritable`)——
  掴んだ要素は手元にあるので叩くのは正しく、書き戻せないという理由で緑の run を赤にしない
- **ロケータの指紋(`FTCore.LocatorFingerprint`)の規律4つ**(詳細は docs/design.md §10
  「ロケータの指紋」): **①効くのは失敗経路だけ**(プライマリ・フォールバック・キャッシュが
  すべて外れたとき。今緑のステップの挙動は変えられないので、リスクがこの1箇所に閉じる)/
  **②ちょうど1件一致のときだけ採用**(スコアも距離も作らない。複数件を「もっとも近い」で
  選ぶと別要素へ静かに解決し誤った緑を作る)/ **③記録するのはプライマリ/フォールバックで
  解決した回だけ**(指紋・ヒール・FM の回を記録すると誤った解決が固定化され再生産される)/
  **④ヒールキャッシュへ書かない**(毎回再導出できるので得られるのは速度だけ。一方で
  誤りが永続化して注記が消える。FM ヒールは confidence の門を通るが指紋にその門は無い)。
  **控えるのは `type` + `label` だけ** —— `id` はドリフトで変わる当のもの、`value` は毎回変わる。
  **失効はシナリオ単位の置き換え**(時間の定数を使わない): 通った run で、その `scenarioID` の
  鍵のうち触れなかったものを刈る。**記録0件の run では刈らない**(全ステップが `.healed` の回に
  根こそぎ消える)・**接頭辞で自分のシナリオのぶんだけ**(部分実行で他を巻き込まない)
- **セレクタ文法(`FTSelector`)・コマンド索引(`CommandIndex`)・コード生成(`ScenarioCodeGen`)は
  FTCore に居る**(写像先の `FlowLocator` が FTCore の型で、DSL ランタイムには依存しない)。
  利用者からの見え方は `Descriptors.swift` の `@_exported import FTCore` が保っている。
  **ただし FTCore の名指し(`TapTargetGeometry.describe` 等)は「どれの話か」を短く言うためのもので、
  セレクタとして貼れる保証はしない** —— 貼れる形が要るなら `SelectorNaming` を通す
- **MCP(`ft_*`)は DSL と別経路なので、鮮度・防御を DSL 側に入れただけでは届かない**
  → maintainer-notes §5。**ただし同じ判定をそのまま強い挙動へ流用しない**。探索ロジックは
  **MCP に2つ目の実装を書かず `StepExecutor` へ委ねる**(`ft_scroll_to`)
- **木だけから決まる注記は `Sources/fleetest-mcp/NoteCatalog.swift` が唯一の定義元**
  (`NoteCoverageTests` のソース走査が検出)。目録にすると3つ手に入る: **発火の全数計測** /
  **鍵ごとの黙らせ**(`FT_MCP_NOTES_OFF=<鍵,…|all>`)/ **出力バイトの回帰ゲート**。
  **注記を足すか消すかは読んだ印象で決めない** —— `Scripts/mcp-bench.sh` で手数が動いたかで決める
  (バグは有限だが「もっと分かりやすく言えたはず」は無限に出るので、印象で決める限り注記は
  単調に増える)。**「出ない」を削除の根拠にする前に、必ずアーキタイプを足して測り直す**。
  **フィクスチャの分類の正は `NoteCoverageTests.archetypes`**(接頭辞は OS を表すだけ)。
  **「地図でしか出ない」と見えた注記も、アーキタイプを足すと他でも出る**
  (`unlabeledClickablesNote` は settings、`keyboardCoverageNote` / `scrollFrameCandidates` は
  chat で発火した)。残る `truncationNote` / `ghostNote` は各1画面のみ、
  `bulkExemptNote` / `sliverNote` は0枚 —— 死に注記は理由を確かめて `knownSilent` に
  登録する(等号照合なので新しい死に注記は落ちる)。
  **1つのアーキタイプがコーパスの 60% を超えないこと**(`testNoArchetypeDominatesTheCorpus`)——
  深く掘るほど1アプリが増え、**掘るほど汎用性の判定が悪くなる**逆向きの力が働くので機械で止める
- **エラーの status はホストの分岐契約**(表は docs/design.md §4.3)。とくに
  **XCUITest ランナーの 409 は `requireApp()` の1箇所だけ** —— ホストはこの経路の 409 を無条件に
  「セッション消失」と読んで activate を撃つ。「セッションはあるが今は無理」は **422** を使う
  (`BridgeRouterStatusContractTests` が 409/503/501 の本数を数えて守る)。in-app ブリッジは逆に
  409 を一時的競合へ広く使ってよい(あちらは包まれない)

### 個別の規律

- **木は a11y が既定。ブラウザで足りないときだけ DOM で補う**(**どの組み合わせでどこから木が
  来るかの一覧は docs/design.md §木はどこから来るか**)。**口は3つ・その上の層は1つ**
  (Android Chrome=CDP / iOS Safari シミュレータ=unix ソケット / iOS Safari 実機=usbmuxd →
  lockdown → TLS)。**条件分岐にしない** —— a11y の充実度はページごとに変わるので、
  ブラウザでは常に DOM を正とする。差し込みの判定は `FTCore.WebViewDOM`(`WebViewDOMTree.swift`)の1箇所。
  **`WebViewDOMSnapshot.swift` へホスト専用の関数を足さない**(ブリッジのソース集合に入っており、
  足すと dylib に無駄が入って指紋ゲートが鳴る)。**実機 iOS だけの罠3つ**は docs/design.md §実機だけの罠
- **1台の失敗で全体を落とさない**。供給は部分失敗を許容し全滅のときだけ throw する
  (`BridgeProvisioner.resolveOutcomes` = 純粋関数)。**逆向きも守る —— 全レーンが同時に落ちて
  いるときにレーンを離脱させない**(`FTCore.WorkerCircuitBreaker`。連続失敗での離脱は
  「その streak の間に別のレーンが通った」証拠があるときだけ。無ければ残して走り続け
  `circuitHeld` を記録する。condition 除外案・閾値ノブだけの案は却下)→ maintainer-notes §6
- **容器推定(`StepExecutor.clippingContainer`)は scrollable 申告の祖先を優先する**。
  この関数はタップの座標補正・ghost 判定・MCP にも効くので、触ったら 5 SUT のフル E2E
  **+ `--ios-xcuitest`**。**フルスイートは iOS を in-app で回すので、これだけでは守れない** ——
  現にこの規則の導入(`8a416bc0`)が xcuitest 限定の退行を入れ、フル E2E 緑のまま通った
  (**同日 `931897d6` で修正済み** —— 申告の祖先へ倒すのは「深さ由来の候補が要素を収められない」
  ときだけ。経緯と壊れ方は maintainer-notes §4.5.1)
  **座標ドラッグは `StepExecutor.dragWithFallback` だけから撃つ**(in-app は drag が 501。
  `driver.drag` を直に呼ぶと hybrid で黙って不発になる)
- **システムアラートの判定は2段**: 登録がある間は `SystemUIGate` が毎ステップ止める / 登録が
  無いときは **launch 直後の最初の触る操作と失敗時だけ1回聞いて** `system-alert-present` の注記と
  題名を残す(止めない・閉じない)。常時監視へ広げない
- **ブリッジを起動する前に「そのポートを今 LISTEN している実体」を確かめる**。`/status` 応答だけで
  数えると、背面に回った in-app ブリッジ(TCP 受付・HTTP 無応答)が掴んだポートを「空き」と
  採番して新しい注入が衝突する(全シミュレータは loopback を共有 = ポートは台を跨いで一意)。
  `PortHolder.stopIfOwnedBridge` / `describe` と `StaleBridgeStop.decide` が定義元。
  **失敗は占有者を名指しして落とす**
- **回復のたびに label(ポート)は変わる**。回復を注入するときは**その時点のワーカー一覧を渡す**
  (`BlankWorkerTriage` の `recover` は第2引数)。最初の一覧を捕まえたままだと2回目の試行で
  新しい label を引けず、`frozen devices have no iOS simulator udid` で必ず失敗する
- **Android のテキスト注入(`InputInjector`)を触ったら負荷10周で判定する**
  (`for i in $(seq 10); do Scripts/e2e.sh --cmp --android; done`)。**単独実行では出ない** flake が
  ある(高負荷でだけ約40%)。守る規律 —「`ACTION_SET_TEXT` の `true` は受理であって反映ではない
  (必ず読み返す)」「`combined` は最初の読みから1回だけ作る(パスワード欄の読みはマスクされて
  おり、作り直すと伏せ字を書き込む・二重追記する)」「フォーカスが立つまで撃たない」
  「追跡は座標でなく resource-id」「**読む前に `refresh()` する**(a11y ノードはキャッシュ供給で、
  とくに WebView は DOM 変更を数秒遅れて出す。取り直さないと**入っているのに古い値を
  読み続けて**期限切れで 500 になる)」 — と不採用案(`ACTION_FOCUS`・ホスト側のキーボード回避)は
  docs/design.md §Android のテキスト注入の規律

## 受け手フローの設計方針(スキル・スクリプト・CLI の分担)

- **機械作業はスクリプト/CLI に寄せ、スキルには判断だけ残す**。エージェントに JSON を書かせる・
  値を集めさせると、実行のたびに結果が揺れる。決まった手順は `Scripts/*.sh` か `fleetest` の
  サブコマンドにする
- **承認回数はコストとして数える**。値の収集は preflight の出力に寄せ、デバイス選定は
  `profile setup --auto-device`、繰り返す実行は `.claude/settings.json` の許可(fleetest 由来の
  コマンドのみ。`api ensure-settings` が毎回補修)で吸収する。承認は3方向から増えるので全部潰す:
  **①聞かなくてよい確認**(答えが決まっているならスクリプトが決める)/ **②許可リストに無い
  コマンド**(スクリプトを足したら許可も足す)/ **③巨大な出力**(切られてエージェントが grep を
  打つ。生ログはファイルへ)。**出力済みの情報を別コマンドで取り直さない**
- **人に聞くのは AskUserQuestion(ダイアログ)だけ**。チャットに質問文を書くと見落とされてフローが止まる
- **生成したシナリオの検証は3段**(`.claude/skills/fleetest-scenario/SKILL.md` ステップ4→4.5→5):
  コンパイル → **dry-run(デバイス不要・数秒)** → デバイス実行。真ん中を飛ばすと「コンパイルは
  通るが何も検証していない」をデバイス実行の時間で見つけることになる。**誤りは早い段の言葉で返す**
  (未知の名前 = コンパイラのメッセージ / 構文・アサーション不足・**撮った画面に無い `#id`** =
  dry-run / 実挙動の確認 = デバイス実行)。**`#id` の実在照合は `ft_snapshot` が貯める台帳**が
  供給源(`SelectorInventory`。撮っていない画面については黙る = 誤検知を出さない側に倒す)
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

拡張の UI 文字列は日英切替対応(設定 `fleetest.language`: auto/ja/en、auto は VSCode 表示言語に追従。モニター「設定」タブからも変更可)。UI 文字列を追加/変更するとき:

- 辞書は `src/i18n/strings/<namespace>.ts` に `{ "ns.key": { ja, en } } satisfies MessageDict`。**ja は表示文字列と byte 一致**(未初期化時の既定 locale が "ja"・既存テストが日本語をアサートするため)。プレースホルダは名前付き `{name}` で ja/en 同集合。namespace とファイルは1対1。
- 拡張側: `import { t } from "./i18n"`(`MessageKey` 型で typo を tsc 検出)。activate 冒頭で `initI18n()`。webview 側: `import { t } from '../i18n.js'`(locale は `<html lang>` 経由)。静的 HTML(monitorHtml.ts 等)は拡張側 `t()` で描画する。
- **罠**: 拡張と webview の**両バンドルに入る .ts**(runReducer.ts/runLaneModel.ts 等。webview の import 連鎖で混入)は、vscode を引き込む `i18n/index.ts` を import できない(webview ビルドが壊れる)。vscode 非依存の別ランタイム `src/i18n/strings/lane.ts`(`tLane`/`setLaneLocale`、locale は両バンドルが注入)を使う。両バンドル共有の文字列を新たに i18n 化するときも同じ制約。
- **module-level の表示 const 禁止**(import 時=initI18n 前に "ja" で固定される)。関数化する(例 livePanelHtml.ts の `livePanelTitle()`)。
- package.json の contributes(コマンド名・設定説明)だけは別系統: `%key%` + `package.nls.json`(英)/`package.nls.ja.json`(日)で **VSCode 表示言語連動**(fleetest.language ではない)。両 nls はキー集合一致。
- 検証は `test/i18n.test.mjs`(辞書パリティ・**残存日本語の AST 走査**[HTML コメントは除外]・webview/lane キー存在・nls 整合)。正当に日本語を残す文字列(非表示の内部 throw 等)は同ファイルの `RESIDUAL_ALLOWLIST` に登録。
- `fleetest.language` 変更は各 webview パネル(Monitor/Live/Dashboard/HealReview)の `relocalize()` が
  `webview.html` を再代入して即時反映する(`extension.ts` が呼ぶ `languageChangeHandler.ts` の
  `handleLanguageChange` が束ねる。vscode 非依存に切り出してあるのはテストのため。パネル未生成時は
  no-op)。Monitor/Live は html 再代入(webview 再読込)でブラウザ側デコーダが失われるため、直後に
  `restartAllStreams()`/`restartStream()` でライブ配信を新キーフレームから張り直す。
  Reload Window が必要なのは package.nls(コマンド名・設定説明。VSCode 表示言語連動で
  `fleetest.language` とは無関係)だけ。

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

**用語(陽性/陰性)**: **「陽性/陰性」は検知の語彙**(発火したかどうか)で、**判定の結果(緑/赤)には
使わない**。occlusion-guard だけが「発火すると赤になる検知」なので、同じ事象を検知として語るか
判定として語るかで極性が反転し、`偽陽性` の一語が両側に跨っていた。使う語は5つ ——
**真陽性**(検知が正しく発火)/ **誤検知**(検知が誤って発火)/ **見逃し**(発火すべきなのにしなかった。
幾何の原理的限界は「取りこぼし」)/ **誤った緑・誤った赤**(判定そのものの誤り)/
**誤反転**(occlusion-guard が可視な要素を反転)。**`偽陽性`・`偽陰性` は書かない**
(`VocabularyPolarityTests` がソース走査で落とす)。**陽性対照**は1語の固有名詞として残す
(単独の「陽性」は書かない)。**例外は `falsePositiveCheck` の名前だけ** —— 受け手のプロファイル
JSON の鍵なので改名せず、ラベルとしての「偽陽性検証/偽陽性チェック」も据え置く(意味は
「誤った緑の検査」)。**走査は受け手向けの面(docs/user-docs/・拡張の i18n 文字列)も含む** ——
どちらも対の英語があるので、直すときは ja/en を同時に直す。**対象外は TestProjects/(ユーザー資産)と
reports/(.gitignore 済み。Apple へ提出済みの資料)だけ** → maintainer-notes §11
