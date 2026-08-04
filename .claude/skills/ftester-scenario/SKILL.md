---
name: ftester-scenario
description: セットアップ済みのプロジェクトに、Swift DSL のテストシナリオ(.swift)を1本作成する。テスト対象アプリを実機/仮想機で実際に操作しながら画面スナップショットから実セレクタを採取し、@TestClass/@Test/scene(CAE)の形に落として、コンパイル検証まで通す。「シナリオを書いて」「テストコードを作って」「〇〇のテストを追加して」「この画面遷移をテストにして」等の依頼で使う。まだセットアップ前なら /ftester-setup、対象アプリ/デバイスの登録が無ければ /ftester-profiles。
---

# ftester シナリオ作成 runbook

> **ユーザーへの質問(AskUserQuestion)・報告・チェックポイントはユーザーの言語で行う**。
> この手順書は日本語だが、読者はエージェントであり利用者の言語とは独立している
> (英語話者にはダイアログ・報告文をすべて英語で出す)。


> **この手順書が古い可能性がある**: プラグイン経由で導入している場合、この文書は
> `~/.claude/plugins/cache/` のスナップショットから読まれており `git pull` では更新されない。
> **clone(TOOL_ROOT)が既にあるなら `<TOOL_ROOT>/.claude/skills/ftester-scenario/SKILL.md` を読み、
> 内容が違えばそちらを正とする**。更新は `claude plugin marketplace update foundation-tester` →
> `claude plugin update ftester@foundation-tester`(2つとも要る・Claude Code の再起動で反映)。
> **`/plugin` スラッシュコマンドは VSCode 拡張・Agent SDK 環境では提供されない**ので CLI 形を使う。

既存プロジェクト(`ftester init` / `ftester project create` 済み・アプリ/デバイス/実行プロファイルが
ある)に、**1本のテストシナリオ .swift** を作る。DSL の正典は docs/design.md §10「Swift DSL」と
README.md「Swift DSL」節。ここはエージェントが順に実行するための手順書。

未セットアップなら `/ftester-setup`、対象アプリ・デバイス・実行プロファイルが無ければ `/ftester-profiles`。

## 進め方の原則

- **人に何かを聞くときは必ず AskUserQuestion（ダイアログ）を使う**。チャットに質問文を書いて
  答えを待たない（テキストで聞くと見落とされ、フローが止まる）。自由入力は Other で受ける。
- **コマンドも推測しない**。`ft_dsl_commands` が名前と署名の索引を返す(デバイス不要・引数なしで
  一覧、`name:` / `category:` で要約つき)。**索引に無い名前は存在しない**(コンパイルエラーになる)。
- **セレクタは推測せず、実画面から採取する**。id / ラベル / 型は `ft_snapshot`(または拡張のライブ操作
  パネル)が返す実物だけを使う。想像で `#login_btn` 等を書かない — セレクタの取り違えは design.md §10 が
  列挙する通り「たまに緑」の切り分け不能バグになる。
- **探索と実行は同じデバイスで行う**。`ft_*` は `profile` を渡さないと既定ポート(8123)へ繋ぐので、
  ブリッジが複数立っているマシンでは**探索した画面と実行するデバイスが食い違う**。そうなると
  上の「実画面から採取する」原則が**静かに崩れる**(採取した id は実在するのに、実行機には無い)。
  **`ft_status` / `ft_snapshot` / `ft_tap` / `ft_type` / `ft_swipe` / `ft_launch` すべてに、
  後で `ft_run_scenario` へ渡すのと同じ `profile` を渡すこと**。
- **マップ・キャンバス系の画面は `ft_pinch` / `ft_double_tap` / `ft_drag` で実際に試してから書く**。
  このとき**`profile` を必ず渡す**(渡すと実行と同じデバイス・同じエンジンで動く)。渡さないと
  iOS のエンジンは接続先ポートのブリッジ任せになり、XCUITest を掴んだときだけ
  **Compose のダブルタップと Flutter のピンチが実行時と食い違う**(理由と実測は docs/commands.md)。
  上の「探索と実行は同じデバイスで」がここでは「同じエンジンで」まで含む。
