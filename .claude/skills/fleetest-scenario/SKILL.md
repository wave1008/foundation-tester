---
name: fleetest-scenario
description: セットアップ済みのプロジェクトに、Swift DSL のテストシナリオ(.swift)を1本作成する。テスト対象アプリをデバイス(Simulator・Emulator・実機)で実際に操作しながら画面スナップショットから実セレクタを採取し、@TestClass/@Test/scene(CAE)の形に落として、コンパイル検証まで通す。「シナリオを書いて」「テストコードを作って」「〇〇のテストを追加して」「この画面遷移をテストにして」等の依頼で使う。まだセットアップ前なら /fleetest-setup、対象アプリ/デバイスの登録が無ければ /fleetest-profiles。
---

# fleetest シナリオ作成 runbook

> **ユーザーへの質問・報告・チェックポイントはユーザーの言語で行う**。
> この手順書は日本語だが、読者はエージェントであり利用者の言語とは独立している
> (英語話者にはダイアログ・報告文をすべて英語で出す)。


> **スキルの呼び出し記法はエージェントごとに違う**(Claude Code は `/fleetest-setup`)。
> 以下は `/` 形で書くので、別の記法のエージェントではそちらへ読み替える。

既存プロジェクト(`fleetest init` / `fleetest project create` 済み・アプリ/デバイス/実行プロファイルが
ある)に、**1本のテストシナリオ .swift** を作る。DSL の正典は docs/design.md §10「Swift DSL」と
README.md「Swift DSL」節。ここはエージェントが順に実行するための手順書。

未セットアップなら `/fleetest-setup`、対象アプリ・デバイス・実行プロファイルが無ければ `/fleetest-profiles`。

## 進め方の原則

- **人に何かを聞くときは必ず選択ダイアログ（Claude Code なら AskUserQuestion）を使う**。チャットに質問文を書いて
  答えを待たない（テキストで聞くと見落とされ、フローが止まる）。自由入力は Other で受ける。
- **コマンドも推測しない**。`ft_dsl_commands` が名前と署名の索引を返す(デバイス不要・引数なしで
  一覧、`name:` / `category:` で要約つき)。**`project:` にこのプロジェクト名を渡すと、
  そのプロジェクトが `@FTCommand("summary")` で公開した独自のヘルパー関数(`login(user:password:)`
  のような素の Swift 関数や `extension FTElement` のメソッド)も `[project: file:line]` 付きで
  一緒に返る** —— これはチームが書いた実物なので、流れに合うなら組み込みより優先して使う。
  **組み込み・project どちらの索引にも無い名前は存在しない**(コンパイルエラーになる)。
  project のヘルパーは `ft_batch` では実行できない(シナリオの .swift に直接書く)。
- **ソースコードは読まない**(実務のテスト担当者と同じ立場で書く)。fleetest 本体のソース(`Sources/`)・ユニットテスト(`Tests/`)も、
  **テスト対象アプリのソースも**読まない。**例外は fleetest のテストプロジェクトのテストコード**(`TestProjects/<プロジェクト>/scenarios/` のシナリオ)で、
  既存のテストに足す・書き方を合わせるときは読む。アプリの振る舞いは、画面(`ft_snapshot` / `ft_screenshot`)・依頼文・
  プロジェクトの仕様書(`TestProjects/<プロジェクト>/docs/testbases/`)から得て、それでも決まらないことは人に聞く(選択ダイアログ)。
  fleetest の仕様は docs から得る。docs はクローン(`.fleetest/state.json` の TOOL_ROOT。外部構成なら作業フォルダの隣の
  `../foundation-tester`)にある:

  | 知りたいこと | 読む場所 |
  |---|---|
  | コマンドの名前・署名・掴んだ要素から読める値 | `ft_dsl_commands`(値は `category: "property"` = `exist(sel).text` 等、読んだ値の検証は `category: "this"`) |
  | コマンドの引数・挙動 | `docs/commands.md`・`docs/user-docs/reference/commands/` |
  | テストクラスの構造(`beforeEach` / `setUpDevice` 等) | `docs/user-docs/reference/testclass/testcode_structure_ja.md`・`docs/user-docs/reference/commands/descriptors_ja.md` |
  | セレクタの書き方 | `docs/user-docs/reference/selector/` |

  docs で答えが見つからなければ、ソースを読みに行かず、完了報告で「docs に無かったこと」として挙げる
  (docs の不足を直す材料になる)。
