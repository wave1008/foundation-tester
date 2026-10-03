---
name: fleetest-profiles
description: fleetest のアプリプロファイル・実行プロファイルを1回のフローでまとめて作成する。最初に iOS/Android を確認し、アプリの表示名・アプリIDを聞き(パッケージパスは聞かない)、デバイスは指定があればそれで、無ければそのマシンで利用可能な最新OSの仮想デバイス(無ければ作成)で用意する。「プロファイルを作って」「デバイスとアプリと実行プロファイルをまとめて用意して」「テスト対象を追加して」等の依頼で使う。
---

# fleetest プロファイル一括作成 runbook

> **ユーザーへの質問・報告・チェックポイントはユーザーの言語で行う**。
> この手順書は日本語だが、読者はエージェントであり利用者の言語とは独立している
> (英語話者にはダイアログ・報告文をすべて英語で出す)。


> **スキルの呼び出し記法はエージェントごとに違う**(Claude Code は `/fleetest-setup`)。
> 以下は `/` 形で書くので、別の記法のエージェントではそちらへ読み替える。

1つのアプリ×1プラットフォーム分の **アプリ/実行プロファイルの二点セット** を作る。
プロジェクトが無ければこのフローが作る(下の「プロジェクトと WORK_DIR」)。fleetest のパッケージ自体が
無い(Package.swift が無い)ときだけ `/fleetest-setup` を案内する。

## 前提の確定(最初に1回)

- **プロジェクトと WORK_DIR**: プロファイルは `WORK_DIR/TestProjects/<プロジェクト>/profiles/` に住む。
  TestProjects/ が1つならそれ。複数なら🧑どのプロジェクトかを確認する。
  **プロジェクトが1つも無ければ作る(名前は常に `project1`。VSCode 拡張の自動作成と同じ名前で、名前は聞かない)**:
  ステップ1・2でプラットフォームとアプリIDが決まった後、`fleetest project create project1
  [--app-id <アプリID>]` を実行してからステップ3以降へ進む(`--app-id` はデモシナリオにだけ入る。
  プロファイルは書かない = ステップ3以降の `profile setup` が作る)(プロジェクト名は以降 `project1`)。
  WORK_DIR に fleetest のパッケージ(`Package.swift` に fleetest の依存か `foundation-tester` の記述)が無ければ
  作らず `/fleetest-setup` を案内する。
- **fleetest CLI の在り処**: clone 構成は `swift run fleetest ...`、外部パッケージ構成は
  `<TOOL_ROOT>/.build/debug/fleetest ...`(TOOL_ROOT は WORK_DIR/Package.swift の `.package(path:)` から
  解決。無ければ既定の `../foundation-tester`。判定は `Sources/FTScenarioRunner/` の有無)。
  以降 `fleetest` はこれを指す。
- **原則**: 各書き込みの後に検証ゲート(`fleetest profile list`)を通す。🧑 は停止して確認する。
  **既に分かっている値は聞き直さない** — 依頼文や会話でプロジェクト名・アプリ表示名・アプリID・
  プラットフォームが示されていれば確定済み。**足りない値だけ**を聞く
  (同じことを二度聞かれるのは、受け手にとって最も目に付く無駄)。
  **人に聞くときは必ず選択ダイアログ(Claude Code なら AskUserQuestion)を使う** — チャットに質問文を書いて答えを待たない
  (テキストで聞くと見落とされ、フローが止まる)。自由入力は Other で受ける。
  「それ以外のパラメータは既定」— 明示的に聞いた値以外は書かない(未指定=デフォルト)。

## 手順

### 1. 🧑 プラットフォームを確認

まず **iOS か Android か** をユーザーに確認する(選択ダイアログ)。以降 `<plat>` = `ios` または `android`。

### 2. 🧑 アプリ情報を確認

次の2つを聞く(自由入力):

- **アプリの表示名**(`appName`。例 `SUT Store`)—— **ホーム画面でアイコンの下に出る名前そのもの**を聞く。
  `tapAppIcon()` の既定の探し先と、システムアラートがこのアプリのものかの判定に使うので、
  区別のための注記(「(実機)」等)や略称を足さない(食い違うと iOS は run 開始時に警告が出る)
- **アプリID**(iOS は bundle ID、Android はパッケージ名。例 `com.sutec.mobile`。
  **分からなくても中断しない**: 仮の ID `com.example.myapp` を `--app-id` に渡して
  進め、実行前に `profiles/apps/` の `app` を実IDへ差し替える必要があることを 🧑 に伝えて
  ステップ7の報告にも残す)

