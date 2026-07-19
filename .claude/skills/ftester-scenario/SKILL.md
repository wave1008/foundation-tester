---
name: ftester-scenario
description: セットアップ済みのプロジェクトに、Swift DSL のテストシナリオ(.swift)を1本作成する。テスト対象アプリを実機/仮想機で実際に操作しながら画面スナップショットから実セレクタを採取し、@TestClass/@Test/scene(CAE)の形に落として、コンパイル検証まで通す。「シナリオを書いて」「テストコードを作って」「〇〇のテストを追加して」「この画面遷移をテストにして」等の依頼で使う。まだセットアップ前なら /ftester-setup、対象アプリ/デバイスの登録が無ければ /ftester-profiles。
---

# ftester シナリオ作成 runbook

既存プロジェクト(`ftester init` / `ftester project create` 済み・アプリ/デバイス/実行プロファイルが
ある)に、**1本のテストシナリオ .swift** を作る。DSL の正典は docs/design.md §10「Swift DSL」と
README.md「Swift DSL」節。ここはエージェントが順に実行するための手順書。

未セットアップなら `/ftester-setup`、対象アプリ・デバイス・実行プロファイルが無ければ `/ftester-profiles`。

## 進め方の原則

- **セレクタは推測せず、実画面から採取する**。id / ラベル / 型は `ft_snapshot`(または拡張のライブ操作
  パネル)が返す実物だけを使う。想像で `#login_btn` 等を書かない — セレクタの取り違えは design.md §10 が
  列挙する通り「たまに緑」の切り分け不能バグになる。
- **人間チェックポイント(🧑)では停止**して、テストの意図・期待結果を確認する。何をテストしたいのかは
  エージェントが勝手に決めない。ただし確認は**推奨案を1つ出して短く承認を取る**形にする(多肢の重い
  設問で意思決定を丸投げしない。セレクタ・経路・後始末など既定で決められることは決めて進める)。
- **各書き込みの後にコンパイル検証ゲートを通す**(`ft_list_scenarios` の自動ビルド、または
  `swift build --product ftester-scenarios-<proj>`)。緑になるまで次へ進まない。
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

1. `ft_status` で接続を確認。未起動なら実行プロファイルのデバイスを起動しておく。
2. `ft_launch`(bundleId=対象アプリ)で先頭画面へ。
3. **画面ごとに `ft_snapshot`** を撮り、各行 `[ref] Type "label" id=... (x,y WxH)` から
   **セレクタに使う id / ラベル / 型を控える**。`ft_tap` / `ft_type` / `ft_swipe`(ref 指定)で
   フローを1手ずつ進め、遷移の各画面でまた snapshot する。これが CAE の action と expectation の素になる。
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
                    tap("#login_btn||ログイン")       // id 優先、ラベルをフォールバック
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

### 5. 🧑 実行して意図通りか確認

ユーザーに実行してよいか確認してから:

- MCP: `ft_run_scenario`(id=`クラス名.S0010`, profile=実行プロファイル)。失敗時はトリアージと
  レポートパスが返る。ロケータのブレを吸収したいときだけ `heal: true`。
- CLI: `ftester run --project <proj> --profile <prof>`(全実行)。

レポートで期待通りか確認する。セレクタがヒール修正提案付きで通っている場合は、提案を人がレビューして
ソースを実ラベルに直す(design.md §10「ヒールキャッシュ」)。

---

## DSL リファレンス(design.md §10 の要点。正典はそちら)

### 構造

- `@TestClass(app:platform:)` クラス → `@Test("説明")` メソッド(ID は `S0010` 形式)→ `scenario { }`
  → `scene(n, "題")` → **condition / action / expectation**(CAE)の3層。
  - `condition` = 前提(通常 `launchApp()`)、`action` = 操作、`expectation` = 検証。
  - チェーンで書く: `condition { … }.action { … }.expectation { … }`。不要な層は省略可。
- コマンドは**同期・非 throw のモジュールレベル関数**。`try`/`await`/`{ it in }` 不要。カレント
  コンテキストを暗黙参照する。
- 失敗セマンティクス: コマンド NG → その scene の以降はスキップ → 次の scene へ(throw しない)。
  scene 全体を即中断したいときは `abortScenarioOnFailure()`。
- `@Deleted("理由")` をクラス/メソッドに付けると論理削除(一括実行から除外・完全一致 ID でのみ実行可)。

