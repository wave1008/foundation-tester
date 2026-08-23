# リモートランナーのセットアップ

**別の Mac(ランナー機)へ SSH でジョブを投げ、結果を手元に受け取る**ための手順書。
設計と背景は [remote-runner.md](remote-runner.md)(こちらは読まなくてよい)。

## できること・できないこと

`ftester run --host <ホスト>` は「向こうの Mac で普通にローカル実行し、出力と成果物を
手元へ返す」だけの機能。**シナリオとプロファイルは実行のたびに自動転送される**ので、
編集は常に手元だけで行う。

| | 状態 |
|---|---|
| 1台のリモートへジョブ単位でディスパッチ(CLI・VSCode 拡張の両方) | ✅ |
| 実行中の進行表示・キャンセル・タイムアウト | ✅ |
| レポート・JUnit・録画・run ログの回収 | ✅ |
| ランナー機の導入・撤去を手元から1コマンド(`remote setup`) | ✅ |
| 複数ホストの一括診断・掃除(`remote status` / `remote clean`) | ✅ |
| リモートで単発の `ftester` を走らせる(`remote exec`) | ✅ |
| 複数ホストへの**同時**実行(フリート。`run --fleet`) | ✅ |
| 同一リモートへの二重ディスパッチの防止 | ✅ ロックで fail fast(`--force-lock` で奪える) |
| 1つのシナリオ集合を台数で**分散**する(ホスト間の分割) | ✅ `run --fleet <名前> --split` |
| リモート実行分が `ftester results` の集計に載る | ✅ 既定(`--remote-artifacts collect`)で回収され、そのまま集計・flaky 検出の対象になる |
| 複数エントリの JUnit を1ファイルに集約 | ✅ `run --fleet … --junit <パス>` |
| リモート機のデバイス一覧の取得・作成・削除(プロファイル編集のダイアログから) | ✅ |
| モニターのデバイスタブでのリモートデバイスの表示・画面配信 | ✅ 状態・静止画・ライブ映像(2026-08-17。自動修復 watchdog はリモートの台を見ない) |

## 全体像

```
発行側の Mac(手元)                     ランナー機
ftester run --host mac2 …               ~/ftester-runner/               ← 専用ベースディレクトリ
  ├ 適合チェック(rev・Xcode)   ssh     ├── foundation-tester/          ← ツール本体のクローン(名前固定・共有)
  ├ 転送(rsync: シナリオ・設定) ────>  └── users/<issuerId>/work/      ← あなたの作業場所(発行者ごと)
  ├ 出力を受け取って表示                     ├── TestProjects/<プロジェクト>/
  └ 成果物を回収 <───────────────────      └── .build/
```

**ランナー機がそのマシン自身のために持っている foundation-tester(あれば)には一切触らない。**
リモートランナーは `~/ftester-runner/` 配下だけで完結する。

## ランナー機の前提

| 区分 | 前提 | 確認 |
|---|---|---|
| ハード | Apple silicon の Mac | `sysctl -n hw.optional.arm64` が 1 |
| Xcode | **発行側と同じ Xcode・同じ macOS**(不一致はディスパッチが止まる) | `xcodebuild -version` |
| ログイン | **コンソールにログイン済み**(いわゆる Aqua セッションが立っている) | `stat -f%Su /dev/console` がランナーのユーザー名 |
| 電源 | システムスリープ無効(ディスプレイスリープと画面ロックは可) | `pmset -g \| grep " sleep"` |
| ネットワーク | リモートログイン ON・鍵で入れる。画面共有 ON を推奨 | 下のステップ1 |
| Homebrew | **その macOS を知っている版であること**(古い brew は `unknown or unsupported macOS version` で**起動自体が失敗**し、`xcodegen` を入れられない) | `brew --version` が動くこと |
| ネットワーク | git が GitHub へ直接出られること(社内プロキシ設定が残っていると clone で数十秒待たされて失敗する) | `git config --global --get-regexp '^https?\.'` が空 |
| Android | Android SDK と AVD(Android を回すときだけ)。SDK は `~/Library/Android/sdk` か `ANDROID_HOME` で見つける(**シェルの rc は読まれない** —— ディスパッチは非対話 ssh なので `~/.zshrc` の PATH/ANDROID_SDK_ROOT は効かない。ツールは adb・emulator・bundletool の `--adb` を自力で解決するので、標準の場所にある限り設定は要らない) | `ftester doctor` |
| FM | システム言語が**英語** + Apple Intelligence 有効(`screenLooksLike` や自己修復を使うときだけ) | `ftester doctor --fm-only` |

**画面ロックはかけたままでよい**(セッションは消えない)。消えるのは再起動と電源断だけで、
そのときは人が1回ログインし直す必要がある(画面共有でよい)。

## ステップ0(ランナー機で1回だけ・手作業)

sudo や GUI が要るものはインストーラでは行わない(無人機に sudo プロンプトを混ぜると
冪等性と自動化が両方壊れる)。ランナー機の前に座るか、画面共有で行う。
**何が足りないかは機械で確認できる** —— ランナー機で `bash Scripts/preflight.sh --runner`
(または手元から `ftester remote setup <ホスト>`)を実行すると、残っている項目だけが列挙される。