- **画面に Material3 の定番部品(ページャ・ボトムシート・メニュー・日付ピッカー・ドロワー・
  引っ張って更新・スナックバー・検索バー 等)があるなら、書く前に
  docs/user-docs/reference/writing/ui_component_patterns_ja.md の該当節を読む**。モーダルの間は背後が木から
  消える・入力欄の値は `.value` に出る・横の容器は `scrollFrame:` が要る、といった部品固有の書き方と、
  ツールの現時点の制約(黙って誤る操作)の回避策がある。そこに書いた回避策で書く
- **セレクタは推測せず、実画面から採取する**。id / ラベル / 型は `ft_snapshot`(または拡張のライブ操作
  パネル)が返す実物だけを使う。想像で `#login_btn` 等を書かない — セレクタの取り違えは design.md §10 が
  列挙する通り「たまに緑」の切り分け不能バグになる。
- **探索と実行は同じデバイスで行う**。`ft_*` は `profile` を渡さないと稼働中のブリッジ/デバイスを
  自力で探す(1つに決まらなければ候補を列挙してエラー)ため、
  ブリッジが複数立っているマシンでは**探索した画面と実行するデバイスが食い違う**。そうなると
  上の「実画面から採取する」原則が**静かに崩れる**(採取した id は実在するのに、実行機には無い)。
  **`ft_status` / `ft_snapshot` / `ft_tap` / `ft_type` / `ft_swipe` / `ft_launch` すべてに、
  後で `ft_run_scenario` へ渡すのと同じ `profile` を渡すこと**。
- **マップ・キャンバス系の画面は `ft_pinch` / `ft_double_tap` / `ft_drag` で実際に試してから書く**。
  このとき**`profile` を必ず渡す**(渡すと実行と同じデバイス・同じモードで動く)。渡さないと
  iOS のモードは接続先ポートのブリッジ任せになり、XCUITest を掴んだときだけ
  **Compose のダブルタップと Flutter のピンチが実行時と食い違う**(理由と実測は docs/commands.md)。
  上の「探索と実行は同じデバイスで」がここでは「同じモードで」まで含む。
- **人間チェックポイント(🧑)では停止**して、テストの意図・期待結果を確認する。何をテストしたいのかは
  エージェントが勝手に決めない。ただし確認は**推奨案を1つ出して短く承認を取る**形にする(多肢の重い
  設問で意思決定を丸投げしない。セレクタ・経路・後始末など既定で決められることは決めて進める)。
- **各書き込みの後にコンパイル検証ゲートを通す**(`ft_list_scenarios` の自動ビルド、または
  `swift build --product fleetest-scenarios-<proj>`)。緑になるまで次へ進まない。
  **緑になったら実行の前に dry-run**(ステップ4.5)。デバイスを1台も使わずに「コンパイルは通るが
  何も検証していない」を落とせるので、デバイスで1回試してから気付くより安い。
- **報告での呼び方**: Simulator・Emulator を「実機」と呼ばない。「実機」は USB でつないだ本物の iPhone /
  Android だけ(実行プロファイルの `kind: "physical"`)。どちらか分からなければ「デバイス」と書く
- TestProjects/ 配下のシナリオはユーザー資産。**既存 .swift を勝手に上書き・整形しない**。追記か新規ファイル。

## 前提の確定(最初に1回)

- **プロジェクトと WORK_DIR**: シナリオは `WORK_DIR/TestProjects/<プロジェクト>/scenarios/` に住む。
  TestProjects/ が1つならそれ。複数なら🧑どれかを確認する。
- **fleetest CLI の在り処**: clone 構成は `swift run fleetest ...`、外部パッケージ構成は
  `../foundation-tester/.build/debug/fleetest ...`(判定は `Sources/FTScenarioRunner/` の有無)。
  以降 `fleetest` はこれを指す。MCP(`ft_*`)が使えるならそちらを優先。
- **プラットフォーム**: iOS か Android か。**両対応なら platform は書かない**(同じコードが
  `--profile ios-run` と `--profile android-run` の両方で走る)。片方の OS でしか意味を持たないときだけ
  `@TestClass(platform: "ios")` / `@Test(..., platform: "android")` を書く ——
  宣言した OS を回さない run では skipped(対象外)として記録され、失敗にならない。
  **プロファイルの登録状況は、アプリが片方専用だという根拠にならない** —— 実行プロファイルもアプリ
  プロファイルの ios / android 欄も、まだ片方しか登録していないだけのことが多い。**利用者が片方専用だと
  言ったときだけ** platform を書き、分からなければ書かない(書かなくても、登録した OS の run でだけ走る)

## 手順

### 1. 🧑 対象アプリ(アプリプロファイル)を確認