- **人間チェックポイント(🧑)では停止**して、テストの意図・期待結果を確認する。何をテストしたいのかは
  エージェントが勝手に決めない。ただし確認は**推奨案を1つ出して短く承認を取る**形にする(多肢の重い
  設問で意思決定を丸投げしない。セレクタ・経路・後始末など既定で決められることは決めて進める)。
- **各書き込みの後にコンパイル検証ゲートを通す**(`ft_list_scenarios` の自動ビルド、または
  `swift build --product ftester-scenarios-<proj>`)。緑になるまで次へ進まない。
  **緑になったら実機の前に dry-run**(ステップ4.5)。実機時間ゼロで「コンパイルは通るが
  何も検証していない」を落とせるので、実機で1回試してから気付くより安い。
- Projects/ 配下のシナリオはユーザー資産。**既存 .swift を勝手に上書き・整形しない**。追記か新規ファイル。

## 前提の確定(最初に1回)

- **プロジェクトと WORK_DIR**: シナリオは `WORK_DIR/Projects/<プロジェクト>/Scenarios/` に住む。
  Projects/ が1つならそれ。複数なら🧑どれかを確認する。
- **ftester CLI の在り処**: clone 構成は `swift run ftester ...`、外部パッケージ構成は
  `../foundation-tester/.build/debug/ftester ...`(判定は `Sources/FTScenarioRunner/` の有無)。
  以降 `ftester` はこれを指す。MCP(`ft_*`)が使えるならそちらを優先。
- **プラットフォーム**: iOS か Android か。両対応なら @TestClass の platform を決める(下記)。

## 手順

### 1. 🧑 対象アプリ(アプリプロファイル)を確認

**bundle ID を推測・探索で決めない。プロジェクトに登録済みのアプリプロファイルから選ばせる。**

1. `Projects/<proj>/profiles/apps/*.json` を列挙する(または `ftester profile list`)。各ファイルの
   `common.appName`(表示名)と `ios.app` / `android.app`(bundle ID・パッケージ名)を読む。
2. 🧑 **どのアプリプロファイルを対象にするかをユーザーに確認**する(AskUserQuestion。候補が
   1つでも確認する)。選ばれたプロファイルの `app` を @TestClass の `app:` に使う。
3. アプリプロファイルが1つも無い、または対象アプリが未登録なら**ここで停止**し、`/ftester-profiles`
   でプロファイルを作るよう案内する(bundle ID を勝手に発明しない)。

続けて確認する:

- **プラットフォーム**(ios / android / 両対応)。選んだアプリプロファイルに ios/android の
  どちらのセクションがあるかとも突き合わせる。
- **テストしたい振る舞い**:どの画面から始め、何を操作し、何が見えれば成功か。
  1シナリオ=1つの意味あるフロー。長すぎるなら @Test を複数に分ける相談をする。
- 既存クラスに @Test を足すのか、新規クラス(新規ファイル)なのか。

### 2. デバイスを用意してライブ探索(セレクタ採取)

**相乗り禁止**: ライブモニターが対象デバイスで稼働中なら、その機に `ft_*` を相乗りさせるとデモが凍る。
別デバイスを使うか、モニターを止めてから行う(`ft_run_scenario` の `force` は既定 false のまま)。

**以下すべての `ft_*` に `profile=<実行プロファイル名>` を渡す**(上の原則。渡さないと既定ポートの
別デバイスを見てしまう)。初回はブリッジのコールドスタートで分単位かかることがある。

1. `ft_status`(profile 指定)で接続を確認。未起動なら実行プロファイルのデバイスを起動しておく。
2. `ft_launch`(bundleId=対象アプリ・profile 指定)で先頭画面へ。
3. **画面ごとに `ft_snapshot`** を撮り、各行 `[ref] Type "label" id=... (x,y WxH)` から
   **セレクタに使う id / ラベル / 型を控える**。`ft_tap` / `ft_type` / `ft_swipe`(ref 指定)で
   フローを1手ずつ進め、遷移の各画面でまた snapshot する。これが CAE の action と expectation の素になる。
   **通った画面は撮っておく** —— `ft_snapshot` は撮った `#id` をプロジェクトの台帳に貯め、
   ステップ4.5 の dry-run が綴り誤りの照合に使う(撮っていない画面の id は照合できない)。