1. **リモートログインを ON**: システム設定 → 一般 → 共有 → リモートログイン
2. **画面共有を ON**(強く推奨。再起動後のログインを手元からやるため)
3. **システムスリープを無効化**: `sudo pmset -a sleep 0`
4. **Xcode を導入**し、1回起動してライセンスに同意(`sudo xcodebuild -license accept` /
   `sudo xcodebuild -runFirstLaunch`)。**版は発行側と揃える**
5. **Homebrew** — `brew --version` が通ること。**しばらく更新していない機械は要注意**:
   古い brew は新しい macOS を知らず、コマンドが1つも動かない。その場合は
   `git -C /opt/homebrew fetch origin && git -C /opt/homebrew reset --hard origin/master` で更新する
   (`brew update` 自体が動かないため git で入れ替える)。`xcodegen` は install.sh が入れる
6. **git のプロキシ設定を確認** — `git config --global --get-regexp '^https?\.'` に
   使われていないプロキシが残っていると clone が失敗する（不要なら `--unset-all` で消す）
7. 必要なら Android SDK・AVD、FM を使うならシステム言語を英語にして Apple Intelligence を有効化
8. **ログインしたままにする**(ログアウトしない。ロックはしてよい)

## ステップ1(発行側): 鍵で入れるようにする

```bash
ssh-copy-id <ユーザー>@<ホスト>            # 初回だけパスワードを1回
ssh -o BatchMode=yes <ユーザー>@<ホスト> 'echo ok'   # これが ok を返せば準備完了
```

ディスパッチは `BatchMode=yes`(パスワード入力をしない)で接続するので、**この確認が通ることが
必須**。初回接続のホスト鍵確認(known_hosts への登録)はここで済ませる。

> `StrictHostKeyChecking` を無効にしない。ホスト鍵の検証は「知らないマシンへ
> プロジェクトを送り込んでしまう」経路を実際に塞いでいる唯一の仕掛け。

## ステップ2(発行側): ランナー機を用意する

**手元から1コマンド**で済む。ランナー機に ssh して手で入れる必要はない。

```bash
ftester remote setup <ユーザー>@<ホスト> --project <プロジェクト名>
```

何をするか(冪等。何度実行してもよい):

| ステップ | 内容 |
|---|---|
| local | 手元のプロジェクト解決(ここで落ちれば ssh に行かない) |
| reach | 到達確認とログイン状態の確認 |
| preflight | **手元の `Scripts/preflight.sh` を送って `--runner` で判定**。人手が要る項目が残っていれば、その一覧を出して止まる(直して同じコマンドを再実行) |
| install | **手元の `Scripts/install.sh` を送って**実行(`~/ftester-runner/users/<issuerId>/work` に**あなたの**受け手パッケージを作る。複数人で共有する場合は各自の分が並ぶ)。初回はコールドビルドで数分 |
| align | ランナー機のクローンを**手元と同じコミット**へ合わせて `swift build`(下記) |
| verify | `--profile`(と任意の `--scenario`)を渡すと**実ディスパッチを1本走らせる**。ここが通って初めてセットアップ成功 |

終了コードは install.sh と同じ語彙: **0 = 完了 / 2 = 必須は通ったが人手の項目が残っている / 1 = 失敗**。

- **`--project` は手元と同じプロジェクト名**(`TestProjects/<名前>`)。手元にプロジェクトが1つだけなら省略できる
- **スクリプトは curl ではなく手元から送る**。GitHub の main ではなく、**いま自分がいるコミットの
  スクリプト**を使うため(検証中のブランチでも版が揃う)
- 拡張・MCP・CLAUDE.md はランナー機には入れない(CLI だけで動く)
- プロファイル(machines/apps/runs)は**手元のものが実行のたびに転送される**ので、ここでは作らない
- 撤去は `ftester remote setup <ホスト> --uninstall`(確認あり。`--yes` で無確認)

> 手で入れたい場合は、上の install ステップと同じことを ssh して実行すればよい:
> `bash install.sh --work-dir ~/ftester-runner/users/<issuerId>/work --tool-root ~/ftester-runner/foundation-tester --name <プロジェクト名> --skip-extension --skip-mcp --skip-claude-md`。
> クローン先の**ディレクトリ名 `foundation-tester` は変えない**(SPM がパッケージ名をディレクトリ名から決めるため)。

## ステップ3: 版を揃える

ディスパッチは **git のコミット**と **Xcode/macOS の指紋**の2つを照合し、どちらかが違えば
**何も実行せずに止まる**(黙って古い版で走らせないため)。

**`remote setup` の align ステップが毎回これを行う**ので、手元でコミットを進めたら
`ftester remote setup <ホスト>` をもう一度流せば揃う。手で合わせるなら:

```bash
ssh <ホスト> 'cd ~/ftester-runner/foundation-tester && git fetch origin && git checkout <コミット> && swift build --product ftester'
```

- **照合はコミットの一致だけで、変更の中身は見ない** —— 手元(親)側にしか効かない修正
  (モニターの fan-out・結果の回収など)を取り込んだときも、**手元を更新したらランナーも align する**。
  「ランナーの挙動は変わらないから」と飛ばすと `remote status` が ⚠️ になり、ディスパッチは止まる
