# fleetest mobile

## 読者の分岐(最初に判定する)

- **このツールを「使う」だけ**(自分のアプリのシナリオを書いて実行したい。ツール本体は改造しない):
  `/fleetest-setup` スキルに従ってセットアップする。手順の全体像は docs/user-docs/getting-started_ja.md。
  **以下の保守者向けルール(委譲方針・コメント規約・i18n・ソース分割等)は適用しない。**
- **このツール本体を「改造する」保守者**: 以下すべてが適用対象。

## ドキュメント

- **利用者向けドキュメント(Shirates 流の en/ja 対)は docs/user-docs/**(入口は `index.md` / `index_ja.md`。1ページ = `<name>.md`(英)+ `<name>_ja.md`(日)で**片方だけ変えない**。`userDocsIntegrity.test.mjs` が対の欠落・切れたリンク・言語の混線・index 未掲載を検出)。DSL の挙動を変えたら docs/commands.md と併せて該当ページも直す
- 受け手向けの導入(事前準備・インストール・更新・アンインストールだけ。使い方は docs/user-docs とスキル): docs/user-docs/getting-started_ja.md
- 受け手の状態判定: `Scripts/preflight.sh`(読み取りのみ。既定モードは引数なしでカレントを見て
  ready=0 / installed=2 / blocked=1 を返す。SKILL.md ステップ0・0.5 と 1:1)。
  **`--runner [--base <dir>]` はリモートランナー機としての判定**(ready=0 / needs-manual=2 /
  blocked=1。`fleetest remote setup` が scp して実行する)。**既定モードの出力は1バイトも変えない**
  (共通判定は関数に括り出して両モードから呼ぶ)。**判定を足すときは blocked/needs-manual の
  仕分けを間違えない** —— install.sh が自動導入するもの(xcodegen 等)を needs-manual にすると、
  `remote setup` が install.sh に到達できず「入れれば直るのに入れる工程まで進めない」で詰まる
- 受け手の一括導入: `Scripts/install.sh`(clone〜検証ゲートを冪等に実行)。**各手順は
  `.claude/skills/fleetest-setup/SKILL.md` のステップ番号と 1:1**(失敗時に「→ SKILL.md ステップ N」を
  出してエージェントを手作業手順へ戻す設計)。**片方だけ変えない** — 手順の追加・番号の変更は両方に入れる
  (`installStepSync.test.mjs` が「install.sh が指すステップが SKILL.md に実在するか」を検出)。
  **スキルからは curl 形で呼ぶ**(クローン側の Scripts/ は pull されるまで古く、新しい引数は
  「不明なオプション」で落ちる)。全出力は `<WORK_DIR>/.fleetest/install-<日時>.log` に残る。
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
  **毎回 `fleetest api ensure-settings` で Bash 許可リストを補修する**(init 経由だけだと
  `--skip-project` の更新で既存の受け手に永久に届かない)
- **エージェントは Claude Code と Codex の2つ**(規約位置の唯一の定義元は
  `Sources/FTCore/AgentIntegration.swift`。表と Codex 固有の罠は docs/design.md §15)。
  **runbook 本体(`.claude/skills/<name>/SKILL.md`)は複製しない** —— 各エージェントへは
  規約位置から正典を参照する薄いアダプタだけを置く(Codex は `.codex-plugin/plugin.json` +
  `.agents/plugins/marketplace.json` + `.agents/skills/<name>` のシンボリックリンク)。
  **正典を `.agents/skills/` へ移さない**: raw.githubusercontent はシンボリックリンクを
  **本文でなくリンク先の文字列**として返すので、`install-skill.sh` の curl が SKILL.md ではなく
  1行のパスを掴む。**シェル(install.sh / install-skill.sh)は clone 前・ビルド前に走るので
  Swift を呼べず、判定規則を手で持つ** —— 片方だけ変えない(`agentIntegration.test.mjs` が
  ドリフトを、`agentAdapters.test.mjs` がアダプタの到達性を落とす)。
  **SKILL.md に特定エージェント専用機能を前提として書かない**(`AskUserQuestion` は
  「選択ダイアログ(Claude Code なら AskUserQuestion)」の形で、実装ではなく意図を書く)。
  **Codex のサンドボックスはシェルだけを縛る**(2026-08-27 実測)—— **MCP サーバはその外**で動くので
  `ft_*` は既定設定のまま全部動く。通らないのは**シェル経由の導入・更新**だけで、
  原因は権限ではなく **①SwiftPM が `sandbox-exec` を入れ子に使う(`swift build` が起動できない)
  ②`simctl` が CoreSimulatorService へ届かない**。**`network_access` / `writable_roots` では直らない**
  ので、それらを根拠に OK を返してはいけない(以前 false green を出していた)。
  install.sh ステップ7.7 と preflight の `codex_sandbox=` は**判定と2択の案内だけ**を出す
  (a: 導入・更新のセッションだけ `codex --sandbox danger-full-access` / b: 恒久緩和)。
  受け手のグローバル設定 = セキュリティ境界なので1バイトも書かない。
  **「貼り付け用ブロック」として出さない** —— TOML は同じキー・テーブルの重複を許さず、
  素朴に追記させると config.toml 全体を無効にする。
  **`codex plugin add` は作業ツリーを丸ごとコピーする**(実測で 11GB。`.build/` 込み)。
  Claude Code のローカル marketplace add と同じ罠**プロジェクトスコープの `.codex/config.toml` も使わない**
  (trusted なプロジェクトでしか読まれず、書いても黙って効かない状態を作れる)
- MCP サーバの起動口: `Scripts/mcp-server.sh`(`.mcp.json` はこれを exec するだけ)。
  **`.mcp.json` をリポジトリに置かない**(2026-08-27。追跡外・`.gitignore` 済み)——
  **プラグイン root = repo ルートなので、ルートの規約ファイルはプラグインに載って配られる**。
  同梱していた `.mcp.json` は `$PWD/Scripts/mcp-server.sh` 依存で、クローンの外で
  エージェントを起動した受け手の MCP が必ず落ちていた(Codex は起動時に
  `connection closed`、Claude は `plugin details` に `MCP servers (1)`)。登録は構成を問わず
  install.sh が**絶対パス**で WORK_DIR へ書く。同型は `skills/`(スキルが二重登録された)——
  **ルートに何か置くときは「プラグインに載ってよいか」を必ず問う**。
  **シェル式を `.mcp.json` へ直書きしない** —— 起動のたびに no-op でも約8秒の `swift build` を払い、
  失敗すると `>/dev/null` で**理由が分からないまま起動しない**(2026-08-06 の外部フィードバック)。
  ランチャが守るのは3つ: **鮮度でだけ建てる**(`find Sources Package.swift -newer <bin>`。
  存在チェックに戻さない = InAppLauncher と同じ規律。建てた直後に `touch` するのは、
  無変更のソースを触っただけだと再リンクされず毎回建て直しになるため)/
  **stdout は JSON-RPC 専用**(診断は stderr・ビルド出力はログファイル)/
  **cwd を変えない**(cwd は受け手パッケージの特定に使う。ビルドはサブシェルで行う)
- 受け手の更新: `Scripts/update.sh`(install.sh を再実行 + project sync + プラグイン更新と版照合。
  `.claude/skills/fleetest-update/SKILL.md` と 1:1)。**先に update-check.sh を呼び up-to-date なら
  即終了**(全工程は更新が無くても約30秒。入れ直しは `--force`)。**ログの場所は最後の
  「次にやること」にも出す**(install.sh には `--no-next-steps` を渡すため、こちらで案内しないと
  人が後から詳細を確認できない)。doctor は既定で出さない
  (`--doctor`。結果表と情報が重複し8秒かかる)。**スキルのステップ0は `.fleetest/state.json` の
  Read で TOOL_ROOT を採る**(コマンドを打たない = 承認が要らない。無ければ preflight に落ちる)
- 更新の有無だけ判定: `Scripts/update-check.sh`(読み取りのみ。**fetch せず `git ls-remote`** で
  upstream と比較し up-to-date=0 / update-available=3 / pinned=0 / unknown=1。取り込みはしない)。
  VSCode 拡張が起動時に1日1回呼ぶ(`src/updateCheck.ts`・設定 `fleetest.updateCheck`)。
  **手動コマンド `fleetest.checkForUpdate` は間隔・却下・設定 off を無視して必ず結果を返す**
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
  **機械可読な索引は `Sources/FTCore/CommandIndex.swift`**(`fleetest api dsl-commands` が出す。
  読者はコードを生成する側で、名前の存在確認に使う)。**コマンドを足す/消す/改名したら索引も直す**
  (`CommandIndexSyncTests` が Commands.swift / CommandsVerify.swift / CommandsAppControl.swift / ValueAssertions.swift / FTElement と突き合わせる)。
  **置いていない名前は `Sources/FTDSL/UnavailableCommands.swift` で受け止める**(他ツールの名前・
  対称性から実在すると誤解される別名。`cannot find in scope` の代わりに正しい書き方を出す)
- Shirates(Classic)との対応表(何が揃っていて何を持たないか・意図的に持たないものの理由・
  OS で挙動が割れるもの・足す価値がある残り): docs/shirates-parity.md。
  **コマンドを足す/名前を変えるときは必ずここも更新する**(準拠漏れの一覧を含む)
- MCP 監査ラウンドの回し方(**1ラウンド = 初見の「形」1つ**。**アプリ名は軸ではない** ——
  軸①画面の形 / 軸②セッションの形の2本立て・拾ったものを**バグ / 自作機構の欠陥 / 言い回し**の
  3つに分ける規律・**増設と検分は交互**・停止規則・台帳): docs/mcp-audit-rounds.md。
  **地図の反復監査は 2026-08-12 に閉じた**。2026-08-13 に軸を「アプリ」から「形」へ直した ——
  アプリで数えていたためにブラウザ6ラウンドが全部「天気」(うち5回は同じ格子)になり、
  **直近の実バグの 3/4 が前のラウンドで自分が入れた注記の手直し**になっていたのを台帳が
  検出できなかった。**天気サイトはもう足さない**
- MCP の使い勝手の計測(**まっさらなエージェントがタスクを終えられたか・何手かかったか**。
  注記の A/B の回し方と判定の規律): Bench/README.md(`Scripts/mcp-bench.sh`)。
  **実 web ページの形も盤面で測れる**(`Bench/boards/` に実ブラウザ用の HTML を置き、
  ホストで配信して Chrome から引く。**ライブの web は叩かない** = 盤面が毎日変わると
  手数の差が注記の効果と混ざる)。ただし 2026-08-13 の A/B で**手数は注記の有無で動かない**
  ことが分かっており(代替手段の無い盤面でも 5/5 完了。measurements.md)、**足す/消すの
  判断材料は note B(実現バイト)**。`NoteBudgetTests` の**本数と鍵の集合の等号固定**は
  引き続き効かせる(予算を動かすには根拠を台帳へ書く)
- CI 連携(`fleetest run --junit` の JUnit 出力・GitHub Actions 例・flaky 方針): docs/ci.md
- **結果 JSON のスキーマ**(run.json / scenarios/*.json の全欄と、落ちた run の仕分けレシピ):
  docs/results-json.md(**唯一の定義元**。`results/` は .gitignore なので**その中に README を置いても
  受け手に届かない** —— 2026-08-20 まで design.md がそこを指していた)。
  **失敗の記録に置くのは事実だけ** —— フェーズ(`section`)・コマンド名(`command`)・
  経路(`failureKind`)・注記(`notes`)。**「環境要因の失敗」という分類は置かない**
  (アプリが重いのかマシンが混んでいるのかツールには区別できず、推測は誤った緑・赤を作る。
  2026-08-20 受け手方針)。**言えないときは欄ごと省く**(「その他」に丸めない)。
  `command` を description から切り出さない・`failureKind` をエラー文言の一致で決めない
  (どちらも書式を変えた瞬間に静かに壊れる。仕分けは `DriverError` の case で行う)。
  渡し忘れはコンパイルも実行も通るので `CommandNamePlumbingTests` がソース走査で落とす。
  **`tap` は対象が操作可能になるまで待ってから撃つ**(2026-08-21 ユーザー決定
  「待って、それでも無効なら撃つ」)。要素は木に居るのに触れない画面(読み込み中のフォーム)が
  実アプリで頻出し、空振りは後段のアサーションでしか分からなかった。**待ち切れなくても撃つ**
  = 無効な要素をわざと叩く書き方を壊さない。`&&enabled=` 明示のセレクタでは待たない。
  witness は `E2EAppAndroid` の `#btn_enables_late`(1.5 秒後に有効)。
  **`tap(入力欄)` → `type("文字列")`(Shirates 伝統形)は支えるべき書き方**(2026-08-21 ユーザー指示)——
  容器を叩いて焦点が立たなかったときは `InputFocusRescue` が入力欄を名指しして入れ直す
  (払うのはタップ直後の木1枚だけ・入れ先が一意に決まらなければ何もしない・注記
  `type-focus-recovered` に残す)。**witness は `E2EAppAndroid` の `#field_wrapped`**
  (容器に id・中身の EditText に id 無し・透明な clickable がタッチを吸う)。
  **割り込みの自動クローズは止められる**(2026-08-21。Shirates 準拠で4つ):
  `suppressHandler { }` / `useHandler { }`(ブロック形。出口で必ず戻る)と
  `disableHandler()` / `enableHandler()`(**CAE のブロックを跨げる唯一の形**。
  ブロック形は1つの CAE ブロックの内側にしか置けない ← 2026-08-21 ユーザー指摘で採用)。
  **止まるのはツールが閉じることだけ**で、割り込みが出ること自体は変わらない。
  **抑止したまま落ちたときだけ**注記に出す(危険は「抑止したまま忘れる」)。
  witness は `TestProjects/E2E-iOS/scenarios/15_別ウィンドウのモーダル.swift` の S0050。
  **割り込みに吸われた操作は撃ち直さない**(届いていた場合に二重実行 = 送信・購入で取り返しが
  つかない)。ツールが閉じるのは**ステップ開始時点で出ている割り込み**までで、閉じた後は
  整定を待って木を取り直す。**間に湧いた分の復帰はシナリオ側**(docs/commands.md
  §割り込みが「操作を吸った」ときの扱い)。**自動リトライを再提案しない**
- リリース(git タグ発行。**受け手の配布口は main の1本**で版固定の導線は案内しない。
  `FLEETEST_REF` は保守者のブランチ検証口): docs/releasing.md(`Scripts/release.sh`)
- **リモートのデバイスの監視と配信**(2026-08-17): 手元の `api monitor` は simctl/adb =
  **この機械しか観測できない**。別の機械のぶんは `RemoteMonitorFanout` が
  `remote exec <host> -- api monitor --device-machine local` を1本ずつ立てて合流させ、
  ライブ映像は**1デバイス = 1本の ssh**(`api device-stream` が向こうで宛先を解決し配信
  ヘルパーへ `execv` で化ける = stdout のバイト列が手元起動時と同一なので `StreamPipeline` を
  そのまま使える)。**多重化の枠は作らない**(却下理由は docs/remote-runner.md §13)。
  守る規律3つ: **①他の機械の台を走査しない**(同名の手元の台に解決して別の機械の状態と画面を出す。
  仕分けは `ApiMonitorCommand.scope` が pure に持つ)/ **②観測していない台は `state:"unknown"`**
  —— offline(止まっている)と別の値にする(同じにすると向こうで動いていても止まって見える。
  拡張の `MonitorDeviceState` と対)/ **③配信が張れなければポーリングへ落ちる**(monitorFrame は
  止めていないので、配信を止めるだけでフォールバックが成立する)。
  **版が揃っていないと状態も映像も来ない**(`--device-machine` は新しいので旧バイナリは即死 →
  3回で諦め)。**操作も同じ規律** —— 一括だけでなく**タイル1枚の起動・停止もその機械へ回す**
  (手元で `api device-up --name` を撃つと、同名の台が別の機械にも居るとき
  **別の機械の設定でこの Mac にシミュレータが1台できる**。`findDevice` は (machine, name) で引き、
  `--device-machine` の既定は手元)。**自動修復(watchdog)はリモートの台を見ない**
  (修復手段が手元にしか効かず、記録が name 単位なので同名の台と混線する)
- **用語(2026-08-26 ユーザー決定。全体で一貫させる)**: **host = ホスト名 / IP**(ネットワークの実体)、
  **machine = その host に対するローカルエイリアス**(この Mac の登録簿だけが知る名前)。
  定義と3つの規律(①エイリアスをリモートへ出さない ②記録の鍵は host ③プロファイルに ssh 実体を
  書かない)は docs/remote-runner.md §0。**エイリアスは頻繁に変わりうるので記録・登録の鍵に
  しない**(例外はその machine 自身に関する構成 = 登録簿とプロファイルのデバイス割り当て)。
  JSON キーはプロファイル `devices[].machine`・登録簿 `machine`・記録 `host`(旧キーはすべて読める)。
  **拡張 ⇄ webview のメッセージと CLI ⇄ 拡張のワイヤも `machine`**(2026-08-26。`api monitor` の
  `machineHost`・`api devices-up` の `host`・`api remote-compat` の `hosts[].name` を改名し
  **ProtocolVersion 9**。こちらは同時に配布されるので旧キーは読まない = **片側だけ改名すると
  黙って壊れる**。実際 webview だけ旧キーのまま残り、実行プロファイルのリモート参照が
  `machine: "local"` へ書き換わった。型検査の効かない webview 境界は往復テストで縛る)。
  リモートへ送るプロファイルは `FTCore.RunnerProfileView` が「そのランナーから見た姿」へ畳む
  (自分の台は `machine: "local"`・他機の台は削除)ので、**転送物にも引数にもエイリアスは出ない**
- リモート実行(`run --machine` / `--host` の SSH ディスパッチ): **ssh 越しに何かを起動する経路を新設したら
  非対話 PATH の補正(`/opt/homebrew:/usr/local/bin`)を必ず写す**(既存は `RemoteShell.remoteRunCommand`。
  写し漏れで「入っているのに brew が無い」と落ちた実害)。**子プロセスを spawn する経路を足したら
  中断のリレーも足す**(`InterruptRelay`)—— **親を殺しても子は死なない**ので、ssh が生き残って
  リモートが走り続け、`dispatch.lock` も残る(2026-08-18 実測)。**SIGKILL へのエスカレートは
  ssh にだけ**(自分の子に掛けるとロック解放と終了スクリプトを飛ばす)。**シグナルソースは
  1プロセスに1組**(2026-08-24)—— relay ごとに立てて `stop()` で SIG_DFL を戻すと、並行する子の
  うち先に終わったものの stop() が残りの横取りまで解き、`kill -INT` で親だけ死ぬ(受け手報告)。
  `fleetest remote unlock` は自分の死んだディスパッチのロックだけを外す(`RemoteDispatchUnlock`)。
  **`--machine M`(旧 `--host`)+ 明示 `--device` は M の台に限定**(`RemoteDispatchExplicitDeviceScope`。同名の台が
  複数機にあると名前だけでは全機ぶんを拾う)。**`--machine local` も同じ判定を通す**(2026-08-24。
  run / api run の2経路 —— 絞らないと別ホストのエントリの UDID を手元で探して
  `no simulator with that UDID` で止まる。受け手報告)。
  **LPT はリモートでも実績で回る**(2026-08-18): 実績 JSON は on-demand でも常に回収・
  実績と観測窓は machine 別(platform 分離と同型)・フリート割り当ては facts キャッシュ
  (`.fleetest/remote-hosts/<host>.json`。ディスパッチのたびに machine と固定費実測を書く)で
  機械別に見積もる(実測は docs/performance-tuning.md §3.7)。**facts の machine 採取は
  relink より前** —— relink が reportPath を書き換えると stamp がファイルから消え、stamp 走査が
  空振りする(実ディスパッチで machine 欠落を確認)。**回収後の後処理を足すときは、後段の走査が
  stamp に依存していないかを見る**。設計・却下案・セキュリティ前提は docs/remote-runner.md /
  **利用者向けの導入手順は docs/remote-runner-setup.md**(ランナー機の前提・install.sh の呼び方・
  版の揃え方・トラブルシュート)/ **エージェント向けは `.claude/skills/fleetest-remote-setup/SKILL.md`**
  (機械作業は `fleetest remote setup` に委ね、聞くこと・人手へ渡すこと・結果の読み方だけを持つ。
  トラブル表は頻出3件だけで、詳細は docs を参照させる = 二重管理にしない)。
  **片方だけ変えない** —— 手順に影響する変更(レイアウト・併用不可オプション・適合チェックの項目)は
  docs とスキルの両方に入れる。**スキルを増やしたら `Scripts/install-skill.sh` の `SKILLS` と
  `.agents/skills/<name>` のシンボリックリンクを足す**(前者は clone より前に走るので導出できず、
  **手書きの一覧はここだけ**。`update.sh` は TOOL_ROOT の正典から導出するので触らなくてよい。
  後者は **Codex の repo ローカル発見の実体** —— `.codex-plugin/plugin.json` だけでは効かない[実測])
- **リモート制御(実行プロファイルの `remoteControl`。旧 `fileSync`)**: ワークスペース(資材の
  置き場。ステージングと転送)+ **run 前後のスクリプト**(依存 DB・スタブサーバの起動と片付け。
  docs/remote-runner.md §17)。**スクリプトに宣言は無い** —— `<workspace>/scripts/setup.sh` /
  `teardown.sh` が**あれば実行、無ければ何もしない**(名前も置き場所も固定。拡張のフォームにも
  入力欄を置かない = 2026-08-18 ユーザー決定)。**呼ぶのは `ProfileRunner.run` と
  `ApiRunCommand` の2箇所** —— リモートの子は `fleetest run --host local` として向こうで同じ
  コードを通るので `RemoteRunDispatcher` には足さない(手元とリモートで実装を割らない)。
  守る規律3つ: **①setup の失敗は run を止める**(インフラ起因。シナリオ0本)/
  **teardown の失敗は結果を変えない** / **②デバイスに触る前に撃つ**(渡すデバイス一覧は
  絞り込み後のもの)/ **③片付けは defer だけに頼らない** —— setup の前に
  `.fleetest/hooks/<pid>.json` を置き、次の run 開始時と `fleetest hooks reap`(`remote clean` が
  撃つ)が死んだ pid のぶんを代わりに実行する(**生存判定は pid だけ。mtime を見ない** =
  数十分の run を「古い」と誤判定して動いている DB を落とさない)。
  **転送から外すのは `.fleetest-transfer-ignore`**(2026-08-23。転送対象ツリーのどこにでも置ける・
  rsync の `--exclude` 書式・置いたディレクトリ起点。`FTCore.TransferIgnore`)。**rsync の `-F`
  (dir-merge)は使わない** —— macOS の openrsync では dir-merge が `--delete` から受け側を守らず、
  ランナー機の台帳が消える(実験で確認)。**3つの転送(run ディスパッチ・fan-out の
  `RemoteProjectSync`・プロジェクト外ミラー)が同じ走査を通る**(`rsyncArgs` の `ignore:` は
  既定値無し = 読み忘れはコンパイルで止まる)
- 設計書(アーキテクチャ・Swift DSL 仕様・セレクタ記法・プロファイル): docs/design.md
- 性能チューニング(調整ノブ・不採用施策と再検討条件・計測手順): docs/performance-tuning.md
- 検証の詳細(flake/性能の判定規律・ベータ整合・全滅時の切り分け・e2e.sh のオプション): docs/verification.md
- fleetest 自身の E2E: **UI フレームワークごとに SUT が5つ**ある(画面・`#id`・ラベルは全 SUT 共通契約):

  | SUT | 実装 | プロジェクト | 対象 OS |
  |---|---|---|---|
  | `E2EAppCMP/` | Compose Multiplatform | TestProjects/E2E-CMP | ios + android |
  | `E2EAppIOS/` | SwiftUI + 一部 UIKit | TestProjects/E2E-iOS | ios |
  | `E2EAppAndroid/` | View/XML + 一部 Compose | TestProjects/E2E-Android | android |
  | `E2EAppFlutter/` | Flutter | TestProjects/E2E-Flutter | ios + android |
  | `E2EAppRN/` | React Native | TestProjects/E2E-RN | ios + android |

  **iOS だけが持つ witness**: `E2EAppIOS/Sources/UI/OverlayWindow.swift` = **キーウィンドウに
  しない別 UIWindow のモーダル**(全画面 / 上部バナーの2形)と、診断画面の `#btn_request_photos`
  = **OS(SpringBoard)の権限アラートがアプリを覆う形**(別プロセスなので in-app の木に載らない。
  緑の回帰は `scenarios/16_システムアラート.swift`・**陽性対照は `_disabled/94_システムアラート.swift`**)。覆い・別ウィンドウに関わる変更は
  `TestProjects/E2E-iOS/scenarios/15_別ウィンドウのモーダル.swift` の4本で対照を取る(docs/verification.md)。
  **4本目は条件判定**(`ifCanSelect`)—— **perform を通らないので操作・検証を直しても守られない**

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
  配送された)。`Tests/FleetestTests/DeepLinkSchemeSyncTests.swift` が契約表との一致と
  SUT 間の重複を検出する

## ビルド・検証

**検証の詳細な罠と判定規律(flake/性能の判定・macOS/Xcode ベータ整合・常駐プロセス掃除・
「Application is not running」全滅時の切り分け・`Scripts/e2e.sh` の各オプション)は docs/verification.md**。
以下は毎回効く最重要ゲートだけ。

- 拡張: `cd vscode-fleetest && npm run compile`(esbuild+tsc)/ `npm test`。挙動を変えたら
  **`npm version --no-git-tag-version <新版>` で版を上げて** `npm run install-local`
  (反映は VSCode の Reload Window **+パネル開き直し**。Reload だけでは効かないことがある。code CLI は PATH に無い)。
  **package.json だけ手で書き換えない** — lock も version を内包しており、放置すると受け手の
  `npm install` が lock を書き換えてクローンが dirty になり、**次の更新が pull ガードで止まる**
  (実害。`packageLockSync.test.mjs` が検出。既にズレたら `npm install --package-lock-only`)。
  **jsdom を使う webview テストは `t.after(() => window.close())` で必ず閉じる** ——
  `pretendToBeVisual` の rAF と `main.js` の `setInterval` が残るとプロセスが終了せず、
  `node --test` はファイル単位の子プロセスの終了を待つので**1本の閉じ忘れでスイート全体が
  止まる**(2026-08-17 の実害: 10本中1本の漏れで `npm test` が終わらなくなった。個々のテストは
  1〜2秒で、遅いテストは1つも無かった)。二重に塞いである: `jsdomTeardown.test.mjs` が
  閉じ忘れをソース走査で落とし(**コメント中の `window.close()` を実装と数えない** ——
  規律はコメントで説明されているので素の一致だと素通しする)、`npm test` は
  **`--test-force-exit`** を付けて漏れがあっても止まらないようにしてある。
  **同型: `argumentHelpLiteral.test.mjs`**(`ArgumentHelp` は文字列リテラルからしか作れないので
  `help: "…" + "…"` はコンパイルが通らない。4回踏んだ)。**Swift 側の「コンパイルで落ちる誤り」や
  「テストが終わらない」型は、swift build/npm test を1回払うまで気付けないので、ソース走査で
  秒未満に落とす**
- Swift: **`swift test --parallel` だけでよい**(実測 127s → 34s。直列も緑のままだが、毎回の待ちが4倍違う)。
  **前に `swift build --build-tests` を打たない** —— `swift test` が同じビルドをやり直すので
  **無変更でも 12.3 秒を二重に払う**(実測: build 12.3s + test 37.9s = 50.2s / test 単独 37.9s)。
  **5 SUT のシナリオも `swift test` で型チェックされる**(実験で確認: シナリオを1行壊すと
  `swift test` が落ちる)ので、DSL の改名・シグネチャ変更の追随漏れもこれで捕まる。
  別途ビルドが要るのは**変異テストの直後に製品バイナリを作り直すとき**だけ
  (`swift build --product <名>`)。
  **合否は exit code で見る**(パイプすると grep 等の exit code に化けて失敗を握りつぶす実害)。
  **並列はテストプロセスを分けるので、ホストの共有資源に触るテストは自分で隔離する** ——
  既定のパスを直接見に行くと、無関係なテストの後始末と競合して落ちる(2026-08-10 に `FMBreaker` で実際に発生。
  状態ファイルがホスト単位なのは仕様なので、**テスト側が差し替え口でプロセスごとの一時パスへ逃がす**。
  「どこに置くか」は I/O 抜きで別に表明する)。同型は `.fleetest/` の台帳・`DiagnosticReports` の走査・simctl/adb
  を呼ぶテスト。**隔離できないホストの実体**(simctl/adb・起動中の Simulator/Emulator・固定パス)は
  `Sources/FTTestSupport/SharedResource.swift` の `SharedResource.<key>.locked { }` で資源キーごとに
  直列化する(隔離が使えないときの下位の手段。詳細は docs/verification.md)
- **`fleetest bridge down --all` を頻繁に打たない**(2026-08-11 指示)。1回ごとに XCUITest ランナーの
  `xcodebuild` が全台ぶん走り、他セッションや監視が使う端末も巻き添えにする。**打たずに済む順序で組む**:
  **①ブリッジに触る編集を全部終えてから版を1回だけ上げる**(小刻みに上げると毎回全台の再構築)/
  **②建て直しは使う端末だけ**(`bridge down --port <N>`。1シナリオの確認なら台数上限で2台しか要らない)/
  **③版ガードに弾かせる**(古いブリッジは「the bridge is OLDER than this build」で明示的に落ちるので、
  予防的に全台を落とさず**弾かれたポートだけ**建て直す)/
  **④建て直しの要らない段から検証する**(単体テスト → dry-run → 生きているブリッジ1台での MCP 確認 →
  最後にデバイス実行)。**ワイヤ形式(DTO の enum・フィールド)を変えたら必ず版を上げる** ——
  上げないと「同じ版なのに非互換」なランナーが残り、400 で落ちて原因が分からなくなる(2026-08-11 に実際に踏んだ)
- **1シナリオの確認にフリート全台を用意しない**。`ProfileRunner` は回す本数から台数を絞る
  (`ResolvedProfile.deviceKeepCount` = 本数 + 予備1台)。実測で iOS の1本実行が 21.8s → 9.3s
  (固定費 14.8s → 2.9s)。**予備1台は必須**(用意した台が blank/frozen で弾かれると run ごと落ちる)。
  **例外は `--broadcast`(ブロードキャスト。2026-08-22)** —— 各台で1回ずつ回すのが目的なので
  絞らない(分配だけ `ScenarioDispatch.broadcast` に差し替え、他は同じ経路。docs/design.md)。
  `fleetest api run`(拡張の並列経路)は**シナリオ一覧をビルドと並行に解決する**ので一覧を待てない ——
  確定している `--scenario` の指定だけで判断する(`ApiRun.exactScenarioCount`。
  明示 ID は1つにつき高々1本なので合計を上限に使え、クラス名指定・全件は絞らない)
- **E2E 実行中に `swift build` / `swift test` を打たない**(2026-08-15 の実害)。同じ `.build` を
  共有するので、**実行中の `fleetest` バイナリが差し替わってプロセスが SIGKILL される**
  (`Killed: 9`)。フル E2E の最中に単体テストを回したところ、3プロファイルが同時刻の連番 PID で
  落ち、**テストの失敗に見える形で赤くなった**(実際は1本も走っていない)。
  見分け方は `Scripts/e2e.sh: line NNN: <pid> Killed: 9` と、シナリオ0本での即死。
  **待つ間に手を動かしたくなる場面ほど踏む**ので、E2E を投げたらビルドを伴う作業は止める
- **モニターを止めるのは性能を測るときだけ**(2026-08-21 ユーザー決定で運用変更。
  以前は「E2E の前に必ず止める」だった)。止めている間の利便性の損失が大きいという判断で、
  **合否を見るだけの実行では止めない**。問題が出たらそのとき見直す。
  **止めるのは `fleetest monitor pause [--for <分>]` / 再開は `resume`**(2026-08-24 追加。
  kill では止まらない —— 拡張が monitor も配信ヘルパーも数秒で再起動する。保持ファイルを
  `api monitor` が毎周期見て観測を止め、全タイルを unknown で出す = 拡張が配信を畳む。
  効くのはこの機械だけ。docs/verification.md §モニターと E2E)。拡張が動いていないときの
  旧手段は pkill 3連打(`fleetest api monitor` / `fleetest-androidstream` /
  `screenrecord --output-format=h264` —— 1つ目だけだと配信が台数ぶん残る)。
  **中途半端に止めた対照は誤った結論を出す**(観測だけ止めて残った失敗を「特定の個体の問題」と
  報告したが、実際はその台の配信が生きていただけだった)。
  **捨ててはいけない実測**(2026-08-13 の3条件対照): 8台すべてに配信を張った状態のフル E2E は
  Android が**実際に赤になった**(3/4 プロファイル失敗・接続断11件 → 完全停止で 4/4・接続断0)。
  遅くなるだけでなく**落ちる**ことがある、という事実は残る。**赤が出たら真っ先に
  配信の有無を疑う**(判定材料: run.json の `workerAnomalies` に `degraded` / `requeued` が
  出ているか。デバイス消失・ブリッジ到達不能はこの壊れ方の署名)。詳細は docs/verification.md
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
  セレクタ/スナップショット/ヒール(`FTFoundationModels`)を変えたら `Scripts/e2e.sh`**(ユニットテストはデバイス
  境界のバグを1つも捕まえない)。**ブリッジのスナップショット/型写像と、StepExecutor の
  操作合成(タップ/ドラッグ/スクロール探索の終端処理)を触ったら SUT を絞らず全部**回す
  (フレームワーク差の退行は SUT を跨がないと出ない。実害: 探索終端の空打ちドラッグは CMP では
  無害・SwiftUI ではタブバーが反応し、E2E-iOS を回すまで 5/5 の回帰に気付けなかった)。
  **既定の e2e.sh は iOS を in-app エンジンで回す**(2026-08-11 に xcuitest から反転。
  **利用者の既定エンジンは hybrid = in-app 優先**なので、既定スイートが見るべきはそちら)。
  **フル E2E は引数なしの `Scripts/e2e.sh` だけ**(2026-08-11 指示。xcuitest は含めない)。
  **XCUITest ブリッジを触ったときだけ `--ios-xcuitest` を的を絞って回す**。エンジン指定(`--ios-inapp` /
  `--ios-xcuitest`)は **iOS だけを回す**(Android にエンジンの選択肢は無いので既定スイートと
  同一の実行を二度払うだけ。2026-08-11 実測で 244 秒の純粋な重複)。OS の絞り込みは
  `--ios` / `--android`。詳細は docs/verification.md。
  **この漏れは e2e.sh が検出する**(2026-08-10)—— **回さなかった側**のブリッジ入力集合
  (`BridgeSourceSet`)の digest を、そのエンジンの実行が**全部成功したときだけ**
  `.fleetest/<engine>-e2e-verified` に記録し、開始時と終了時に食い違いを警告する
  (`fleetest api bridge-sources --set inapp|xcuitest --digest`。一覧は BridgeSourceSet が唯一の定義元)。
  **落とさず警告だけ**(検知は警告から始める)。実害: in-app/xcuitest 両方のスナップショット生成を
  変えた回の E2E 254 本が全部 engine=xcuitest で、in-app 側は1度も動かないまま緑になった
- **e2e の実行範囲はリスクとコストで決める**(上のゲートは「最低限ここまでは回す」の下限で、
  常に全部回す意味ではない。フルスイートは10分超かかるので、**何も足さない実行はしない**):

  | 変更の性質 | 範囲 |
  |---|---|
  | 改名・シグネチャ変更・型に閉じたリファクタ | **`swift test --parallel` だけ**。追随漏れは必ずコンパイルエラーになる(5 SUT のシナリオも Package のターゲットなので型チェックされる。実験で確認済み) |
  | ホスト側ロジック(`StepExecutor` の分岐・セレクタ解決) | `swift test` + **該当シナリオ1〜2本** |
  | ブリッジの挙動(注入・スナップショット・型写像) | 該当 SUT の**1プロファイル**。フレームワーク差が絡むなら全 SUT(上のゲート) |
  | 入力・キー・IME 系 | 上記 + **`--ios-xcuitest`**(既定は in-app なので、もう片方のエンジン) |
  | flake 調査・性能 | 該当プロファイルを**反復10周**(docs/verification.md) |
  | run 制御(再キュー・ワーカー離脱など。シナリオ実行の中身を触らない) | `swift test` + **その経路を強制的に通す陽性対照**。緑の run では1度も実行されないのでフルは情報ゼロ |
  | リリース前・大きな統合の締め | **フルスイート = `Scripts/e2e.sh`(引数なし)だけ**。xcuitest は含めない(2026-08-11 指示) |

  **回す前に「それで何が検証できるか」を言えること**(2026-08-06 指示。惰性で回して指摘された)。
  判定はひとつ —— **その変更は緑の run で1度でも実行されるか**。実行されないなら、
  フルは 10 分を捨てるだけで、代わりに要るのは**経路を強制的に通す陽性対照**。

- **受け手が受け取る経路も一度は通す**(2026-08-07 の実害)。9コミット積んだ後で
  `Scripts/update.sh` を実際に走らせたら、**2回目以降の更新が必ず失敗する**欠陥が出た。
  3ラウンドの実アプリ監査でも単体テストでも1度も出ていない ——
  **コードの正しさと、それが受け手へ届くことは別に確かめる**
- **flake の修正は1回グリーンで判定しない・単発の観測で性能を断じない**(反復+負荷で叩く。実害と
  手順は docs/verification.md)
- **「読む回数を減らす」最適化は、その読みが担っている砦を先に列挙する**(2026-08-12)。
  MCP の `ft_scroll_to` が 0 スワイプでも木を2回読むのを1回にしたら、
  **既存の回帰テスト2本が落ちて「2枚目を読むこと自体がガード」だと分かった**
  (返す木 = 照合した木にすると、対象の消失も画面外への移動も定義上検出できなくなる)。
  節約できるのは**誰も見ていない読み**だけ。省く前に「この読みの結果を何が見ているか」を
  grep で数え、**ガードなら速さと引き換えにしない**(実装は撤回。詳細は docs/design.md)
- **単体テストが緑でも実データで1回動かすまで信用しない**。テストは書いた本人の前提を共有するので、
  前提が誤っていると実装とテストが同じ誤りを持ったまま緑になる(実害3件は docs/verification.md)
- **定数を置くときは根拠・単位・尽きたときの発話を書く**(2026-08-15 ユーザー方針
  「根拠のない定数は排除したい」)。書けないなら数字を調整するのではなく**数字への依存を消す**
  (観測可能な事象を待つ・デバイスの応答が要らない情報源から導く)。**片方の文脈で詰めた値を
  別の文脈へ流用しない** —— 読み手の予算・シミュレータの実測・pt で測った床は、読み手の
  いない経路・実機・px の木では**遅くなるのではなく黙って誤る**(4件の実例と直し方は
  docs/verification.md と記憶 context-blind-constants-20260815)。残す数字は名前を付けて
  1箇所に置く(いずれ実行プロファイルから指定できるようにする差し込み口になる)
- **陽性対照は pass/fail でなく出力の文言まで読む**。主張を含む文言(「天井でも足りない」等)は
  **主張が偽になる周回**が設計に残っていても単体テストでは緑のままになる(2026-08-15 に実際に
  嘘を出し、latch へ設計変更した。docs/verification.md)
- **失敗の帰属は「HEAD での対照」で決める**。変更の直後に出た失敗を、印象で自分のせいにも
  既存の問題にもしない(`git stash push -u` → HEAD で1シナリオ → `git stash pop`。3〜4分。
  docs/verification.md)
- **「差が出ない」ときは仮説より先に実験系を疑う**。差が出ないことは、**変更が無効だったこと**と
  **実験が無効だったこと**を区別しない。実行の実体は `fleetest` ではなく
  **`fleetest-scenarios-<project>` サブプロセス**なので、A/B で `fleetest` を差し替えても
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
  **逆向きも成り立つ ——「固定コーパスで0件」も自前 SUT の実画面を代表しない**(2026-08-15)。
  木の欠落検知(`TreeCoverage`)は 37 枚のコーパスで誤検知0だったのに、**フル E2E では
  5 SUT すべての緑の run で毎回発火**した(真陽性 —— `webview.html` は `aria-hidden` の
  見出しを持つこの検知の offline witness そのもの)。**「出ない」ことを設計の根拠にするなら、
  コーパスとデバイス実行の両方で確かめる**。とくに**注記を毎ステップの経路へ配線するとき**は、
  発火率がそのまま出力とレポートの雑音になるので、デバイス実行の実測でしか判断できない。
  **実アプリのスナップショットは `Tests/Fixtures/RealAppSnapshots/` に固定してあり、
  `SweepHarnessTests` が `swift test` で毎回当てる**(件数の基準値+タップ対象に対する
  警告率の上限)。**基準値を上げるのは増えた分を1件ずつ見て真陽性だと確かめてから** ——
  黙って上げるとこの砦は現状の追認装置になる。採り直しは `FT_SWEEP_BASELINE=1`
  (貼り付け用の1行と、何が発火したかの明細が出る)
- **新しいテストは「破ったら落ちる」ことを1回確かめる**。変異は **`Scripts/mutation-check.sh` で
  git worktree 並列**(2026-08-10 ユーザー指示。本線のツリーには書かないので復元忘れが起きない。
  filter は密閉されたテストだけ。詳細は docs/verification.md)。手で1件だけやるときは
  壊して実行→復元(**復元に `git checkout <file>` を使わない** = 未コミットの変更ごと消える。実害あり)。
  この確認だけで無力なテストが4件見つかった実績がある。
  **検知の類は両方向に掛ける**(出さなくする変異 / 常に出す変異)—— 片方だけだと
  「常に空を返す」変異を「空を期待するテスト」に当てて素通しする(2026-08-07 に2回)。
  **テストが production の関数を通っているかも見る** —— 掃討ハーネスが `!e.enabled` を
  自前で書いていたため、`RefGuard.disabledWarning` を壊しても落ちなかった。検出できない変異が出たらテストを境界へ
  寄せる(要素数を増やす・既定値でなく限界値で呼ぶ)。詳細は docs/verification.md
- **LPT の実績 run 数の既定値は3箇所(`LPTOrdering.defaultHistoryRuns` / `package.json` の
  `fleetest.lptHistoryRuns.default` / `monitorPanel.ts` が webview へ送る default)で一致必須**
  (`lptDefaultSync.test.mjs` が検出。設定タブは default を初期値として入力欄に入れ、空欄・不正値の
  ときもそこへ戻すので、ズレると表示された件数と実際に走る件数が食い違う)
- `fleetest api` の JSON/NDJSON 契約を後方非互換に変えたら `Sources/FTCore/ProtocolVersion.swift` と `vscode-fleetest/src/protocolVersion.ts` の版を +1(両者一致必須・`protocolVersion.test.mjs` が検出。拡張は起動時に照合し不一致を警告)
- **ブリッジの挙動・エンドポイントを変えたら版を上げる**(上げないと**稼働中の旧ブリッジが再利用され、変更が反映されないまま緑になる**。実害2回)。iOS = `Sources/FTCore/BridgeDTO.swift` の `bridgeProtocolVersion`(in-app dylib と XCUITest ランナーの共通定数)/ Android = `AndroidRunner/build.sh` の `VERSION_CODE` と `AndroidBridge.swift` の `expectedBridgeVersionCode` を**同時に**(`AndroidBridgeVersionSyncTests` が定数間の不一致と、**コミット済み `prebuilt/ftbridge.apk` が
  定数と別版のまま=APK 作り直し忘れ**を検出)。**実装ソースを変えたら `BridgeContractTests` が落ちる**
  ので、そこで版を上げてから期待値を貼り替える(貼り付け用のリテラルは失敗メッセージが出す)。
  検出は2段: ルート表(エンドポイントの増減)+ ソース指紋(**ルートが同じでハンドラだけ変えた場合も
  落ちる**)。**版を上げること自体は強制できない**ので最後は人間の規律。
  **Android の版上げは revert しても端末側が戻らない**(2026-08-14 の実害)。**Android は
  versionCode の引き下げインストールを拒否する**ので、上げた版を配った後に版を戻すと、
  ホストは古い版を入れ直せず**全台が「no response to status」で応答不能**になる
  (フリート8台が全滅し、`adb uninstall com.example.ftbridge` を全台に打つまで復旧しない。
  その後も数台が凍結し、落ち着くまで2周かかった)。**試行的な変更ほどブリッジに入れない** ——
  ホスト側で完結できないかを先に問う(この件の本修正は結局ホストだけで足りた)。
  **ブリッジの入力ファイル一覧は `Sources/FTCore/BridgeSourceSet.swift` が唯一の定義元**
  (`InAppLauncher` の dylib 再ビルド判定も同じ一覧を使う。片方だけ変えない)。
  指紋の性質(コメント編集でも落ちる理由)・保留中の代替案は docs/verification.md
- **木は a11y が既定。ブラウザで足りないときだけ DOM で補う**(2026-08-14 に反転。
  **どの組み合わせでどこから木が来るかの一覧は docs/design.md §木はどこから来るか**。
  設計と実測は同 §ブラウザの中身は DOM から読む)。**口は3つ・その上の層は1つ**
  (Android Chrome=CDP / iOS Safari シミュレータ=unix ソケット / iOS Safari 実機=usbmuxd →
  lockdown → TLS)。**条件分岐にしない** —— a11y の充実度はページごとに変わるので、
  「このページでは通るが別のページでは落ちる」を防ぐため、ブラウザでは常に DOM を正とする。
  差し込みの判定は `FTCore.WebViewDOM`(`WebViewDOMTree.swift`)の1箇所。
  **`WebViewDOMSnapshot.swift` へホスト専用の関数を足さない**(ブリッジのソース集合に入っており、
  足すと dylib に無駄が入って指紋ゲートが鳴る)。**実機 iOS だけの罠3つ**(1通の大きさ・
  Web インスペクタ・Safari の起動し直し)は docs/design.md §実機だけの罠
- **判定は MCP と DSL で共有する**(2026-08-07)。「手前かどうか」は `FTCore.PaintOrder`、
  「撃つと別の物に当たるか」は `FTCore.TapTargetGeometry`(合成チェーンは `occlusionAdvisory`)と
  `FTCore.OcclusionGeometry`(中心を覆う最前面の名指し。`OcclusionSuspicion.covering` とは
  判定軸が別=面積比 vs 中心点。統合しない理由は両型の doc)、「絵が古いか」は
  `FTCore.StaleFrameDetector`、焦点待ちの定数は `FTCore.FocusWait` の1箇所だけに置き、
  `RefGuard`/MCP は転送する。別々に持つと**同じ画面で MCP と DSL の判断が食い違う**。
  移設したときは**掃討ゲート(`SweepHarnessTests`)が実アプリのコーパスで等価性を検証する**。
  **type の読み返しの有無はドライバの能力**(`AppDriver.verifiesTypedText`。xcuitest ランナー/
  Android 注入器=true・in-app=false で、false のときだけ `StepExecutor` がホスト側で読み返す)。
  **デバイスの健康状態も同じ**(2026-08-11): 「画面が凍結しているか」は `FTCore.FrozenVerdict`
  が唯一の定義元で、run 前トリアージとモニターは**根拠(`FrozenEvidence`)を束ねた同じ型**を配る。
  プロセスを跨ぐ受け渡しは `FTCore.DeviceFrozenStore`(`.fleetest/frozen-<key>.json`。RunLease と
  同じ pid 生存 + mtime)。**新しい根拠は `isConclusive=false`(警告)から入れる**
- **共有するのは「判定」であって「文言」ではない**(2026-08-15)。同じ事実に対して MCP は
  ツール名で逃げ道を書き(`ft_screenshot` / `ft_scroll_to`)、DSL はシナリオの言葉で書く
  (`back()` を呼び直す)。**文言まで一本化しようとすると、既存の応答文字列を壊して
  MCP のテストと注記の予算ゲート(`NoteBudgetTests`)に当たる**。正しい形は
  **①判定・順序・当たり判定を FTCore に1つ ②文言は呼び手ごとに持つ**:
  - タップ前警告の連鎖 = `TapTargetGeometry.advisoryKind`(当たった形を enum で返す)。
    `occlusionAdvisory`(DSL)と `RefGuard.overlapWarning`(MCP)は**両方これを呼んで写すだけ**。
    以前は同じ順序を2箇所に手で書いており、**実際に2形(ゼロ幅高さ frame・縁の細切れ)が
    DSL にだけあって MCP のタップ時に出ていなかった**。「同じ優先順」はテストのコメントに
    書いてあっただけで、照合するテストは1本も無かった
  - 近い候補の選定 = `FTCore.SimilarLabels`。文言の組み立ては MCP と `StepExecutor.candidateHint`
    がそれぞれ持つ。DSL 側は MCP が 2026-08-10 に捨てた旧版(部分文字列一致・文書順の先着3件)の
    ままで、装飾要素が枠を埋めて実在する操作可能要素を出せない画面があった
  - back の空振り = `FTCore.BackEffect`(中核文 + 呼び手ごとの advice)
  - 打ち切りの逃げ道 = `FTCore.SnapshotTruncation.remedy`(上限を上げる / 画面を狭くする の
    2択を返す)。**DSL だけが「対象に近づくようスクロールする」と勧めていた** —— 同じ事実に
    MCP は「スクロールしても戻ってこない」と書いており、同じ画面で逆のことを言っていた
    (MCP のコメントは「文言だけ揃えて複製する」と書いてあったが揃っていなかった)。
    落ちた要素は配列から抜けているので MCP が正しい。**天井まで来ていたら「上げろ」と言わない**
  - 画面外の一致 = `TapTargetGeometry.offscreenScrollGateCentre`(収まる軸の中心が画面外)。
    探索の「見つかった」ゲート・逆走査 `reverseSweep`・MCP の `ft_scroll_to` 再照合・
    **`requireVisible` の幾何 Tier-0**(`StepExecutor.occlusionFlip`。FM より前・FM 無しでも効く)の
    4箇所が同じ述語を呼ぶ。2026-08-23 まで逆走査と requireVisible には無く、iOS の木に残る
    通り過ぎた要素への `exist(scroll:)` が成功していた(受け手報告)。**FM に訊いて答えが無かった
    ステップは `visibility-guard-skipped`** を立てる(FM が死んでいることを知っているのはツールだけ)
- **「木が画面を代表していない」判定は `FTCore.TreeCoverage` の1箇所**(2026-08-15)。
  webView の内側に大きな空白帯が残る形(Android の Chrome が a11y を部分的にしか公開しない)と、
  アドレス欄はあるのにページ本体が1要素も無い形の2つ。**失敗の型は打ち切りと同じ**
  (不完全な木で否定アサーションが誤って成功する)なので、DSL の notExists/count も
  `StepNote.treeUnderreported` を運ぶ。**判定は変えず注記だけ** —— 幾何からの疑いであって
  申告された事実ではないので、断定すると空のページに対する正当な `notExist` が書けなくなる。
  同型で `FTCore.DuplicateRegion`(横スクロールで前後のコピーが両方 木に残る形。
  片方は描かれていないので撃つと別物に当たる。DSL の tap は `StepNote.staleDuplicateRegion`)——
  こちらは `hasClampedCoordinates`(同一 frame を要求)では**発火し得ない**ので独立に持つ。
  どちらも固定コーパスで**発火する画面の集合を等号で固定**する(`TreeCoverageTests` /
  `DuplicateRegionTests`)。増えたら1件ずつ検分してから直すこと
- **要素上限の撮り直しは肯定側にも要る**(2026-08-15)。`retakenAtElementLimitCeiling` は
  notExists/count(誤った成功)だけを塞いでいたが、exist と操作の解決は**実在する要素で
  赤くなる** = flake として残っていた。操作側は**ドライバ切替と FM ヒールより前**に置く ——
  切り詰められた木で FM に代わりを探させると、実在する本命が候補に無いまま別の要素へ
  「修復」し、それが `fleetest api apply-heal` で利用者の .swift へ書き戻される
- **「書けるセレクタ」の規則は `FTCore.SelectorNaming` の1箇所**(2026-08-15 に FTCore へ降ろした)。
  一意性(`picksOnlyOne`)・祖先スコープ・記法のエスケープ・耐久性の格付けを持つ。
  **ヒール(自己修復)もここを通す** —— 旧 `FlowLocatorBuilder.chain` は一意性を見ずに
  id/label を採っており、同じ id が複数ある画面で**別要素に解決するセレクタを利用者の .swift へ
  書き戻していた**(`fleetest api apply-heal` は直接書き込む)。書けるセレクタが無いときは
  **操作は続けて修復だけ成立させない**(`StepNote.healUnwritable` で数える)——
  掴んだ要素は手元にあるので叩くのは正しく、書き戻せないという理由で緑の run を赤にしない
- **セレクタ文法(`FTSelector`)・コマンド索引(`CommandIndex`)・コード生成(`ScenarioCodeGen`)は
  FTCore に居る**(2026-08-15 に FTDSL から降ろした)。写像先の `FlowLocator` が FTCore の型で、
  DSL ランタイムには依存しない。FTDSL に置いていた間は **FTCore が `FTSelector.serialize` を
  呼べず7箇所でセレクタを手で綴っており**、`fleetest-mcp` はセレクタ文法のためだけに
  DSL ランタイム全体をリンクしていた(この依存は外した)。利用者からの見え方は
  `Descriptors.swift` の `@_exported import FTCore` が保っている。
  **ただし FTCore の名指し(`TapTargetGeometry.describe` 等)は「どれの話か」を短く言うためのもので、
  セレクタとして貼れる保証はしない** —— 貼れる形が要るなら `SelectorNaming` を通す
- **1台の失敗で全体を落とさない**(2026-08-11 の実害)。ブリッジ供給は 10台中8台が ready でも
  残り2台の期限切れで throw し、**Flutter/RN の 51 本が1本も走らなかった**(健全な8台は待機のまま)。
  凍結機をレーンから外して残りで走るのと同じ思想で、**供給は部分失敗を許容し全滅のときだけ throw**
  する(`BridgeProvisioner.resolveOutcomes` = 純粋関数・規則はテストで固定)。
  同型は「N個中1個の失敗を致命にしていないか」——供給・インストール・回復の各段で確認する。
  **逆向きも守る —— 全レーンが同時に落ちているときにレーンを離脱させない**(2026-08-24。
  `FTCore.WorkerCircuitBreaker`): 連続失敗での離脱は「その streak の間に別のレーンが通った」
  証拠があるときだけ。無ければ残して走り続け `circuitHeld` を記録する(外部障害で全部離脱 →
  revive 上限 → 未実行が連鎖した受け手報告。condition 除外案・閾値ノブだけの案は却下。docs/design.md)
- **容器推定(`StepExecutor.clippingContainer`)は scrollable 申告の祖先を優先する**(2026-08-23)。
  「同じ深さの子を2つ持つ直近の祖先」の近似は Compose iOS 向けで、申告のある木ではカードを容器に
  選んで見切れ判定を免除し、横カルーセルへ送れなかった(受け手の最小再現)。申告の無い木は従来どおり。
  この関数はタップの座標補正・ghost 判定・MCP にも効くので、触ったら 5 SUT のフル E2E。
  **座標ドラッグは `StepExecutor.dragWithFallback` だけから撃つ**(in-app は drag が 501。
  `driver.drag` を直に呼ぶと hybrid で黙って不発になる — slowDrag/hintDrag がそうなっていて、
  見切れ回復が利用者の既定エンジンで一度も出ていなかった。2026-08-23)
- **システムアラートの判定は2段**(2026-08-23): 登録がある間は `SystemUIGate` が毎ステップ止める /
  登録が無いときは **launch 直後の最初の触る操作と失敗時だけ1回聞いて** `system-alert-present` の
  注記と題名を残す(止めない・閉じない)。常時監視へ広げない(0ec9b245 の費用判断)
- **ブリッジを起動する前に「そのポートを今 LISTEN している実体」を確かめる**(2026-08-23)。
  `/status` 応答だけで稼働中を数えると、背面に回った in-app ブリッジ(TCP 受付・HTTP 無応答)が
  掴んだポートを「空き」と採番して新しい注入が衝突する(全シミュレータは loopback を共有 =
  ポートは台を跨いで一意)。`PortHolder.stopIfOwnedBridge` / `describe` と `StaleBridgeStop.decide`
  が定義元。**失敗は占有者を名指しして落とす**(「応答が無い」だけでは残骸が原因だと分からない)
- **回復のたびに label(ポート)は変わる**。回復を注入するときは**その時点のワーカー一覧を渡す**
  (`BlankWorkerTriage` の `recover` は第2引数で現在の一覧を渡す)。最初の一覧を捕まえたままだと
  2回目の試行で新しい label を引けず、`frozen devices have no iOS simulator udid` で必ず失敗する
- **変異が生き残ったら、まずテストの置き場所とフィルタを疑う**(2026-08-11)。
  「効かないテスト」と結論する前に、**そのフィルタで狙ったテストが実際に走ったか**をログで見る
  (実際は別クラスにあり1本も走っていなかった)。2026-08-15 に再発 ——
  `--filter TapTargetAdvisoryTests` は**ファイル名ではなくクラス名**に当たるので、同じファイルの
  別クラス(`TapAdvisoryKindPriorityTests`)が1本も走っていなかった。
  **変異が生き残ったときの切り分けは4つ**(この順に疑う):
  ①フィルタが狙ったクラスに当たっているか ②**先に落ちたテストがプロセスごと死んで
  後続を隠していないか**(ログに `Fatal error` / `signal code` が無いか。2026-08-18 実害:
  テスト内の強制アンラップが変異でクラッシュし、同プロセスの残り全テストが走らないまま
  「生き残り」に見えた。**テストでは失敗アサーション後に `!` で触らない** —— guard + XCTFail で
  止める)③**変異式が本当に挙動を変えているか**
  (既定引数を足すだけ・使われない関数を足すだけの「変異」は何も壊していない)
  ④そのうえで初めてテストの内容
- **テストが production の代わりに正規化・整形していないか**(2026-08-15。「テストが production の
  関数を通っているか」の具体形)。`XCTAssertEqual(plan(target, normalize(actual)), .done)` のように
  **アサーション側で production と同じ前処理を掛ける**と、production の前処理を外しても落ちない。
  渡すのは**生の入力**だけにする。
  **併せて「壊れ方が入力で割れる」ものは、割れた先ごとに入力を用意する** ——
  不可視文字の混入は**途中なら `.unverifiable` で黙って受理・末尾なら `.deleteExcess` で
  打ち直しループ→失敗**と別々に壊れ、途中形の入力では正規化を外した変異を**1つも殺せない**
- **「観測」と「配信(表示の最適化)」を同じループに書かない**(2026-08-11 の実害)。
  モニターは配信中のタイルのフレーム生成を止める(`suppressFrames`)が、そのガードが**観測より
  手前**にあったため、実運用の全デバイス(iOS 10 + Android 8 = 全部ストリーミング対象)が
  判定対象から外れ、凍結カウンタが**恒久的に 0** になっていた。抑制は配信段だけに効かせ、
  観測は cadence を落として続ける(`ApiMonitorCommand.capturePlan` = 純粋関数・不変条件はテストで固定)
- **凍結・a11y 異常など「意図的に起こせない事象」の検知には注入口を用意する**
  (`FrozenInjection` / `FT_FAKE_FROZEN_KEYS`)。**陰性(誤検知0)の確認は「常に false を返す検出器」と
  区別できない** —— 実際 2026-08-11 の凍結カウンタは「10台すべてに frozen が乗り誤検知0」を
  根拠にマージされ、恒久 false のまま入った。注入は**観測と公表の経路だけ**を通し、
  回復・除外のような**デバイスを触る動作は撃たない**(`FrozenVerdict.isInjectedOnly`)
- **MCP(`ft_*`)は DSL と別経路なので、鮮度・防御を DSL 側に入れただけでは届かない**。
  `StepExecutor` が持つ知見(キャッシュを捨てた snapshot・ghost の掴み直し・整定)を足したら、
  **MCP にも同じものが要るかを必ず見る**(2026-08-06 に3件まとめて踏んだ: スクロール後の古い木・
  容器外 ghost への座標タップ・pressEnter の焦点待ち。いずれも DSL 側では対処済みだった)。
  **ただし同じ判定をそのまま強い挙動へ流用しない** —— DSL の「掴み直して送り直す」合図を
  MCP で**タップ拒否**に格上げしたら、実アプリで誤検知が5形出て警告へ後退した
  (docs/design.md §10「実装で得た知見」の `RefGuard.ghostWarning` の項)。**新しい検知はまず警告から**入れる。
  探索ロジックは**MCP に2つ目の実装を書かず `StepExecutor` へ委ねる**(`ft_scroll_to`)
- **木だけから決まる注記は `Sources/fleetest-mcp/NoteCatalog.swift` が唯一の定義元**
  (応答の組み立て側へ直に書かない。`NoteCoverageTests` のソース走査が検出)。目録にすると
  3つ手に入る: **発火の全数計測**(どの注記がどの画面で出るか)/ **鍵ごとの黙らせ**
  (`FT_MCP_NOTES_OFF=<鍵,…|all>`。起動時に stderr で名乗る = A/B の陽性対照)/
  **出力バイトの回帰ゲート**。**注記を足すか消すかは読んだ印象で決めない** ——
  `Scripts/mcp-bench.sh` で「まっさらなエージェントの手数」が動いたかで決める
  (バグは有限なので監査を重ねれば減衰するが、**「もっと分かりやすく言えたはず」は無限に出る**
  ので、印象で決める限り注記は単調に増える。実際そうなった)。
  **「出ない」を削除の根拠にする前に、必ずアーキタイプを足して測り直す**(2026-08-12 に実証)——
  19 枚(地図 14)の時点で「地図でしか出ない」と見えていた5本のうち、設定/チャット/WebView 等を
  6枚足したら**3本は他アーキタイプでも出た**(`unlabeledClickablesNote` は settings、
  `keyboardCoverageNote`/`scrollFrameCandidates` は chat)。削っていたら効いている注記を消していた。
  **フィクスチャの分類の正は `NoteCoverageTests.archetypes`**(接頭辞は OS を表すだけ)。
  残る `truncationNote`/`ghostNote` は 25 枚でも各1画面のみ、`bulkExemptNote`/`sliverNote` は
  0 枚(理由を確かめて `knownSilent` に登録済み。等号照合なので新しい死に注記は落ちる)。
  同じ6枚は幾何判定にも当たり、**実 web ページで overlay の誤検知が 10 件**出た
  (折り返す inline テキストの矩形が重なる形。詳細は docs/verification.md)。
  **1つのアーキタイプがコーパスの 60% を超えないこと**(`testNoArchetypeDominatesTheCorpus`)——
  深く掘るほど1アプリが増え、**掘るほど汎用性の判定が悪くなる**逆向きの力が働くので機械で止める
- **エラーの status はホストの分岐契約**(表は docs/design.md §4.3 の
  「エラーの status はホスト側の分岐に使われる契約」)。
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
  プラットフォームの生成・二度聞き)。決まった手順は `Scripts/*.sh` か `fleetest` のサブコマンドにする
- **承認回数はコストとして数える**。値の収集は preflight の出力に寄せ、デバイス選定は
  `profile setup --auto-device`、繰り返す実行は `.claude/settings.json` の許可(fleetest 由来の
  コマンドのみ。`api ensure-settings` が毎回補修)で吸収する。**出力済みの情報を別コマンドで
  取り直さない**。承認は3方向から増えるので全部潰す:
  **①聞かなくてよい確認**(答えが決まっているならスクリプトが決める。例: 外部構成のクローンの
  ローカル変更 = 受け手の資産ではないので自動破棄)/ **②許可リストに無いコマンド**(スクリプトを
  足したら許可も足す)/ **③巨大な出力**(切られてエージェントが grep を打つ。生ログはファイルへ)
- **人に聞くのは AskUserQuestion(ダイアログ)だけ**。チャットに質問文を書くと見落とされてフローが止まる
- **生成したシナリオの検証は3段**(`.claude/skills/fleetest-scenario/SKILL.md` ステップ4→4.5→5):
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
2026-08-05 に一斉修正(dry-run との対比で「実機の前に落とす」等と書いていた 20 箇所が、
実際は Simulator の話だった)。**翌 08-06 に再発**した —— Emulator 上の観測を
「実機で観測」とコメント・docs・コミットメッセージに書いた。**「デバイスで動かした」と
書きたくなった瞬間に、何の上で動かしたかを確認する**(プッシュ済みのメッセージは直せない)。