4. 出るか不定なダイアログ(権限・初回オンボーディング等)があれば、出た/出ないの両方を観察して
   `ifCanSelect` で無害化する対象を把握する。
5. **コントロールが期待通り動かない**とき(タップしても遷移しない等)は snapshot 往復で粘らず
   `ft_screenshot` を1枚撮って地の状態を確認する(選択中タブ・実際の着地画面が即分かり、tree の
   取り違えか実挙動かを切り分けられる)。
6. **探索は原因特定に足る最小手数で切る**。SUT 側の不具合(操作が効かない・別画面へ遷移する等)は
   **再現が2-3回取れたら深追いせず**、その経路を諦めて別経路へ回す。ここは🧑ポイント: 見つけた不具合を
   伝え、**回り込み経路を1つ推奨**して承認を取る(不具合の扱い=報告のみ/バグ再現シナリオ化 も一言添える)。

拡張のライブ操作パネルで**録画**して雛形を得る手もある(`ftester api gen-scenario`)。その場合も
生成された仮セレクタを snapshot の実物と突き合わせて確定させる。

### 3. シナリオ .swift を書く

`Projects/<proj>/Scenarios/<日本語可のファイル名>.swift` に、下記「DSL リファレンス」に従って書く。
命名: クラス名は日本語可、@Test メソッドは `S0010`, `S0020`, …(10刻み)。@Test の説明は「〜できる」。

```swift
// <ファイル名>.swift
import FTDSL

@TestClass(app: "com.example.myapp", platform: "ios")   // app = 手順1で確認したアプリプロファイルの bundle ID。platform は "ios"/"android"、両対応なら省略
class ログインできること {

    @Test("メールとパスワードでログインできる")
    func S0010() {
        scenario {
            scene(1, "ログイン画面を開く") {
                condition {
                    launchApp()                      // 引数省略 = @TestClass の app
                }.expectation {
                    exist("#email")                  // 実 snapshot の id を使う
                    exist("#password")
                }
            }
            scene(2, "資格情報を入れて送信する") {
                action {
                    tap("#email"); type("me@example.com")
                    tap("#password"); type("secret")
                    tap("#login_btn||ログイン")       // id か ラベル(節の順で先に見つかった方)
                }.expectation {
                    exist("ようこそ")                 // 着地画面の実ラベル
                }
            }
        }
    }
}
```

### 4. コンパイル検証ゲート

- MCP: `ft_list_scenarios`(project 指定)を呼ぶ。自動ビルドされ、**コンパイルエラーはそのまま返る**。
  緑なら新シナリオ ID(`クラス名.S0010`)が一覧に出る。
- CLI: `swift build --product ftester-scenarios-<proj>`(exit code で判定。`--target` は不可 = リンクしない)。

エラーが出たら直して再検証。緑になるまで次へ進まない。

- ビルドが `Could not find target 'ftester-scenarios-<proj>...'` で落ちたら、そのプロジェクトが
  Package.swift に未登録(手動 clone / git pull 後にありがち)。**`ftester project sync`** でマーカー
  区間を再生成してから再検証する(Package.swift のマーカー区間は自動生成・手編集しない)。
- **コマンド名の当てずっぽうを避ける**: 存在しない名前はコンパイルエラーになるが、`ftester api
  dsl-commands`(デバイス不要・JSON)で名前・引数・`exist` へのチェーン可否を先に引ける
  (`--name tap` / `--category scroll` で絞る)。他ツールの名前(`assertExists` `waitFor` `click`
  `sleep` `swipeUp` 等)を書くと、コンパイラが ftester での書き方を指して落ちる。

### 4.5. dry-run ゲート(デバイス不要・数秒)

**コンパイルの次・実機実行の前に必ず1回**。実機を1台も使わずに、セレクタの構文誤り・到達しない
scene・**アサーションが0個の expectation** を落とす(どれもコンパイルは通り、実機では
「なぜか緑」になって気付けない類)。