- **手元の未コミットの変更は届かない**(警告が出る)。ツール本体の変更を試すなら、
  コミットして push し、ランナー機をそのコミットに合わせる
- Xcode や macOS を更新したら**両方**を更新する。片方だけだと全ディスパッチが止まる
- `ftester remote align <ホスト>` だけでも揃う(`remote setup` の align ステップ単体。
  preflight/install は通さない軽量版)。VSCode 拡張は実行開始時に版ズレを自動検出し、
  「更新して実行 / キャンセル」のダイアログから更新できる(ズレたまま実行する選択肢は無い。
  更新で直せないズレ = 未 push・到達不能・toolchain 不一致は実行を止めて理由を出す)

## ステップ4: マシン名とプロファイル

実行プロファイルが参照する**マシンプロファイル**(どのデバイスを使うか)は、次の順で決まる。

1. 実行プロファイルが `machine` を明示していればそれ
2. 環境変数 `FT_MACHINE`(その回だけの上書き)
3. マシンプロファイルが1つしかなければそれ

複数あって `machine` も書いていなければ、**候補を挙げて止まります**(どれを使うか決められないため)。
「この Mac の登録名」という概念は廃止しました —— 名前1つに「機械の身元」と「どのデバイス群か」の
2つの意味が載っており、プロファイルを改名するとこの Mac の身元まで変わっていたためです。

ランナー機のデバイス構成が手元と違う場合は、そのためのマシンプロファイルを**手元で**作り
(転送されます)、実行プロファイルの `machine` でそれを指します。

```
TestProjects/<プロジェクト>/profiles/machines/<名前>.json   # ランナー機に実在するデバイスを書く
TestProjects/<プロジェクト>/profiles/runs/<名前>.json       # "machine": "<名前>" で指す
```

### どのホストで走るかは、マシンプロファイルが決める

**マシンプロファイルは `host` を持つ**。実行プロファイルは `machine` でマシンを指すので、
**実行プロファイルを選べば、そのデバイスがある機械も一緒に決まる**。

```jsonc
// TestProjects/<プロジェクト>/profiles/machines/M1Max.json
{ "host": "M1Max",              // ← 直下の host はこのプロファイルの既定(登録簿の名前)
  "ios": { "devices": [
      { "host": "M1Max", "name": "simulator1", "simulator": "iPhone 17 Pro" } ] } }
```

```bash
ftester run --profile <実行プロファイル>   # --host は要らない。マシンの host へ自動で飛ぶ
```

- **書けるのは登録名だけ**(`user@192.168.20.101` のような ssh の実体は書けない)。
  プロファイルはプロジェクト資産で、リポジトリに接続先を混ぜないため。実体は
  `~/.config/ftester/config.json`(登録簿)にだけ置く
- **`--host` を明示すればそちらが勝つ**。マシン側が別のリモートを指していれば警告が出る
  (黙って別の機械へ送らない)。`--host local` は「今回は手元で走らせる」の明示指定
- **手元のデバイスには `"host": "local"` と書く**(省略しない。理由は次の節)

### 1つの実行プロファイルで、手元とリモートの両方を同時に回す

`host` は**デバイス1台ずつにも書けます**。プロファイル直下の `host` はその既定です。

```jsonc
// 手元10台 + M1Ultra 10台を1回の run で回す
{ "ios": { "devices": [
    { "host": "local",   "name": "iPhone 17 Pro-01", "udid": "E38D…" },
    { "host": "M1Ultra", "name": "iPhone 17 Pro-01", "udid": "3F0A…" } ]}}  // 同名でよい
```

**手元のデバイスにも `"host": "local"` を書きます**(ツールが書き出すときも省略しません)。
省略は「プロファイル直下の既定を継ぐ」の意味なので、既定がリモートのプロファイルでは
手元のデバイスが別の機械のものとして扱われます。キーの並びは `host` → `name` が先頭です。

- **一意なのは (ホスト, デバイス名)**。別の機械に同じ名前のデバイスが居てよい(各機が同じ
  命名規則でシミュレータを作るので、同名になるのが普通です)
- 実行プロファイルの参照も `host` を書けます。**書かずに同名が複数ホストに居ると、候補を挙げて
  止まります**(どちらの機械のものか決められないため)。既定がリモートのプロファイルで手元の
  デバイスを指すときは `"host": "local"` と明示します
- `ftester run --profile <名前>` は**ホストごとのサブ実行に分かれ**、シナリオを**台数で重み付けて**
  配ります(10台の機械には10台ぶん)。出力は `[ホスト] ` 付き、`--junit` は1ファイルに結合、
  終了コードは非0の最大です
- **`--host` を明示すると分散しません**(その機械だけで走ります)
- **モニターの実行ボタンからは回せません**(CLI 専用)。混在プロファイルを選んで実行すると、
  その旨のエラーで止まります(一部の台だけ走って「全部通った」に見えるのを防ぐため)

ランナー機の状態は**手元から照会できる**(個別に ssh しなくてよい):

```bash
ftester remote exec <ホスト> -- api installed-devices # 実在するデバイス
ftester remote exec <ホスト> -- doctor --fm-only      # FM が使えるか
```