**bundle ID を推測・探索で決めない。プロジェクトに登録済みのアプリプロファイルから選ばせる。**

1. `TestProjects/<proj>/profiles/apps/*.json` を列挙する(または `fleetest profile list`)。各ファイルの
   `ios.appName`/`android.appName`(表示名)と `ios.app` / `android.app`(bundle ID・パッケージ名)を読む。
2. 🧑 **どのアプリプロファイルを対象にするかをユーザーに確認**する(選択ダイアログ。候補が
   1つでも確認する)。**確認した bundle ID をコードに書いてはいけない** —— 対象アプリは
   実行プロファイル(`profiles/runs/<name>.json` → アプリプロファイル → 実行中 platform の
   `ios.app` / `android.app`)から解決される。ここで確認するのは、**実行時にどの実行プロファイルを
   使うか**と、スナップショット採取をどのアプリに対して行うかを決めるため。
3. アプリプロファイルが1つも無い、または対象アプリが未登録なら**ここで停止**し、`/fleetest-profiles`
   でプロファイルを作るよう案内する(bundle ID を勝手に発明しない)。

続けて確認する:

- **プラットフォーム**(ios / android / 両対応)。選んだアプリプロファイルに ios/android の
  どちらのセクションがあるかとも突き合わせる。
- **テストしたい振る舞い**:どの画面から始め、何を操作し、何が見えれば成功か。
  1シナリオ=1つの意味あるフロー。長すぎるなら @Test を複数に分ける相談をする。
- 既存クラスに @Test を足すのか、新規クラス(新規ファイル)なのか。

### 2. デバイスを用意してライブ探索(セレクタ採取)

**相乗り禁止**: ライブモニターが対象デバイスで稼働中なら、その機に `ft_*` を相乗りさせるとデモが凍る。
別デバイスを使うか、モニターを止めてから行う。

**以下すべての `ft_*` に `profile=<実行プロファイル名>` を渡す**(上の原則。渡さないと既定ポートの
別デバイスを見てしまう)。初回はブリッジのコールドスタートで分単位かかることがある。

1. `TestProjects/<プロジェクト>/workspace/scripts/compose.yaml` にサービスの宣言があれば(コメントだけの雛形は除く)、探索の前に
   `ft_services`(`action: up`・同じ `profile`)で起こす。終わっても `down` しない(`ft_start_run` が引き取って起こし直す)。
   `ft_run_scenario` はサービスを起こさないので、書いている途中の確認もこの `up` が前提。
2. `ft_status`(profile 指定)で接続を確認。未起動なら実行プロファイルのデバイスを起動しておく。
3. `ft_launch`(bundleId=対象アプリ・profile 指定)で先頭画面へ。
4. **画面ごとに `ft_snapshot`** を撮り、各行 `[ref] Type "label" id=... (x,y WxH)` から
   **セレクタに使う id / ラベル / 型を控える**。`ft_tap` / `ft_type` / `ft_swipe`(ref 指定)で
   フローを1手ずつ進め、遷移の各画面でまた snapshot する。これが CAE の action と expectation の素になる。
   **最初の `ft_snapshot` に `interactiveOnly: true` を渡す**(以後の木を返す呼び出しにも引き継がれる)。レイアウトだけの行
   (ラベルも値も無く、操作もスクロールもしない行)を省くので木が半分〜3分の1になり、ラベル・値を持つ行(検証に使う文字)は残る。
   **通った画面は撮っておく** —— `ft_snapshot` は撮った `#id` をプロジェクトの台帳に貯め、
   ステップ4.5 の dry-run が綴り誤りの照合に使う(撮っていない画面の id は照合できない)。
   **長いリストは `ft_swipe` を繰り返さず `ft_scroll_to`(selector 指定)を使う** —— 要素の上で
   止まったうえで撮り直した一覧を返すので、送りすぎ・古い ref のまま叩く事故が起きない。
   スクロールする領域が画面に複数あるなら `scrollFrame`(容器の `#id`)も渡す ——
   **どれが容器かは行末の `scroll` 印**で分かり、2つ以上あるときは snapshot の先頭でも名指しされる
   (印が無い = スクロールしない、ではない。Compose / Flutter の in-app は申告できないので、
   その場合は `scrollFrame` 無しで試してから考える)。
   **`⚠️scroll-leftover` が付いた行は、その座標に別のものが描かれていることがある**
   (スクロールで容器の外へ出た残り)。タップは通るが警告が返るので、**セレクタとして採る前に
   `ft_scroll_to` で可視域へ入れ直す**(採ったセレクタ自体は正しいので、慌てて別の `#id` を探さない)。