- MCP: `ft_dry_run`(id=`クラス名.S0010`, project 指定)
- CLI: `ftester api run --project <proj> --dry-run --scenario <クラス名.S0010>`

⚠️ 行が出たら直してから次へ進む:

| 出る警告 | 意味 | 直し方 |
|---|---|---|
| `contains no assertions` / `no assertions at all` | 操作しただけで何も検証していない | expectation に `exist` / `textIs` / `thisIs` 等を足す |
| `no snapshot taken for this project contains this id` | その `#id` は、**ステップ2で撮ったスナップショットのどれにも無い** = 綴り誤りの疑い | スナップショットの実物と突き合わせる。まだ撮っていない画面のものなら `ft_snapshot` を撮り直す(撮った時点で台帳に入る) |

id の照合は**ステップ2で `ft_snapshot` を撮った画面ぶんだけ**効く(`ft_snapshot` が
`<プロジェクト>/.ftester/selector-inventory.json` に貯める)。**撮らずに書いたシナリオでは
何も言わない**ので、セレクタを推測で書かない原則は変わらない。ラベルとワイルドカード
(`#row_*`)は照合対象外。

### 5. 🧑 実行して意図通りか確認

ユーザーに実行してよいか確認してから:

- MCP: `ft_run_scenario`(id=`クラス名.S0010`, profile=実行プロファイル)。失敗時はトリアージと
  レポートパスが返る。ロケータのブレを吸収したいときだけ `heal: true`。
- CLI: `ftester run --project <proj> --profile <prof>`(全実行)。

レポートで期待通りか確認する。セレクタがヒール修正提案付きで通っている場合は、提案を人がレビューして
ソースを実ラベルに直す(design.md §10「ヒールキャッシュ」)。

### 6. 仕様違反のバグ起票(標準)

testbase(SC/TC 等の仕様書)を根拠にシナリオを書く場合、実行結果が仕様に従わない箇所の扱いを標準化する:

- **仕様違反は緑にしない**。テストを実挙動に寄せて通す(=仕様違反を緑で隠す)ことはせず、**仕様どおりの
  期待のまま RED(失敗)**にして追跡する(緑で隠すと退行検知にならない)。後始末は `tearDown` に置く
  (失敗でシナリオは中断するが、tearDown だけは失敗後でも実行されるため残留を防げる)。
- **バグは1件1ファイルで専用フォルダに起票**する(詳細=個別ファイル)。置き場所:
  `Projects/<proj>/issues/defects/`。命名・テンプレート・凡例は同フォルダ `README.md`(`D-<連番2桁>-<slug>.md`)。
  **状態の一覧は同フォルダ `INDEX.md`(対応状況ダッシュボード)**に集約し、起票・状態変更時は個別ファイルと
  INDEX.md の両方(集計含む)を更新する。
  各ファイルに: 対象 / 対応 SC-TC / 重大度 / 状態 / 検出元シナリオ / 再現手順 / 期待 / 実際 / 証拠 / 仕様裁定案。
- **テストが仕様の正誤を独断確定しない**: TC 自身が「実挙動を Pass として記録し仕様裁定は別起票」と明示する
  ケース(仕様と実装が三者不一致など)は、その TC の指示に従い緑のままにし、裁定事項として起票側に回す。
- 修正されたら defect の状態を更新し、対応テストが緑に変わることを確認する。

---

## DSL リファレンス(design.md §10 の要点。正典はそちら)

### 構造

- `@TestClass(app:platform:)` クラス → `@Test("説明")` メソッド(ID は `S0010` 形式)→ `scenario { }`
  → `scene(n, "題")` → **condition / action / expectation**(CAE)の3層。
  - `condition` = 前提(通常 `launchApp()`)、`action` = 操作、`expectation` = 検証。
  - チェーンで書く: `condition { … }.action { … }.expectation { … }`。不要な層は省略可。
- コマンドは**同期・非 throw のモジュールレベル関数**。`try`/`await`/`{ it in }` 不要。カレント
  コンテキストを暗黙参照する。
- 失敗セマンティクス: コマンド NG → **シナリオ中断**(以降のステップは scene を跨いですべてスキップ。
  throw しない。`tearDown` だけは失敗後でも実行される)。