**アプリのバイナリは転送されない。** アプリプロファイルの `appPath` は、ランナー機で解決できる
パスにしておく。**相対パスの基準は「リポジトリルート」= ランナー機では自分の WORK_DIR
(`<base>/users/<issuerId>/work`)** で、
**クローン(`<base>/foundation-tester`)の中は見ない**。

> ここは手元とランナー機で意味が変わる箇所。手元がツールのクローンで作業する構成
> (クローン = 作業ディレクトリ)だと `E2EAppIOS/dist/...` のような相対パスがリポジトリ内を
> 指すが、**ランナー機は外部構成**(クローンと作業ディレクトリが別)なので同じ文字列が
> `<base>/users/<issuerId>/work/E2EAppIOS/dist/...` に解決される。ビルド済みのアプリは
> **自分の WORK_DIR から見た位置**に置く(rsync/scp で置くか、ランナー機でビルドしてそこへ出す)。

## ステップ5: 疎通を確認する

```bash
ftester remote status --host <ユーザー>@<ホスト>
```

```
HOST          REACHABLE  LOGIN  REV          TOOLCHAIN     FM  BINARY  FREE
user@mac2     yes        yes    ✅ 9655a21…  ✅ Xcode26…   -   yes     412 GB
```

- `LOGIN` が `no (console: …)` → ランナー機がログイン画面で待っている。解錠してログインする
- `REV` / `TOOLCHAIN` に ⚠️ → ステップ3
- `BINARY` が `no` → ステップ2(または `swift build --product ftester`)
- `FM` を見たいときは `--fm` を付ける(1ホストにつき数秒かかるので既定では見ない)
- 複数ホストは `--host a --host b`。`--json` で機械可読の1行

## ステップ6: 最初のディスパッチ

```bash
ftester run --host <ユーザー>@<ホスト> --profile <実行プロファイル> --scenario <シナリオID>
```

- **初回は数分**(リモートでのシナリオビルドとブリッジ供給)。2回目以降は十数秒で始まる。
  実測(iOS in-app・1シナリオ・LAN 越し): **初回 138.8 秒 / 2回目 12.6 秒**(どちらもテスト時間は約5秒。
  2回目はブリッジを再利用する)
- **初回だけ SPM の依存取得でつまずくことがある**(`Couldn't fetch updates from remote repositories` /
  `Recv failure: Operation timed out`)。ランナー機の回線が細いと出る。**再実行すれば進む**
  (取得済みの分は残る)。確実にやるなら先に
  `ftester remote exec <ホスト> -- ...` ではなく、ランナー機で
  `cd ~/ftester-runner/users/<issuerId>/work && swift package resolve` を通しておく
- **Android を回すときは、先にエミュレータを起こしておく**(iOS と違い自動では起きない):
  `ftester remote exec <ホスト> -- devices up --profile <実行プロファイル>`
- `--host` と併用できないもの: `--ports` / `--report-dir` / `--failed` / `--skip-build`
  (理由付きで即座に止まる)。`--dry-run` は手元のシナリオだけで判定できるので、
  `--host` を付けていても**送らずローカルで完結する**
- 途中で Ctrl-C すると**リモート側の実行も止まる**。`--remote-timeout <秒>` で全体の上限も付けられる
  (既定はシナリオ数から算出)

**成果物の行き先**

| もの | 行き先 |
|---|---|
| レポート | 手元の `TestProjects/<プロジェクト>/reports/` へ回収(リモート側は回収後に削除) |
| 録画・run ログ | 既定(`--remote-artifacts collect`)で手元の `results/` へ回収。`on-demand` にするとリモートに残し場所だけ知らせる |
| JUnit | `--junit <パス>` で手元に書かれる(中に載るリモートの絶対パスは手元向けに置換されるが、レポート本体は上の `reports/` にある) |

## ホストに名前を付ける・複数台へ一斉に流す

**登録簿**に名前を付けると、以後は `--host <名前>` で指せる(登録は
`~/.config/ftester/config.json`。リポジトリの設定からは触れない):

```bash
ftester remote hosts add M1Max --host <ユーザー>@192.168.20.101
ftester remote hosts                      # 一覧
ftester run --host M1Max --profile <実行プロファイル>
```

送り先の同一性は **ssh の宛先(とホスト鍵)** が保証します(以前はランナー機の登録名とも
照合していましたが、登録名そのものを廃止しました)。

登録簿は**モニターの「設定」タブからも編集できます**(同じファイルを読み書きします)。
登録した名前は、そのまま**マシンプロファイルの `host`**(ステップ4)とフリート定義に書けます。

**フリート** = 複数の実行先へ一斉に流す定義。`TestProjects/<プロジェクト>/profiles/fleets/<名前>.json`:

```jsonc
{ "runs": [
    { "host": "local",   "profile": "ios-inapp" },   // "local" は手元での実行
    { "host": "M1Max",   "profile": "ios-m1max" } ] }
```

```bash
ftester run --project <プロジェクト> --fleet <名前> [--scenario <ID>]
```

- **`host` は `"local"` か登録名だけ**(ssh 宛先は書けない = プロジェクト資産に接続先を混ぜない)
- 出力は `[<host>] ` 前置で混ざって流れ、最後に1画面の集計が出る
- **同じホストを2回書くと拒否**される(デバイスの取り合いになるため)。未登録の名前も拒否
  (黙ってローカルで走らせない)
