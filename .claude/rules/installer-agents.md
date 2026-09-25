---
paths:
  - ".claude-plugin/**"
  - ".claude/skills/**"
  - ".claude/skills/fleetest-scenario/SKILL.md"
  - ".claude/skills/fleetest-setup/SKILL.md"
  - ".claude/skills/fleetest-update/SKILL.md"
  - ".gitignore"
  - "CLAUDE.md"
  - "Scripts/*.sh"
  - "Scripts/install-skill.sh"
  - "Scripts/install.sh"
  - "Scripts/mcp-server.sh"
  - "Scripts/preflight.sh"
  - "Scripts/update-check.sh"
  - "Scripts/update.sh"
  - "Sources/FTCore/AgentIntegration.swift"
  - "Sources/FTCore/DevicePicker.swift"
  - "Sources/FTCore/ProfileWriter.swift"
  - "Sources/FTCore/SelectorInventory.swift"
  - "Sources/FTCore/ToolchainFingerprint.swift"
  - "Tests/FTCoreTests/DevicePickerTests.swift"
  - "Tests/FTCoreTests/ProfileWriterTests.swift"
  - "Tests/FTCoreTests/SelectorInventoryTests.swift"
  - "Tests/FTCoreTests/ToolchainFingerprintTests.swift"
  - "docs/user-docs/getting-started*.md"
  - "docs/user-docs/tools/other_agents*.md"
  - "vscode-fleetest/src/monitorUpdateController.ts"
  - "vscode-fleetest/src/toolRootResolve.ts"
  - "vscode-fleetest/src/updateCheck.ts"
---

# 受け手フローのスクリプト・エージェント連携・配布 の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

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
  - **WORK_DIR の `AGENTS.md` にマーカー付きで入口を置き、`CLAUDE.md` には `@AGENTS.md` の読み込みだけを置く**
    (ステップ7.6。Claude Code は v2.1.277 から AGENTS.md を読むが、CLAUDE.md があると既定では読まず、
    古い版は読まない = 読み込みならどちらにも届き、AGENTS.md を読む他のエージェントにも同じ本文が届く。
    定義元は `AgentIntegration.entryPointFile` / `claudeImportFile`。`.mcp.json` も
    `.claude/settings.json` も「設定として効く」だけでエージェントが読む物ではないため、これが
    無いと導入の翌週にスキルの description しか手掛かりが無くなる)。
    **使い方の解説は書かない**(ツール説明と二重管理になり必ずズレる)。受け手の資産なので
    マーカーの内側だけ差し替え、嫌う受け手には `--skip-entry-point`。
    **ここは受け手のファイルを書き換える唯一の箇所**なので、**マーカーが begin/end ちょうど1組で
    なければ1バイトも書かない**(`installClaudeMdBlock.test.mjs` が3形を守る)→ maintainer-notes §1.2
  - **クローンが git 管理しているファイルには書かない**。判定はレイアウトではなく
    **入口ファイルがクローンの作業ツリーの内側にあるか**(`os.path.commonpath` による包含判定)。
    **受け手のフローに「クローンの中を書く」工程を足すときは必ずこの判定を見る**
    → maintainer-notes §1.3
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