### コマンド

| 分類 | コマンド |
|---|---|
| タップ/入力 | `tap(sel, optional:, timeout:)` / `type(text)`(直前フォーカス)/ `type(sel, text)` / `press(sel, duration:)`(長押し) |
| スワイプ/スクロール | `swipe(.up/.down/.left/.right)` / `scrollTo(sel, direction:, maxSwipes:)` |
| 検証 | `exist(sel)` / `textIs(sel, 期待)` / `valueIs(sel, 期待)` / `screenIs(名)`。exist は `.textIs()/.valueIs()` チェーン可 |
| アプリ制御 | `launchApp(bundleID?)` / `relaunchApp()` / `terminateApp()` / `home()` / `appSwitcher()` |
| 待機/分岐 | `wait(秒)` / `ifCanSelect(sel, waitSeconds:) { … }.ifElse { … }` / `ios { }` / `android { }` / `procedure("名") { try await … }` |

- `optional: true` = 見つからなくても失敗にしない。`timeout:` = ロケータ再試行の上限秒(0=即諦め、
  省略=約0.7秒)。出るか不定な optional ステップの空振り短縮に使う。
- 同じ手順を関数に切り出して使い回してよい(private func。例: 不定ダイアログの `dismiss…IfAny()`)。
- `procedure` は任意 Swift(データ準備等)を1ステップとして記録。throw すると NG 扱いで scene 中断。

### セレクタ式(文字列1本・`||` でフォールバック連鎖)

- `#id` — id 完全一致(最も頑健。可能なら第一候補)
- `ラベル` — label(**完全一致優先 → 無ければ部分一致**)
- `.Type` / `.Type[2]` — 型(+順番、**1 オリジン**。1番目は [1] 省略可)
- `.Type#id` / `.Type=ラベル` — 型で絞る
- `=ラベル` — `#` や `.` で始まる**生ラベル**を label として扱うエスケープ
- 例: `tap("#login_btn||ログイン||.Button")` = id → ラベル → 型の順で解決を試みる

### セレクタ選定の罠(そのまま踏む。design.md §10 実測)

- **短いラベルは誤マッチする**。`"許可"` が `"通知を許可"` に、`"ディスプレイ"` が別項目の要約
  `"ディスプレイ、操作、音声"` にも当たり「曖昧解決不能」で失敗する。→ 実 UI の**完全ラベル**
  (`"ディスプレイとタップ"`)に寄せるか、`#id` / `.Type=ラベル` で型を絞る。id は常に完全一致。
- **`||英語` フォールバックは英語ロケール機でのみ発火**。ja-JP フリートでは日本語プライマリが唯一の
  頼り。プライマリを対象 OS/ロケールの実ラベルに合わせて維持する(OS 改名で即ハード失敗)。
- **id を一切公開しないアプリ**では label/型でしか指せず、戻る/アイコンボタン等の**無ラベル要素は
  `.Type[n]`(順序依存で脆い)でしか指せない**。position で採取し、指定にコメントを添える。id があれば
  頑健なので、テスト容易性の改善提案(主要導線への accessibilityIdentifier 付与)も併せて伝えてよい。
  - **`.Type[n]` は画面状態で指す要素が変わる**(一覧では削除ボタン、空表示では別ボタン/タブ 等)。
    破壊的・index 指定の tap は、**意図した状態のみ出るマーカーで `ifCanSelect` ガード**してから撃つ。
  - **件数不定の一括操作は DSL にループが無い**ので、この**ガード付き反復を上限回数ぶん並べて**表現する
    (空になればガードが空振りして残りは無害。上限は想定最大件数に合わせる)。
- **`exist`/`textIs`/`valueIs` は非スクロール**(現在画面のみ)。折り返し下の項目は先に
  `scrollTo(sel, maxSwipes:)` で送ってから確認する。
- **アニメーション中は座標がずれる**。メニュー展開・シート表示・表示切替の直後は `wait(1)` を挟む。
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

### 命名・配置

- ファイル: `Projects/<proj>/Scenarios/<日本語可>.swift`(`_Main.swift` は触らない = エントリポイント)。
- クラス名は日本語可。@Test メソッド名 `S0010`/`S0020`/…(10刻み)。実行 ID は `クラス名.メソッド名`。
- 深い階層に置いてよい(`Scenarios/Demo/…`)。objc 走査で自動発見される。