**パッケージパス(`appPath`)は聞かない**。ユーザーが自発的に伝えてきた場合のみ使う
(ビルド済み `.app`/`.apk`。相対は WORK_DIR 基準・`~`・絶対可)。未指定なら省略する
(後から `profiles/apps/` を編集して向けられる)。

`appRef`(アプリプロファイルのファイル名)は既定で対象 OS 名(`ios` / `android` / `hybrid`)になる。
`--app-ref` は渡さない(既存の実行プロファイルがあればそのアプリプロファイルを使い続ける)。

### 3. 🧑 デバイスの指定を確認

**「デバイスについて指定したいものはあるか」** を聞く。指定できるのは:

- 機種(iOS: シミュレータ機種 / Android: AVD デバイス定義)
- OS バージョン(iOS: ランタイム / Android: システムイメージ)
- デバイスの論理名(実行プロファイルから参照する `name`)

**指定がなければ既定**: そのマシンで **利用可能な最新 OS** の仮想デバイスを使う。無ければ作成する
(下のステップ4のアルゴリズム)。論理名の既定は「機種(OS)-NN」(例 `iPhone 17 Pro(iOS 27.0)-01` / `Pixel 10(Android 16, API 36, APIs)-01`。`--auto-device` が付ける)。

### 4. プロファイルを作る(**1コマンド。JSON は手書きしない**)

アプリ/実行の2ファイルは `fleetest profile setup` が整合させて書く(冪等・再実行可。
書くデバイスは常にこの Mac(`"machine": "local"`)。別の機械のデバイスを足すときは「完了後」を参照)。
**デバイスの選定もコマンドに任せる**(`--auto-device`)。
`fleetest api device-catalog` / `simctl list` / `emulator -list-avds` を別々に叩かない
(承認回数が増えるだけで、選定規則はコマンド側に入っている):

```
fleetest profile setup --project <プロジェクト> --platform <ios|android|hybrid> --auto-device \
  --app-id <アプリID> --app-name "<表示名>" [--app-path <パッケージパス>] [--app-ref <ref>]
```

- `--auto-device` の選定規則: **iOS = ランタイムは選択中の Xcode の SDK の版(`xcrun --sdk iphonesimulator --show-sdk-version`)に届く最新
  (導入済みが届いていなければ未導入と判定)、機種はそのランタイムが対応する `iPhone <N>`(装飾なし)ちょうどのうち N が最大
  (Pro・Pro Max・Plus・Air・Duo・e・mini・SE・iPad は除く)** /
  **Android = 機種は最新の Pixel スマートフォン(`avdmanager list device` の id が `pixel_<数字>` か `pixel_<数字>a` ちょうどのうち数字が最大。
  同じ数字なら無印を優先。`pixel_9_pro` `pixel_fold` 等の装飾つきは除く)、システムイメージは tag `google_apis`・この Mac の ABI で API レベルが最大のもの
  (導入済みとダウンロード可能の合算。同じ API なら導入済み)**。登録するのは**その機種・OS の「機種(OS)-NN」**:
  手元に同じ形の名前があり、かつ**中身(iOS = 機種+runtime / Android = 機種+system image)も選定結果と同じ**なら番号最小のものを再利用し
  (冪等。同じ形の名前なら拡張で作ったデバイスもそのまま使う)、無ければ**空いている最小の番号**(`-01` が別の中身で埋まっていれば `-02`)で
  専用の仮想デバイスを新規作成する。OS 部分は iOS = runtime 名(`iOS 27.0`)/ Android = `Android 16, API 36, APIs`
  (例 `Pixel 10(Android 16, API 36, APIs)-01`)。**利用者の既存シミュレータ/AVD は改名も削除もしない**。
  iOS のランタイムが未導入なら、**デバイスを新しく作る直前に `xcodebuild -downloadPlatform iOS` で自動導入する**
  (ライセンス承諾のフラグは要らない。**数 GB のダウンロードで数分〜数十分かかり、コマンドはその間返らない**。
  事前に本人へ時間がかかる旨を伝え、出力を待つ。再利用できる既存デバイスがあれば導入しない。ランタイムだけを先に入れたいときは `fleetest api install-ios-runtime --version <SDK の版>`。導入済みなら何もせず、SDK の版と違う版は拒む)。