5. 出るか不定なダイアログ(権限・初回オンボーディング等)があれば、出た/出ないの両方を観察して
   `ifCanSelect` で無害化する対象を把握する。
6. **コントロールが期待通り動かない**とき(タップしても遷移しない等)は snapshot 往復で粘らず
   `ft_screenshot` を1枚撮って地の状態を確認する(選択中タブ・実際の着地画面が即分かり、tree の
   取り違えか実挙動かを切り分けられる)。
7. **探索は原因特定に足る最小手数で切る**。SUT 側の不具合(操作が効かない・別画面へ遷移する等)は
   **再現が2-3回取れたら深追いせず**、その経路を諦めて別経路へ回す。ここは🧑ポイント: 見つけた不具合を
   伝え、**回り込み経路を1つ推奨**して承認を取る(不具合の扱い=報告のみ/バグ再現シナリオ化 も一言添える)。

**探索が終わったら `ft_draft_scenario` で雛形を得る**。直前の `ft_launch` 以降に `ft_*` で行った操作を、
その時点で推奨されたセレクタで Swift に起こして**文字列で返す**(ファイルは書かない = ステップ3で置く)。
安定したセレクタが無かった手は TODO コメントで残る。返ってきた番号付きの手順一覧を読み、寄り道・
やり直しを `drop:` / `lastN:` で落として撃ち直す。**expectation は必ず空で返る**(アサーションを推測しない)
ので、ステップ2で撮った画面をもとに自分で埋める。

拡張のライブ操作パネルで**録画**して雛形を得る手もある(`fleetest api gen-scenario`)。その場合も
生成された仮セレクタを snapshot の実物と突き合わせて確定させる。

### 3. シナリオ .swift を書く

**書く直前に `<クローン>/.claude/skills/fleetest-scenario/dsl-reference.md` を Read で読む**(構造・コマンドの表・
セレクタ式・セレクタ選定の罠。`<クローン>` は fleetest 本体のクローン = 外部構成なら作業フォルダの隣の `../foundation-tester`、
クローン構成ならリポジトリの直下)。探索の段では要らないので、ここで初めて読む。
`TestProjects/<proj>/scenarios/<日本語可のファイル名>.swift` に、そのリファレンスに従って書く。
命名: クラス名は日本語可、@Test メソッドは `S0010`, `S0020`, …(10刻み)。@Test の説明は「〜できる」。

```swift
// <ファイル名>.swift
import FTDSL

@TestClass                                 // 対象アプリは実行プロファイルが決める(app: は書かない)
                                           // その OS でしか意味を持たないなら @TestClass(platform: "ios")
class ログインできること {

    @Test("メールとパスワードでログインできる")
    func S0010() {
        scenario {
            scene(1, "ログイン画面を開く") {
                condition {
                    launchApp()                      // 引数省略 = 実行プロファイルが決めた対象アプリ
                }.expectation {
                    exist("#email")                  // 実 snapshot の id を使う
                    exist("#password")
                }
            }
            scene(2, "資格情報を入れて送信する") {
                action {
                    type("#email", account("[user1].id"))           // 入力は type(sel, text)。資格情報は直書きしない
                    type("#password", account("[user1].password"))
                    tap("#login_btn||ログイン")       // id か ラベル(節の順で先に見つかった方)
                }.expectation {
                    exist("ようこそ")                 // 着地画面の実ラベル
                }
            }
        }
    }
}
```

**画面の解像度に依存しない形で書く**(必須)。採取したときの端末で緑でも、**背の低い端末では
落ちる**(逆向きも同じだけ起きる)。守るのは4つ:

- **折り返しの下にある要素は `tap("#id", scroll: .down)` か `scrollTo` で到達させる**。
  探索時に見えていたからといって `tap` だけで書かない —— 画面が短いと**木にすら載らない**
- **送りの始点・終点は、その画面で確実に窓の中に居る要素だけ**を使う。見切れた要素は
  クランプされた座標を返すので、そこから払っても容器に当たらず1pt も動かない
- **`notExist` を「画面外へ出た」の観測に使わない**。リストは画面外の行を数行ぶん木に残す
  (残す数は窓の高さで変わる)。不在で確かめたいなら、**確かめたい端末の実測**で距離を決める
- **上端の表示と下端のボタンのように対で検証する2要素**は、狭い画面で同時に見えるか探索時に
  確かめる。同時に出せないなら、送って読み返す形にせず**検証の組み立てを変える**
  (送ると `:above()` / `:below()` の相手がクランプされた残骸になり、判定が成立しない)