- `@Deleted("理由")` をクラス/メソッドに付けると論理削除(一括実行から除外・完全一致 ID でのみ実行可)。

### コマンド

| 分類 | コマンド |
|---|---|
| タップ/入力 | `tap(sel, timeout:)` / `tap(sel, holdSeconds:)`(長押し)/ `type(text)`(直前フォーカス)/ `type(sel, text)` / `select(sel)`(掴むだけ。**掴めなければ空要素**を返し失敗しない)/ `lastElement`(直前に掴んだ要素。**値は掴んだ時点の凍結値**なので、掴んだ直後に読むときだけ使う。離れた場所で使うなら `let e = select(…)` で受ける) |
| スワイプ/スクロール | `swipe(.up/.down/.left/.right)`(**指の動き**。生のジェスチャ)/ 以下は**コンテンツ基準**(`.down` = 下に読み進める): `scrollTo(sel, direction:, maxSwipes:)` / `scrollDown(repeat:)` `scrollUp` `scrollRight` `scrollLeft` / `scrollToBottom(maxSwipes:)` `scrollToTop` `scrollToRightEdge` `scrollToLeftEdge` / `flickCenterToTop/Bottom/Left/Right` `flickLeftToRight/RightToLeft` `flickBottomToTop/TopToBottom`(画面基点・8種。速い1ストロークの生ジェスチャ) |
| スクロールしながら探す | `tap(sel, scroll: .down)` / `exist(sel, scroll: .down)`(別名 `tapWithScrollDown` / `existWithScrollDown`)/ ブロックで囲む `withScrollDown { … }` と、1コマンドだけ打ち消す `tapWithoutScroll` `existWithoutScroll` `withoutScroll { … }` |
| 検証 | セレクタを取るのは `exist(sel)` / `notExist(sel)` / `countIs(sel, 個数)` / `screenIs(名)` だけ。**要素の属性検証は「掴んでから」書く**: `select(sel).enabledIsTrue()` / `.enabledIsFalse()` / `.checkIsON()` / `.checkIsOFF()` / `.idIs("…")`。`verify("説明") { … }` は複数アサーションを1ステップに集約(ブロック内0個なら inconclusive = passed でも failed でもない・シナリオは続行) |
| テキスト・値の検証 | **セレクタは取らない**(対象は直前に掴んだ要素)。`select(sel).textIs("期待値")` と書くか、`select(sel)` の次の行に `textIs("期待値")` を書く(**同義**。`lastElement.textIs(…)` も同じ)。種類は `textIs` `textContains` `textStartsWith` `textEndsWith` `textMatches`(正規表現)`textMatchesDateFormat` `textIsEmpty` `textIsNotEmpty` と、**それぞれの否定** `textIsNot` `textContainsNot` … / `value…` も同名で一式。**これらに `scroll:` は無い**(静止画面の検証用。画面外は先に `scrollTo`) |
| 画面に依らない値の検証 | `thisIs` `thisIsNot` `thisIsTrue` `thisContains` `thisMatchesDateFormat` `thisIsGreaterThan` …(API 応答・計算結果に直接生える。失敗は1ステップとして記録される) |
| アプリ制御 | `launchApp(bundleID?)` / `restartApp()` / `terminateApp()` / `home()` / `appSwitcher()` / `installApp(path?)` / `removeApp(id?)` / `appIs(id, waitSeconds:)` / `tapAppIcon(name?)`(ホーム画面のアイコンをタップ。省略時はプロファイルの appName) |
| 待機/分岐 | `wait(秒)` / `waitForDisplay(sel, waitSeconds:)`(表示まで待つ。スクロールしない)/ `waitForClose(sel, waitSeconds:)`(消えるまで待つ。スクロールしない)/ `ifCanSelect(sel, waitSeconds:) { … }.ifElse { … }` / `ios { }` / `android { }` / `procedure("名") { try await … }` |
| 反復 | `repeatWhileCanSelect(sel, max: n) { … }`(解決できる限り繰り返す。上限到達は失敗にしない)/ `doUntilTrue("名", waitSeconds:) { 条件 }`(**アプリ・外部の状態待ち専用**。要素の出現待ちは各コマンドの `timeout:`) |
| 割り込み | `irregularHandler("#promo_modal", dismiss: "#btn_close")` を setUp で宣言すると、出るか不定の**アプリ内メッセージ**を出た時点で自動的に閉じる(OS のダイアログはツール側が吸収するので書かない) |
| まとまり | `group("ログイン") { … }`(記録に `[ログイン]` を前置するだけ。実行・失敗の扱いは素の列と同じ) |
| 記録 | `screenshot(filename:?)`(現在の画面を撮り、このステップ直後にレポートへ埋め込む) |
| 前後処理 | テストクラスに `func setUp()` / `func tearDown()`(引数なし)を書くと各 `@Test` の前後で自動実行 |