- 終了コードは**非0の最大**(どのエントリがどう落ちたかを潰さない)

**`--split` を付けると、同じシナリオを全ホストで回す代わりに、台数で分けて流します**
(夜間回帰の壁時計を縮めたいとき):

```bash
ftester run --project <プロジェクト> --fleet <名前> --split
```

- 割り当ては**過去の実績(results)から所要を見積もって均す**。実行前に割り当て表が出る
- **iOS 専用のシナリオは iOS を走らせられるホストにしか行かない**。どこにも置けない
  シナリオがあると、走らせずに止まる(黙って落とさない)
- 割り当てが0本になったホストはディスパッチしない(集計に skip として出る)
- 同じ入力なら**毎回同じ割り当て**になる(flake の切り分けで前回と同じ条件を作れる)
- 一覧を解決するため**手元で1回ビルドする**(`--split` を付けたときだけ)

実測(E2E-iOS 23本を2台へ): 11 + 12 本に分かれ、推定 133.4s / 135.7s に対し
実測 130.5s / 128.9s。

**CI から使うなら `--junit <パス>`** —— 全エントリの結果が**1ファイルにまとまり**、
どの機体で走ったかは各 `<testsuite>` の `hostname` で分かります。

```bash
ftester run --project <プロジェクト> --fleet <名前> --split --junit reports/fleet.xml
```

**あるホストが JUnit を出さなかった場合(早期に落ちた・版ズレで弾かれた等)は、
そのホストのぶんが失敗1件として出力に入ります。** 黙って省くと、CI からは
「そのホストのぶんは全部通った」に見えてしまうためです。

**同一ホストへ二重に投げると、後から来たほうが止まります**(誰がいつから掴んでいるかを表示)。
自分のディスパッチが死んで残ったロックは `ftester remote unlock --host <ホスト>` で外します
(他の人のロックは外しません)。他の人のものが止まったまま解放されない場合だけ `--force-lock` で
奪えます(警告が出ます)。

**`--host <ホスト>` に `--device <名前>` を付けると、その名前はそのホストの台に限定されます**
(同名の台が複数の機械にあるプロファイルでも1台に絞れる)。そのホストに無い名前は、
そのホストの台を列挙して手元で止まります。

## VSCode 拡張から使う

**実行先を選ぶ UI は無い。**「どのマシンプロファイルを使うか」= 実行プロファイルの選択が、
そのままホストの選択になる(ステップ4)。拡張がやることは2つだけ。

### 1. ホストを登録する(モニターの「設定」タブ)

「ホストを追加」で行を足し、`名前 / ホスト / 作業ベースディレクトリ` を入れて**行の「確定」**を
押す(押すまで反映されない)。`作業ベースディレクトリ` 空欄 = `~/ftester-runner`。

**これは VSCode の設定ではなく CLI の登録簿**(`~/.config/ftester/config.json`)を読み書きしている
(`ftester api remote-hosts`)ので、`ftester remote hosts add` で足したものと同じ表に出る。
リポジトリの `.vscode/settings.json` からディスパッチ先を差し替えられないための構造。

拡張が持つリモート関連の設定キーは **`ftester.remote.artifacts`**(`collect` 既定 / `on-demand`)
**だけ**。

### 2. マシンプロファイルにホストとデバイスを入れる(「プロファイル」タブ)

マシンプロファイルの **「デバイスを追加」の ＋** を押すと「デバイスを選択」ダイアログが開く。
その上部に**ホスト**の選択がある。

- ホストを切り替えると、**その機械に実在するデバイス**の一覧に切り替わる
  (読み込み中は前の一覧を残したまま「読み込み中...」を出す)
- **選んだホストが、そのマシンプロファイルの `host` になる**。ローカルを選べば `host` は消える
- **選んだホスト上に新しいデバイスを作れる** —— ダイアログ内の **＋(デバイスを作成)**。
  作られた実体はそのホストに、登録は**手元のマシンプロファイル**に入る(プロファイルの正は常に手元)
- デバイス行を**右クリック → 削除**で、**シミュレータ/AVD の実体を削除**できる(元に戻せない)。
  **起動中のデバイスは削除しない**(先に停止する)。マシンプロファイルから参照されている
  デバイスでも削除は止めないが、**どのプロファイルが参照していたかを削除後に知らせる**
  (宙ぶらりんのエントリが残るため)

同じことは CLI でもできる:

```bash
ftester remote exec <ホスト> -- api installed-devices     # 実在するデバイス
ftester api delete-device --platform ios --udid <UDID>    # 手元のデバイスの実体を削除
ftester api delete-device --platform android --avd <AVD名>
```

### 3. リモートのデバイスもタイルに映る(状態・ライブ映像)

**手元の台と同じように見えます** —— 状態(未起動/起動中/接続済み)も、タイルのライブ映像も、
起動・停止の操作も同じです。タイルの名前の下にホスト名のバッジが付くのが唯一の違いです。

仕組みは、その機械で監視を1本走らせて合流させるだけです(自動。設定は要りません):

