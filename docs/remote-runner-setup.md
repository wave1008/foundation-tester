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
| 1つのシナリオ集合を台数で**分散**する(ホスト間の分割) | ❌ 未実装(フリートは「各ホストで同じ指定を走らせる」) |
| リモート実行分を `ftester results` の集計に混ぜる | ❌ 未実装(レポート・JUnit は回収されるので個別の調査は可能) |
| モニターでのリモートデバイス表示 | ❌ 未実装 |

## 全体像

```
発行側の Mac(手元)                     ランナー機
ftester run --host mac2 …               ~/ftester-runner/               ← 専用ベースディレクトリ
  ├ 適合チェック(rev・Xcode)   ssh     ├── foundation-tester/          ← ツール本体のクローン(名前固定)
  ├ 転送(rsync: シナリオ・設定) ────>  └── work/                        ← 実行の作業場所
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
| Android | Android SDK と AVD(Android を回すときだけ) | `ftester doctor` |
| FM | システム言語が**英語** + Apple Intelligence 有効(`screenIs` や自己修復を使うときだけ) | `ftester doctor --fm-only` |

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
ftester remote setup <ユーザー>@<ホスト> --project <プロジェクト名> --machine "<マシン名>"
```

何をするか(冪等。何度実行してもよい):

| ステップ | 内容 |
|---|---|
| local | 手元のプロジェクト解決(ここで落ちれば ssh に行かない) |
| reach | 到達確認とログイン状態の確認 |
| preflight | **手元の `Scripts/preflight.sh` を送って `--runner` で判定**。人手が要る項目が残っていれば、その一覧を出して止まる(直して同じコマンドを再実行) |
| install | **手元の `Scripts/install.sh` を送って**実行(`~/ftester-runner/work` に受け手パッケージを作る)。初回はコールドビルドで数分 |
| align | ランナー機のクローンを**手元と同じコミット**へ合わせて `swift build`(下記) |
| machine | `--machine` を渡したときだけ `ftester machine set` |
| verify | `--profile`(と任意の `--scenario`)を渡すと**実ディスパッチを1本走らせる**。ここが通って初めてセットアップ成功 |

終了コードは install.sh と同じ語彙: **0 = 完了 / 2 = 必須は通ったが人手の項目が残っている / 1 = 失敗**。

- **`--project` は手元と同じプロジェクト名**(`TestProjects/<名前>`)。手元にプロジェクトが1つだけなら省略できる
- **スクリプトは curl ではなく手元から送る**。GitHub の main ではなく、**いま自分がいるコミットの
  スクリプト**を使うため(検証中のブランチでも版が揃う)
- 拡張・MCP・CLAUDE.md はランナー機には入れない(CLI だけで動く)
- プロファイル(machines/apps/runs)は**手元のものが実行のたびに転送される**ので、ここでは作らない
- 撤去は `ftester remote setup <ホスト> --uninstall`(確認あり。`--yes` で無確認)

> 手で入れたい場合は、上の install ステップと同じことを ssh して実行すればよい:
> `bash install.sh --work-dir ~/ftester-runner/work --name <プロジェクト名> --skip-extension --skip-mcp --skip-claude-md`。
> クローン先の**ディレクトリ名 `foundation-tester` は変えない**(SPM がパッケージ名をディレクトリ名から決めるため)。

## ステップ3: 版を揃える

ディスパッチは **git のコミット**と **Xcode/macOS の指紋**の2つを照合し、どちらかが違えば
**何も実行せずに止まる**(黙って古い版で走らせないため)。

**`remote setup` の align ステップが毎回これを行う**ので、手元でコミットを進めたら
`ftester remote setup <ホスト>` をもう一度流せば揃う。手で合わせるなら:

```bash
ssh <ホスト> 'cd ~/ftester-runner/foundation-tester && git fetch origin && git checkout <コミット> && swift build --product ftester'
```

- **手元の未コミットの変更は届かない**(警告が出る)。ツール本体の変更を試すなら、
  コミットして push し、ランナー機をそのコミットに合わせる