- **要素が見つからなければ失敗**(シナリオ中断)。**唯一の例外は `select`**(空要素を返す。`.isEmpty` で分岐)。
  「出るか不定」を表す引数は無いので、アプリ内メッセージは `irregularHandler`、その場限りの分岐は
  `ifCanSelect(sel) { … }` で書く。`timeout:` = ロケータ再試行の上限秒(0=即諦め、省略=約0.7秒)で、
  `ifCanSelect` / `select` の空振り短縮に使う。
- **`wait(秒)` は原則不要**。`tap` はロケータ解決を約0.7秒(`timeout:` でその秒数)まで再試行し、
  `exist`/`textIs`/`valueIs` は既定タイムアウト(5秒・実行プロファイルの `--default-timeout` で上書き)まで
  ポーリング再判定する。要素の**出現待ち**はこれらが暗黙にこなすので、遷移後の `exist` 直前などに
  `wait` を入れても冗長。待ちが足りなければ `exist(sel, timeout:)` / `tap(sel, timeout:)` を上げる。
- **`ifCanSelect` だけは既定で即時判定**(`waitSeconds:0`)。遷移直後に分岐条件を待ちたいときは
  先行 `wait` ではなく `ifCanSelect(sel, waitSeconds:)` を使う(解決できたら即進む)。
- **`type` は Compose Multiplatform / Flutter 等(UIKit の入力欄を持たないアプリ)でもそのまま書いてよい**。
  iOS の既定エンジン(hybrid)が Compose を自動判定し、type だけ XCUITest 実行に切り替える(tap/exist は
  高速な inapp のまま)。409「フォーカスされた入力欄がありません」が出るのは engine=inapp 明示の
  プロファイルだけ。Android は常に inapp で type 可。type の前の `tap(入力欄)` は両 OS 共通で入れておく
  (Android inapp のフォーカス確立に必要)。
- 同じ手順を関数に切り出して使い回してよい(private func。例: 不定ダイアログの `dismiss…IfAny()`)。
- `procedure` は任意 Swift(データ準備等)を1ステップとして記録。throw すると NG 扱いでシナリオ中断。

### セレクタ式(文字列1本・`||` は候補の和)

- `#id` — id 完全一致(最も頑健。可能なら第一候補)
- `ラベル` — label(**完全一致のみ**。完全形 `text=ラベル`)
- `*語*` / `語*` / `*語` — 部分一致 / 前方一致 / 後方一致。**部分一致は必ずこの記法で明示する**
  (素の文字列は完全一致しかしない)。正規表現は `textMatches=^…$`(部分一致。全体一致は `^…$`)
- `.型` / `.型[2]` — 型(+順番、**1 オリジン**。1番目は [1] 省略可)。
  **型名は先頭小文字**(`.button` / `.staticText`)。スナップショットが返す綴りと同じ。
  先頭大文字で書くと実行前に構文エラーになる
- `.型#id` — 型で絞った id(`&&` 合成の短縮形)。型とラベルの併用は `.型&&ラベル`
- `A&&B&&…` — **AND 合成**。属性は `text` `value` `placeholder` `id` `type` `pos` `checked` `enabled`
  (`*語*` 等の一致方法は `textContains=` のように接尾辞で書ける)。
  例: `.textField&&value=太郎` / `.switch&&checked=true` / `*保存*&&.button&&enabled=true`
- `.input` / `.widget` — 型エイリアス(`.input` = textField|secureTextField /
  `.widget` = OS 共通の役割型5つ。役割不明の `clickable` は含まない)
