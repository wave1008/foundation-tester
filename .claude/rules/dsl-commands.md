---
paths:
  - "Sources/FTCore/BridgeDTO.swift"
  - "Sources/FTCore/CommandIndex.swift"
  - "Sources/FTCore/Flow.swift"
  - "Sources/FTCore/InputFocusRescue.swift"
  - "Sources/FTCore/ProjectCommandIndex.swift"
  - "Sources/FTDSL/**"
  - "Sources/FTDSL/Commands.swift"
  - "Sources/FTDSL/FTRuntime.swift"
  - "Sources/FTDSL/UnavailableCommands.swift"
  - "Sources/FTDSLMacros/**"
  - "Tests/FTDSLTests/**"
  - "Tests/FTDSLTests/CommandIndexSyncTests.swift"
  - "Tests/FTDSLTests/FTDriveCorePrewarmWiringTests.swift"
  - "Tests/FTDSLTests/SelTests.swift"
  - "Tests/FleetestMCPTests/BatchLineParserTests.swift"
  - "docs/commands.md"
  - "docs/shirates-parity.md"
  - "docs/user-docs/commands/**"
---

# DSL コマンド(索引・引数名・スクロール指定・操作の待ち) の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **機械可読な索引は `Sources/FTCore/CommandIndex.swift`**(`fleetest api dsl-commands` が出す)。
  **コマンドを足す/消す/改名したら索引も直す**(`CommandIndexSyncTests` が Commands.swift /
  CommandsVerify.swift / CommandsAppControl.swift / ValueAssertions.swift / FTElement と突き合わせる)
- **利用者が scenarios/ に書いた `@FTCommand("summary")` 付き関数(FTDSL の空展開マーカー)は
  `fleetest api dsl-commands --project` / MCP `ft_dsl_commands` の索引に `origin: "project"` で載る**。
  出典は `Sources/FTCore/ProjectCommandIndex.swift`(ソーステキストを直接読む純粋な走査。デバイス・
  ビルド非依存)—— `CommandIndexSyncTests` 等の組み込み同期テストはこちらを対象にしない(走査対象は
  ユーザーのシナリオファイルで、リポジトリには実例を置かない)
- **スクロールの指定は各コマンドの `scroll:` 引数だけ**(ユーザー決定 2026-09-19)。向き(`.down` 等)か
  `.noScroll`(`withScroll*` の中でもこの1コマンドだけ送らない)。**関数名で指定する別名
  (`*WithScrollDown/Up/Right/Left`・`*WithoutScroll`)は1つも置かない・再提案しない** —— 別名は族ごとに
  シグネチャが不揃いになり(`maxSwipes:` しか取らない・`exist` は上下だけ…)、同じことが2通りで書ける。
  型は FTDSL の `FTScrollOption`(4方向 + `.noScroll`)。**`FTCore.FTScrollDirection` に `.noScroll` を足さない**
  —— `scrollTo(direction:)`・`withScroll*`・MCP の `direction` に書けてしまう。**省略(nil)= 文脈に従う、と
  `.noScroll` は別の値**で、解くのは `FTDriveCore.effectiveScroll` の1箇所(`SelScrollVariantDispatchTests` が
  3値の解決を縛る)。ブロック形の `withScrollDown { }` / `withoutScroll { }` は残す
- **引数名の規律**(ユーザー決定 2026-09-19): 待つ上限は全コマンドで **`waitSeconds:`**(`timeout:` を DSL に置かない。
  **MCP ツールの待ち上限も `waitSeconds`**(ユーザー決定 2026-09-25。DSL を書くための入口なので名前を揃える)。
  `FlowStep.timeout`・プロファイルの `defaultTimeout` は内部 / 別系統の名前で据え置き)/ ループ上限は
  **`maxLoopCount:`** / ラベル無しの第1引数は `selector`・`label`・`appID`・`filename`、ブロックは `body` /
  同じことを2通りで書ける口を作らない(`screenshot` のファイル名はラベル無しの1形だけ)。
  **引数の並びは「対象(ラベル無し)→ コマンド固有(`holdSeconds` / `requireVisible` / `strict` / `prefer` /
  `threshold` 等)→ `waitSeconds:` → `scroll:` → `maxSwipes:`」**を全コマンドで守る(Swift は既定値つきでも
  順序を強制するので、族の中で並びが割れると書き手が1つずつ覚える羽目になる)。
  **`ft_batch` は DSL の行を受けるので、索引の signature を変えたら `MCPServer.batchStepBuilders` のキーも同時に変える**
  (片方だけだと実在するラベルを断り、無いラベルを受ける。緑のまま通った = `BatchLineParserTests.testWaitCapLabelFollowsTheDSL`)
- **置いていない名前は `Sources/FTDSL/UnavailableCommands.swift` で受け止める**(他ツールの名前・
  対称性から実在すると誤解される別名。`cannot find in scope` の代わりに正しい書き方を出す)
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