- モニターを開くと、リモートのホストごとに ssh が1本ずつ張られます
- タイルがライブ映像を出している間は、**そのデバイスにつきもう1本**張られます
  (映像は LAN 前提。H.264 で1台あたり概ね数百 kbps)
- 映像が張れない・途切れたときは**2秒毎の静止画に自動で戻ります**(タイルが止まることはありません)。
  帯域や CPU を使いたくないときは、設定タブの**「ポーリングモードを使用する」**で
  全タイルを静止画に固定できます

タイルの右クリックからの**起動・停止もその機械で実行されます**(一括の「全て起動/終了」も同じ)。

**自動修復だけは手元のデバイスにしか効きません** —— ブリッジが応答しない・Wi-Fi が落ちた等の
自動復旧は、リモートの台では動きません(手動の起動・停止は使えます)。

**両方の機械の ftester の版が揃っている必要があります**。古いと状態も映像も来ず、タイルは
「<ホスト> に届いていません(状態は取得できません)」のままになります(→ ステップ3 で版を揃える)。

## テストの前に DB やスタブサーバを起こす(開始/終了スクリプト)

テスト対象アプリがバックエンドを必要とするときは、**テストを走らせる機械の上で**それを起こす
必要がある。設定は要らない —— **ワークスペースの `scripts/` に置くだけ**でよい。

```
TestProjects/<project>/workspace/scripts/setup.sh      # テスト実行前に走る(あれば)
TestProjects/<project>/workspace/scripts/teardown.sh   # テスト実行後に走る(あれば)
```

**雛形は VSCode 拡張から作れる**: モニターの「プロファイル」タブ →「リモート制御」→
**「スクリプトの雛形を作成する」**。使い方(渡される環境変数・実行規則)は雛形の中に
コメントで書いてある。既にあるファイルは上書きしない。

- ワークスペースはディスパッチのときにランナー機へ運ばれるので、**スクリプトも資材
  (compose ファイル・シードデータ)も一緒に届く**
- **手元で実行しても同じように走る**(リモート専用ではない)
- **setup.sh が失敗したら、テストは1本も走らずに止まる**(依存サービスが無いまま流すと、
  全シナリオが「アプリの不具合」の顔で落ちるため)。teardown.sh の失敗は結果を変えない(警告のみ)
- スクリプトが読める環境変数: `FT_HOOK`(setup/teardown)・`FT_WORKSPACE`・`FT_PROJECT`・
  `FT_PROFILE`・`FT_MACHINE`・`FT_REPORT_DIR`・`FT_IOS_DEVICES`・`FT_ANDROID_DEVICES`

```bash
#!/bin/sh
# workspace/scripts/setup.sh の例
set -eu
docker compose -f "$FT_WORKSPACE/data/compose.yaml" up -d
until nc -z 127.0.0.1 5432; do sleep 1; done   # 「時間」ではなく「起きたこと」で待つ
# Android エミュレータからは 10.0.2.2、実機は adb reverse で手元のポートへ届かせる
for serial in $(adb devices | awk '/\tdevice$/ {print $1}'); do
  adb -s "$serial" reverse tcp:8080 tcp:8080
done
```

**run が異常終了(ssh 切断・強制終了)しても、起こしたものは残らない。** 次の run の開始時と
`ftester remote clean` が、死んだ run の終了スクリプトを代わりに実行する
(手で撃つなら `ftester hooks reap`)。

### 機械ごとの状態・ログを転送から外す(`.ftester-transfer-ignore`)

ワークスペースはディスパッチのたびに**手元の内容でランナー機を上書き**する(消えたファイルは
向こうでも消える)。起こしたサービスが**状態やログをワークスペースの中に書く**なら、そのパスを
転送から外さないと、次のディスパッチで**手元の状態がランナー機の状態を上書きする**
(例: スタブサーバの端末登録台帳が手元の内容に戻り、ランナー機の端末が未登録になる)。

外すパスは、ワークスペース(またはその配下のどのディレクトリでも)に
**`.ftester-transfer-ignore`** を置いて書く。書き方は rsync の `--exclude` と同じで、
**そのファイルを置いたディレクトリを起点に読む**(`.gitignore` と同じ感覚):

```
# workspace/.ftester-transfer-ignore
/appstub/data/temp/session.json   # 先頭 / = このディレクトリ直下に固定
*.log                                           # 先頭 / 無し = 配下のどの深さでも
.stub-leases/                                   # 末尾 / = ディレクトリだけ
```

- 書いたパスは**送られず、ランナー機にあるものも消されない**(両方)
- 除外を足す前に運ばれてしまった複製は、ランナー機に残ったままになる。必要なら
  `ftester remote exec <ホスト> -- …` や ssh で1回だけ消す(以後は運ばれない)
- ディスパッチのログに `==> .ftester-transfer-ignore: N exclude pattern(s) from …` と出る
  (出なければファイルが読まれていない = 置き場所か名前を疑う)
- `#` / `;` で始まる行はコメント。`+`/`-` で始める rsync の filter 規則の書式は使えない

## 日常運用

```bash
ftester remote status --host <ホスト>                        # 使える状態か
ftester remote clean --host <ホスト> --keep-days 7 --dry-run # 何が消えるか見る
ftester remote clean --host <ホスト> --keep-days 7           # 実際に消す
ftester remote exec <ホスト> -- <サブコマンド>               # 単発の照会・操作(下記)
```