- `祖先 >> 子孫` — **スコープ**。`#list >> .clickable[2]` = `#list` の子孫だけを候補にし、序数もその中で数える
  (画面クロム・スクロール位置で `.型[n]` がずれる問題の対処。多段可)。
  **容器がアプリ側で a11y ツリーに公開されている必要がある**(`#id` と同じ性質の要件で、
  フレームワークの差ではない)。公開されていない/畳まれている容器はスコープに使えないので、
  実スナップショットで「容器が要素として出ている」「行がその子になっている」を確認してから書く
- `基準:rightSwitch` — **相対セレクタ(基準が先・対象が後)**。基準から見てその方向にある候補だけに
  絞る。**id が無い要素を隣のラベルから指す**ための記法(`通知:rightSwitch` = ラベル `通知` と
  同じ行にあるスイッチ)。方向は `right` / `left` / `above` / `below`、型別接尾辞は
  `Button` / `Input` / `Label` / `Image` / `Switch` / `Widget`。
  引数で序数(`数量:right(2)` = 近い順2番目)や任意フィルタ(`#a:below(.button&&項目)`)も書け、
  `見出し:right:belowButton` と連鎖もできる。基準は `<...>` で囲んでもよい(Shirates 正典形。
  `<変更&&.button>:right(数量)`。囲みは任意で、パース結果は囲まない形と同じ)。
  規則は3つだけ:
  ①候補の中心が基準の帯(right/left なら y 範囲、above/below なら x 範囲)に入る
  ②候補の中心が基準の中心よりその方向 ③その中で近い順(同距離はツリー順先頭)。
  **該当が無ければ失敗**する(近いものを勝手に選ばない)。可視要素にのみ有効。
  スコープと併用すると**基準も対象も容器の中**で解決する(`#row >> 数量:rightButton`)
- `=ラベル` — `#` や `.` で始まる**生ラベル**を label として扱うエスケープ
  (`>>` `&&` `:right` `*` を含むラベルもこれで書く)
- **綴り誤り・未対応記法は実行前にエラー**になる(`:near` `:parent` 等の他ツール記法、未知の
  フィルタ名 `textContans=`、型名の `=`、`[abc]`、閉じない括弧)。
  黙ってラベル扱いにはならないので、通れば構文は正しい
- `A||B` — **候補の和集合**(Shirates 準拠)。`tap` は節の順で最初の候補に着地するので
  「id 優先・ラベルは代替」の書き方はそのまま通る。`countIs` は**和の総数**(同じ要素が複数の節に
  当たっても1度だけ)。例: `tap("#login_btn||ログイン||.button")`
- `(a|b)` — **フィルタ内 OR**。`保存||OK` と等価(`.button&&(許可|項目)` のように型と併用できる)。
  相対の引数では括弧を自分で書く(`:right((保存|OK))`)
- `!値` / `属性!=値` — **否定**(`.button&&!キャンセル` = キャンセル以外のボタン)。
  `!#id` `!.型` も可。**否定だけの節は書けない**(「〇〇以外の全要素」は容器まで掴むため)

### セレクタ選定の罠(そのまま踏む。design.md §10 実測)

- **部分一致を安易に使うと誤マッチする**。`"*許可*"` は `"通知を許可"` にも当たる。素の文字列は
  完全一致なので、まず**実 UI の完全ラベル**をスナップショットから採って素で書く。
  部分一致(`*語*`)は動的な文字列を含むときだけにし、一意になる部分文字列を選ぶ。
- **`||英語` フォールバックは英語ロケール機でのみ発火**。ja-JP フリートでは日本語プライマリが唯一の
  頼り。プライマリを対象 OS/ロケールの実ラベルに合わせて維持する(OS 改名で即ハード失敗)。