- Xcode や macOS を更新したら**両方**を更新する。片方だけだと全ディスパッチが止まる

## ステップ4: マシン名とプロファイル

実行プロファイルが参照する**マシンプロファイル**(どのデバイスを使うか)は、次の順で決まる。

1. 実行プロファイルが `machine` を明示していればそれ
2. 環境変数 `FT_MACHINE`
3. そのマシンに登録された名前(`ftester machine set`)
4. マシンプロファイルが1つしかなければそれ

**マシンプロファイルが1つだけなら何もしなくてよい。** 手元とランナー機でデバイス構成が違う場合は、
ランナー機に名前を登録し、その名前のマシンプロファイルを**手元で**作る(転送される)。

```bash
# ランナー機の名前を登録する(remote setup に --machine を渡していれば済んでいる)
ftester remote setup <ホスト> --machine "<マシン名>"

# 手元で(そのマシン名のプロファイルを作り、ランナー機に実在するデバイス名を書く)
#   TestProjects/<プロジェクト>/profiles/machines/<マシン名>.json
```

ランナー機の状態は**手元から照会できる**(個別に ssh しなくてよい):

```bash
ftester remote exec <ホスト> -- machine show          # 登録名とプロファイルの対応
ftester remote exec <ホスト> -- api installed-devices # 実在するデバイス
ftester remote exec <ホスト> -- doctor --fm-only      # FM が使えるか
```

**アプリのバイナリは転送されない。** アプリプロファイルの `appPath` は、ランナー機で解決できる
パスにしておく。**相対パスの基準は「リポジトリルート」= ランナー機では `<base>/work`** で、
**クローン(`<base>/foundation-tester`)の中は見ない**。