### 4. コンパイル検証ゲート

- MCP: `ft_list_scenarios`(project 指定)を呼ぶ。自動ビルドされ、**コンパイルエラーはそのまま返る**。
  緑なら新シナリオ ID(`クラス名.S0010`)が一覧に出る。
- CLI: `swift build --product fleetest-scenarios-<proj>`(exit code で判定。`--target` は不可 = リンクしない)。

エラーが出たら直して再検証。緑になるまで次へ進まない。

- ビルドが `Could not find target 'fleetest-scenarios-<proj>...'` で落ちたら、そのプロジェクトが
  Package.swift に未登録(手動 clone / git pull 後にありがち)。**`fleetest project sync`** でマーカー
  区間を再生成してから再検証する(Package.swift のマーカー区間は自動生成・手編集しない)。
- **コマンド名の当てずっぽうを避ける**: 存在しない名前はコンパイルエラーになるが、`fleetest api
  dsl-commands`(デバイス不要・JSON)で名前・引数・`exist` へのチェーン可否を先に引ける
  (`--name tap` / `--category scroll` で絞る)。他ツールの名前(`assertExists` `waitFor` `click`
  `sleep` `swipeUp` 等)を書くと、コンパイラが fleetest での書き方を指して落ちる。

### 4.5. dry-run ゲート(デバイス不要・数秒)

**コンパイルの次・デバイス実行の前に必ず1回**。デバイスを1台も使わずに、セレクタの構文誤りを
失敗として落とし、**アサーションが0個の expectation** と台帳に無い `#id` を ⚠️ 行で言う(どれも
コンパイルは通り、デバイス実行では「なぜか緑」になって気付けない類)。**⚠️ 行は失敗扱いではない**
(結果は passed のまま)が、放置してよい意味ではない。

- MCP: `ft_dry_run`(id=`クラス名.S0010`, project 指定)
- CLI: `fleetest run --project <proj> --dry-run --scenario <クラス名.S0010>`

⚠️ 行が出たら直してから次へ進む:

| 出る警告 | 意味 | 直し方 |
|---|---|---|
| `contains no assertions` / `no assertions at all` | 操作しただけで何も検証していない | expectation に `exist` / `textIs` / `thisIs` 等を足す |
| `no snapshot taken for this project contains this id` | その `#id` は、**ステップ2で撮ったスナップショットのどれにも無い** = 綴り誤りの疑い | スナップショットの実物と突き合わせる。まだ撮っていない画面のものなら `ft_snapshot` を撮り直す(撮った時点で台帳に入る) |

id の照合は**ステップ2で `ft_snapshot` を撮った画面ぶんだけ**効く(`ft_snapshot` が
`<プロジェクト>/.fleetest/selector-inventory.json` に貯める)。**撮らずに書いたシナリオでは
何も言わない**ので、セレクタを推測で書かない原則は変わらない。ラベルとワイルドカード
(`#row_*`)は照合対象外。

### 5. 🧑 実行して意図通りか確認

ユーザーに実行してよいか確認してから(聞くときもデバイスは名前と種類で呼ぶ —「iPhone 17 Pro の Simulator で
実行してよいですか」。**Simulator・Emulator を「実機」と書かない**。報告も同じ):

- MCP: `ft_run_scenario`(id=`クラス名.S0010`, profile=実行プロファイル)。失敗すると結果が
  isError になり、失敗したステップのエラー・**失敗した瞬間の要素一覧とスクリーンショット**・
  レポートパスが返る。**直すときはまず要素一覧を読む**(画像からは `#id` を読めない)。
  そこに無いものが画面にあるなら、別ウィンドウ・システムアラートの覆いを疑う。
  ロケータのブレを吸収したいときだけ `heal: true`(ロケータの指紋照合。FM は使わない)。
- 利用者に全部の実行を頼まれたら `ft_start_run`(profile=実行プロファイル。`fleetest run --profile` と同じで
  結果の履歴・録画が残る)。裏で始まってすぐ返るので、`ft_run_status` で進み具合と結果を引く。

レポートで期待通りか確認する。セレクタがヒール修正提案付きで通っている場合は、提案を人がレビューして
ソースを実ラベルに直す(design.md §10「ロケータの指紋」)。

### 6. 仕様違反のバグ起票(testbase を根拠に書いたときだけ)

testbase(SC/TC 等の仕様書)を根拠に書いたシナリオが仕様どおりに動かなかったら、**`<クローン>/.claude/skills/fleetest-scenario/defects.md`** を読んで、その手順で起票する(仕様違反を緑で隠さない)。