- **id を一切公開しないアプリ**では label/型でしか指せず、戻る/アイコンボタン等の**無ラベル要素は
  `.型[n]`(順序依存で脆い)でしか指せない**。position で採取し、指定にコメントを添える。id があれば
  頑健なので、テスト容易性の改善提案(主要導線への accessibilityIdentifier 付与)も併せて伝えてよい。
  - **`.型[n]` は画面状態で指す要素が変わる**(一覧では削除ボタン、空表示では別ボタン/タブ 等)。
    容器の id があるなら `#容器 >> .型[n]` でスコープを付けると画面クロムやスクロール位置の影響を切れる。
    破壊的・index 指定の tap は、**意図した状態のみ出るマーカーで `ifCanSelect` ガード**してから撃つ。
  - **件数不定の一括操作は `repeatWhileCanSelect(sel, max: n) { … }`** を使う(セレクタが解決
    できる限り繰り返す。上限到達は失敗にしない)。上限は想定最大件数に合わせる。
- **既定は現在画面のみ**(非スクロール)。折り返しの下にある項目は `tap(sel, scroll: .down)` /
  `exist(sel, scroll: .down)` で探索するか、先に `scrollTo(sel, maxSwipes:)` で送る。
  **テキスト検証(`textIs` 等)は自動でスクロールしない**ので、先に送ってから確認する。
- **`wait` が要るのはアニメーション整定だけ**。要素は在るのにタップ座標がアニメ中でずれる場合
  (メニュー展開・シート表示・表示切替の直後の `tap` 等)に限って `wait(1)` を挟む。**要素の出現待ちには
  使わない**(上記の暗黙ポーリングで足りる。`exist` 前の `wait` は削る)。
- **出るか不定なダイアログは `ifCanSelect` で無害化**(素で tap すると出ない環境で失敗する)。
- **状態を変える操作(表示切替・トグル等)は同一 @Test 内で元に戻す**(他シナリオへ副作用を残さない)。
  特に**実行を跨いで残る保存状態**(登録・作成・変更したデータ等)は、戻さないと次回実行の擬陽性源になる
  (冒頭でリセット、または末尾で削除する)。
- **擬陽性を避ける**: expectation は「その action が起きなければ落ちる」ものにする。実行を跨いで残る状態を
  presence だけで確認すると、前回の残留で緑になり action の失敗を見逃す。**基準化→action→検証**の形にする
  (例: 空にする→空マーカーを確認→追加→存在確認、または件数/合計の**差分**)。**基準化の直後に基準到達を
  必ずアサート**してから action する(リセットが黙って失敗すると擬陽性が戻る)。なお**プロセス終了での
  リセットは効かない/未対応のことがある**(terminate が in-app ドライバで不可等)。アプリ内のリセット手段を
  確立し、実際に空/初期になることを確かめてから使う。
- **状態依存の入口はガードする**: 空状態のみ出る CTA・初回だけの導線・不定の再開画面は `ifCanSelect` で
  分岐して吸収する。前提をコメントで断るだけにしない(条件が崩れると不可解に落ちる)。
- **launchApp が直前画面から再開する**アプリは、一覧/先頭画面へ正規化してから進める
  (`ifCanSelect("#詳細ビュー") { tap("#BackButton") }` 等)。
- **WebView(Web コンテンツ)内は規約が違う**(スナップショットに `.webView` 型が出たらこの画面):
  **`#id` は一切効かない**(HTML の `id` 属性は両 OS とも a11y に出ない)。指せるのは
  表示テキスト・`aria-label`・型だけ。**リンクは `.link` と `.staticText` の2要素で重複して
  出る**ので `.link&&ラベル` と型で絞る。**ラベルの無い入力欄は `placeholder=…`** で指す。
  中身が現れるまで初回は数秒かかることがあるため、**遷移直後の検証は `timeout:` を長めに**
  (実測: 内蔵 HTML で 2〜8 秒。実ページ+通信ならさらに延びる)。id を採取しようとして
  スナップショットに無くても、アプリ側の不備ではなく仕様(改善提案の対象にしない)。

### 命名・配置

- ファイル: `Projects/<proj>/Scenarios/<日本語可>.swift`(`_Main.swift` は触らない = エントリポイント)。
- クラス名は日本語可。@Test メソッド名 `S0010`/`S0020`/…(10刻み)。実行 ID は `クラス名.メソッド名`。
- 深い階層に置いてよい(`Scenarios/Demo/…`)。objc 走査で自動発見される。