- **`remote clean` は定期的に。** ランナー機は誰も見ないので、results・reports・録画が
  溜まり続けて、ある日ディスクフルで止まる。孤児プロセスやゾンビブリッジの掃除、
  死んだ run が残した終了スクリプトの実行も同時に行う
- **ツールの更新**は `ftester remote setup <ホスト>` をもう一度流すだけ(冪等。align が版を揃える)
- **`remote exec` はリモートで `ftester` を1本走らせる汎用の口**。デバイス一覧・FM の可否・
  `devices down`・カタログ照会など、用途ごとに ssh を書かずにこれ1つで済ませる。
  `--remote-dir` を使うときは**ホスト名より前**に置く(ホスト名より後ろは全部リモートへ素通し)
- **ランナー機を再起動したら、1回ログインし直す**。ログイン画面のままだとディスパッチは
  「ログイン画面で待機中」と言って止まる(シミュレータの謎の失敗として現れないようにするため)

## 複数人でフリートを共有する

前提は**同一の信頼グループ**(同じチーム)での共有。認証・隔離の仕組みはない —
ssh で入れる人はそのランナーで何でもできる。チームを跨いだ隔離が要るなら、
**機械ごと割り当てる**(チーム A は mac-a、チーム B は mac-b。フリート定義で表現できる)。
設計の背景は [remote-runner.md](remote-runner.md) §18。

### 1人1鍵(失効できるようにする)

ランナーの `~/.ssh/authorized_keys` には**1人1行**で鍵を足し、行末コメントを本人の識別子にする:

```
ssh-ed25519 AAAA… tanaka@dev-mbp
ssh-ed25519 AAAA… suzuki@dev-mba
```

鍵を共有しない。**失効 = その行を消すだけ**(退職・端末紛失時に個別に取り消せる)。

### 名乗る(issuerId)

各自の発行側 Mac で `~/.config/ftester/config.json` に自分の識別子を書く:

```jsonc
{ "issuerId": "tanaka@dev-mbp" }
```

未設定なら `ユーザー名@ホスト名` が自動で使われる。この値は**自己申告**(認証ではない)で、
ロックの保持者表示と実行結果(run.json の `issuer`)に載る —— 「今誰が使っているか」
「これは誰の run か」をチーム内で見分けるためのもの。

**ランナー上の作業場所の名前にもなる**(`~/ftester-runner/users/<issuerId>/work`)ので、
**明示設定を強く推奨** —— 既定値はホスト名を含み、ホスト名はネットワークで変わることがある。
変わると次のディスパッチが**別人扱い**になり、ランナー上に新しい作業場所が作られてしまう
(未設定のまま使うと警告が出る)。使える文字は英数と `@ . _ -` だけ。

**各自が `ftester remote setup <ホスト>` を1回流す**(自分の作業場所を作るため。tool は
共有済みなので数秒で終わる)。setup していない人のディスパッチは
「no runner workspace — run: ftester remote setup」で止まる。

### 順番待ち(ロック)

同じランナーには同時に1つのディスパッチしか走れない。取れないときは誰がいつから
掴んでいるかが表示される。**待つなら `--wait-lock <秒>`**:

```bash
ftester run --profile <名前> --wait-lock 600   # 最大10分、解放を待って自動で続行
```

`--force-lock`(奪う)は相手の run を壊すので、表示された相手に確認してから。
時間で自動的に奪う仕組みは意図的に無い。**自分のディスパッチが死んで残ったロック**は
`ftester remote unlock --host <ホスト>` で外す(自分のものだけ。動いている自分の run のロックや
他の人のロックは外さない)。

### 版はフリートで揃える(ピン運用)

原則: **ランナーの版は動かさず、遅れている人が自分を更新する**。版ズレで止まったときの
メッセージは向きを教えてくれる:

| 案内 | 意味 | やること |
|---|---|---|
| この機械が古い(update…) | 自分が pull していない | 手元で `Scripts/update.sh`(ランナーは触らない) |
| ランナーが古い(remote align…) | フリートの版上げが必要 | 当番が **1台だけ** align → 検証ディスパッチ1本 → 通ってから残りへ(カナリア。Xcode/macOS 更新も同じ手順) |
| 分岐している(diverged) | ブランチ作業 | 共有ランナーでは実行しない。専用機か手元で検証する |

VSCode 拡張の「更新して実行」も、自分が古いケースではランナー更新を提案しない。

### 当番を決める(モード A のランナー)

FileVault 有効のランナーは**再起動のたびに誰かが解錠+ログイン**する必要がある
(ステップ0)。「誰かがやるだろう」で全員が止まるので、機械ごとに当番を決めて
チームの目に見える場所(README 等)に書いておく。

### 他人の run を壊さない

- `remote clean` / `devices down` / デバイス削除は**他人の実行中 run を殺し得る**。
  ロックの保持者表示(誰がいつから)を見てから
- モニターのライブ配信はテスト実行と干渉する(特に Android)。**他人が run 中の
  ランナーのタイルを開いたままにしない**

## うまくいかないとき