> ここは手元とランナー機で意味が変わる箇所。手元がツールのクローンで作業する構成
> (クローン = 作業ディレクトリ)だと `E2EAppIOS/dist/...` のような相対パスがリポジトリ内を
> 指すが、**ランナー機は外部構成**(クローンと作業ディレクトリが別)なので同じ文字列が
> `<base>/work/E2EAppIOS/dist/...` に解決される。ビルド済みのアプリは
> **`<base>/work` から見た位置**に置く(rsync/scp で置くか、ランナー機でビルドしてそこへ出す)。

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
  `cd ~/ftester-runner/work && swift package resolve` を通しておく
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
ftester remote hosts add M1Max --host <ユーザー>@192.168.20.101 --machine "M1Max"
ftester remote hosts                      # 一覧
ftester run --host M1Max --profile <実行プロファイル>
```

`--machine` を登録しておくと、**ディスパッチ前にランナー機の登録名と照合**し、食い違えば止まります
(別のマシンへ送っていることに気付けます)。

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

**同一ホストへ二重に投げると、後から来たほうが止まります**(誰がいつから掴んでいるかを表示)。
止まったまま解放されない場合だけ `--force-lock` で奪えます(警告が出ます)。

## VSCode 拡張から使う

モニターの「設定」タブでホストを登録し、実行先を選ぶ。設定キーは3つ。

| キー | 意味 |
|---|---|
| `ftester.remote.hosts` | 登録簿。`{ "name": "表示名", "host": "user@mac2", "dir": "" }` の配列(`dir` 空 = `~/ftester-runner`) |
| `ftester.remote.target` | 実行先。**空ならローカル実行**、非空なら `hosts` の `name` |
| `ftester.remote.artifacts` | `collect`(既定)/ `on-demand` |

- いずれも **machine スコープ**(そのマシンの設定)。リポジトリの `.vscode/settings.json` からは
  上書きできない — 開いたリポジトリに実行先を書き換えられないための措置
- `target` が `hosts` に無い名前を指していると、**黙ってローカルで走らせず run を中止する**

## 日常運用

```bash
ftester remote status --host <ホスト>                        # 使える状態か
ftester remote clean --host <ホスト> --keep-days 7 --dry-run # 何が消えるか見る
ftester remote clean --host <ホスト> --keep-days 7           # 実際に消す
ftester remote exec <ホスト> -- <サブコマンド>               # 単発の照会・操作(下記)
```

- **`remote clean` は定期的に。** ランナー機は誰も見ないので、results・reports・録画が
  溜まり続けて、ある日ディスクフルで止まる。孤児プロセスやゾンビブリッジの掃除も同時に行う
- **ツールの更新**は `ftester remote setup <ホスト>` をもう一度流すだけ(冪等。align が版を揃える)
- **`remote exec` はリモートで `ftester` を1本走らせる汎用の口**。デバイス一覧・FM の可否・
  `devices down`・カタログ照会など、用途ごとに ssh を書かずにこれ1つで済ませる。
  `--remote-dir` を使うときは**ホスト名より前**に置く(ホスト名より後ろは全部リモートへ素通し)
- **ランナー機を再起動したら、1回ログインし直す**。ログイン画面のままだとディスパッチは
  「ログイン画面で待機中」と言って止まる(シミュレータの謎の失敗として現れないようにするため)

## うまくいかないとき

| 症状・メッセージ | 原因 | 対処 |
|---|---|---|
| `cannot reach … over ssh` | 鍵で入れない / ホスト名違い | ステップ1(`BatchMode=yes` でパスワードは聞けない) |
| `remote setup` が preflight で warn 終了(exit 2) | ランナー機に人手の項目が残っている | 出力に列挙された操作を行い、同じコマンドを再実行(冪等) |
| `Failed to connect to <名前> port 8080`(clone が75秒待って失敗) | ランナー機の git に古いプロキシ設定が残っている | `git config --global --unset-all http.proxy` / 同 `https.proxy`（必要な環境ならプロキシ側を直す） |
| `unknown or unsupported macOS version` / `brew install xcodegen failed` | Homebrew がその macOS を知らない古い版（brew が1つも動かない） | `git -C /opt/homebrew fetch origin && git -C /opt/homebrew reset --hard origin/master` |
| `cannot resolve the local project` | 手元にプロジェクトが複数 | `--project <名前>` を付ける |
| `is sitting at the login window` | ランナー機がログイン画面 | 解錠してログイン(画面共有) |
| `git revision mismatch` | 版がズレている | ステップ3 |
| `toolchain mismatch` | Xcode / macOS が違う | 両機を同じ版に |
| `ftester binary not found on remote` | ビルドされていない | ランナー機で `swift build --product ftester` |
| `unknown package` | クローンのディレクトリ名を変えた | `~/ftester-runner/foundation-tester` に戻す |
| `no running emulator for AVD …` | Android のエミュレータが未起動 | ステップ6 の `devices up` |
| シナリオが0本 / 見つからない | プロジェクト名が手元と違う | ステップ2 の `--name` を手元と揃える |
| アプリのインストールに失敗する | `appPath` がランナー機で解決できない | ステップ4（相対パスは `<base>/work` 基準。バイナリは転送されない） |
| `Couldn't fetch updates from remote repositories` / `Recv failure: Operation timed out` | ランナー機の回線が細く SPM の依存取得が落ちた | 再実行する（取得済みは残るので数回で通る）。事前に `swift package resolve` を通しておくと確実 |
| `Foundation Models unavailable` の警告 | ランナー機で Apple Intelligence が無効 | heal / screenIs / トリアージを使わないなら無視してよい（実行は続く）。使うならシステム言語を英語にして有効化 |
| `--ports is not supported with --host` 等 | 併用できない指定 | ステップ6 の一覧 |

切り分けが要るときは、ランナー機で**そのまま手で実行してみる**のが早い —
リモート実行は「向こうで普通にローカル実行する」だけなので、同じことが手でもできる。

```bash
ssh <ホスト>
cd ~/ftester-runner/work
~/ftester-runner/foundation-tester/.build/debug/ftester run --profile <実行プロファイル>
```

## 関連

- 設計・判断の背景(なぜ SSH なのか・却下した案・セキュリティ前提): [remote-runner.md](remote-runner.md)
- CI での実行(Jenkins / EC2 Mac): [ci.md](ci.md)
- 一般的な導入(手元のマシン): [getting-started.md](getting-started.md)