- **`profile setup` が「システムイメージのライセンス承諾が必要」と言って止まったら**(Android で選ばれたイメージが未導入のとき。
  何も導入せずに止まる): メッセージの package・サイズ・ライセンスを示し、選択ダイアログで本人に承諾してよいか聞く。
  承諾なら**同じコマンドに `--accept-licenses` を足して**再実行する。**本人の承諾なしに勝手に付けない**。
- `--platform hybrid` で iOS と Android を1回で作る(論理名はそれぞれ「機種(OS)-01」)。
  `--platform` はアプリプロファイルの対象 OS(`platform`)にも書かれる。既存のアプリプロファイルに別の OS を足すと `hybrid` になる。
- 機種/OS をユーザーが指定した場合だけ `--auto-device` を外し、実体を明示する
  (iOS: `--device-name "<シミュレータ名>" --os <version>` か `--udid`、Android: `--avd <avdID>` か `--serial`)。
- 仮想デバイスを**新規作成**する必要があるとき(0台・指定に合うものが無い)は
  `fleetest api create-device`(→ 下の 4-b)で作ってから、`profile setup --device-name <作った名前>` を呼ぶ。
- `--app-path` は入力があったときだけ渡す(渡すと `autoInstall` が有効になる)。
- **台数の指定があれば**(例「デバイスは2台にして」): `--auto-device` は1回で1台(`-01`)しか登録せず、
  呼び直しても同じ `-01` を再利用する。2台目以降は `-01` と同じ機種・OS で、空いている番号(`-02` …)を使い 4-b の
  create-device で作り、`profile setup --device-name <作った名前>` で同じ実行プロファイルへ追記する。
  ステップ5の報告に全台を並べる。

#### 4-b. 新規作成が要るとき(create-device)

```
fleetest api create-device --project <プロジェクト> --profile <実行プロファイル名> \
  --platform <plat> --name "<論理名>" --model "<機種 identifier/id>" --os "<ランタイム identifier / システムイメージ package>"
```

`--model` / `--os` の値は `fleetest api device-catalog` の
`ios.deviceTypes[i].identifier` / `ios.runtimes[i].identifier`(Android は `android.models[i].id` /
`android.systemImages[i].package`)。**このカタログ取得は新規作成のときだけ**行う。
`--name` は「機種(OS)-NN」の形(例 `iPhone 17 Pro(iOS 27.0)-01` / `Pixel 10(Android 16, API 36, APIs)-01`。括弧は半角で機種名との間に空白を入れない・連番は2桁)を勧める。

Android のシステムイメージは同じ OS バージョンでも Play Store 版(`...;google_apis_playstore;...`)と
Google APIs 版(`...;google_apis;...`)がある。**指定が無ければ `google_apis` を選ぶ**
(モニターの「デバイスを追加」の既定と揃える。Play ストアが要るテストのときだけ playstore 版)。

Android で `android.models` が空(`android.errorCode` = `avdmanager-missing`)なら cmdline-tools が
未導入。`fleetest api install-cmdline-tools` で導入できる(約150MB・数分)。**勝手に走らせず**
選択ダイアログで導入の可否を聞いてから実行し、終わったら device-catalog を取り直す。

### 5. 検証ゲート

```
fleetest profile list --project <プロジェクト>
```

作った実行プロファイル `<plat>` が **アプリ名・デバイス @ マシン名** まで解決し、`❌`/`⚠️` が出ない
ことを確認してユーザーに要約報告する。赤が出たら原因(デバイス名の不一致・アプリパス不在など)を
そのまま見せて相談する。

## 完了後

- 実行: エージェントは `ft_start_run`(profile=`<plat>`。進み具合と結果は `ft_run_status`)。人が端末から打つなら
  `fleetest run --project <プロジェクト> --profile <plat>`。どちらも仮想デバイスか実機が要る。
- 別プラットフォームや別アプリを足すときは、この `/fleetest-profiles` をもう一度実行する
  (実行プロファイルの `devices` には追記。別アプリは `--app-ref` で別のアプリプロファイルを追加)。
- **別の機械(リモートランナー)のデバイスを足すときは `fleetest profile setup`/`api create-device`
  を使わない**(どちらも `"machine": "local"` のデバイスしか作らない)。`fleetest remote machines add` で
  そのマシンを登録したうえで、`profiles/runs/<name>.json` の `devices` に
  `{ "platform": "...", "machine": "<登録名>", "name": "...", ... }` を直接追記するか、
  拡張のプロファイルタブの「デバイスを追加」で機械を選んで足す(→ `/fleetest-remote-setup`)。