| 症状・メッセージ | 原因 | 対処 |
|---|---|---|
| `cannot reach … over ssh` | 鍵で入れない / ホスト名違い | ステップ1(`BatchMode=yes` でパスワードは聞けない) |
| `remote setup` が preflight で warn 終了(exit 2) | ランナー機に人手の項目が残っている | 出力に列挙された操作を行い、同じコマンドを再実行(冪等) |
| `Failed to connect to <名前> port 8080`(clone が75秒待って失敗) | ランナー機の git に古いプロキシ設定が残っている | `git config --global --unset-all http.proxy` / 同 `https.proxy`（必要な環境ならプロキシ側を直す） |
| `unknown or unsupported macOS version` / `brew install xcodegen failed` | Homebrew がその macOS を知らない古い版（brew が1つも動かない） | `git -C /opt/homebrew fetch origin && git -C /opt/homebrew reset --hard origin/master` |
| `cannot resolve the local project` | 手元にプロジェクトが複数 | `--project <名前>` を付ける |
| `is sitting at the login window` | ランナー機がログイン画面 | 解錠してログイン(画面共有) |
| `git revision mismatch` | 版がズレている | メッセージの向き付き案内に従う(「複数人でフリートを共有する」の表。単独利用ならステップ3) |
| `another dispatch is already running on this remote host` | 別のディスパッチ(他の人・別ターミナル)が実行中、または自分のディスパッチが死んでロックが残った | 待つ(`--wait-lock <秒>`)。保持者が自分で死んでいるなら `ftester remote unlock --host <ホスト>`。他の人のもので確認できたときだけ `--force-lock` |
| `toolchain mismatch` | Xcode / macOS が違う | 両機を同じ版に |
| `ftester binary not found on remote` | ビルドされていない | ランナー機で `swift build --product ftester` |
| `unknown package` | クローンのディレクトリ名を変えた | `~/ftester-runner/foundation-tester` に戻す |
| `no running emulator for AVD …` | Android のエミュレータが未起動 | ステップ6 の `devices up` |
| `no runner workspace at …`(exit 91) | あなたの issuerId の作業場所がまだ無い(未 setup / issuerId が変わった) | `ftester remote setup <ホスト>` を1回。issuerId は明示設定にする(「複数人でフリートを共有する」) |
| シナリオが0本 / 見つからない | プロジェクト名が手元と違う | ステップ2 の `--name` を手元と揃える |
| アプリのインストールに失敗する | `appPath` がランナー機で解決できない | ステップ4（相対パスは自分の WORK_DIR = `<base>/users/<issuerId>/work` 基準。バイナリは転送されない） |
| `.apks` のインストールで `needs bundletool` | ランナー機に bundletool が無い | ランナー機で `brew install bundletool`（`.apks` を使うときだけ要る。単一 `.apk` なら不要） |
| `Couldn't fetch updates from remote repositories` / `Recv failure: Operation timed out` | ランナー機の回線が細く SPM の依存取得が落ちた | 再実行する（取得済みは残るので数回で通る）。事前に `swift package resolve` を通しておくと確実 |
| `Foundation Models unavailable` の警告 | ランナー機で Apple Intelligence が無効 | heal / screenLooksLike / トリアージを使わないなら無視してよい（実行は続く）。使うならシステム言語を英語にして有効化 |
| `--ports is not supported with --host` 等 | 併用できない指定 | ステップ6 の一覧 |
| 手元で走ってほしいのにリモートへ飛ぶ / その逆 | 実行プロファイルが指す**マシンプロファイルの `host`** が効いている | ステップ4。今回だけ変えるなら `--host local` / `--host <名前>`(明示が勝つ) |
| `--host … overrides the machine profile's host …` | `--host` とマシン側の `host` が違う機械を指している | 警告どおり `--host` が使われる。意図と違えばどちらかを直す |
| `the device is currently running — stop it first` | 起動中のデバイスは削除できない | `ftester devices down` で停止してから削除する |
| `no such simulator/AVD` | 既に削除済み / 識別子が違う | 一覧を取り直す(ダイアログのホストを選び直す) |
| タイルが「<ホスト> に届いていません」のまま | その機械の ftester が古い(`Unknown option '--device-host'` が OUTPUT に出る)/ ssh が通らない | ステップ3 で版を揃えてから、モニターの「モニター再起動」(諦めた接続はここでやり直す) |
| リモートのタイルだけ映像が出ない(静止画は出る) | 配信の ssh が張れていない / そのプラットフォームの配信を設定で切っている | 静止画で運用は続く。OUTPUT の `[monitor-stream]` を見る。設定タブの iOS/Android 配信のトグルを確認 |

切り分けが要るときは、ランナー機で**そのまま手で実行してみる**のが早い —
リモート実行は「向こうで普通にローカル実行する」だけなので、同じことが手でもできる。

```bash
ssh <ホスト>
cd ~/ftester-runner/users/<自分の issuerId>/work
~/ftester-runner/foundation-tester/.build/debug/ftester run --profile <実行プロファイル>
```

## 関連

- 設計・判断の背景(なぜ SSH なのか・却下した案・セキュリティ前提): [remote-runner.md](remote-runner.md)
- CI での実行(Jenkins / EC2 Mac): [ci.md](ci.md)
- 一般的な導入(手元のマシン): [getting-started.md](getting-started.md)
