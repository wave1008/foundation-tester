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
| 複数ホストの一括診断・掃除(`remote status` / `remote clean`) | ✅ |
| 複数ホストへの**同時**実行(フリート)、シナリオの台数分散 | ❌ 未実装 |
| リモート実行分を `ftester results` の集計に混ぜる | ❌ 未実装(レポート・JUnit は回収されるので個別の調査は可能) |
| 同一リモートへの二重ディスパッチの直列化 | ❌ 未実装 — **重ねて投げるとデバイスの取り合いになる**。運用で避ける |
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
| Homebrew | `xcodegen` が入っていること(iOS のブリッジビルドに必須) | `brew install xcodegen` |
| Android | Android SDK と AVD(Android を回すときだけ) | `ftester doctor` |
| FM | システム言語が**英語** + Apple Intelligence 有効(`screenIs` や自己修復を使うときだけ) | `ftester doctor --fm-only` |

**画面ロックはかけたままでよい**(セッションは消えない)。消えるのは再起動と電源断だけで、
そのときは人が1回ログインし直す必要がある(画面共有でよい)。

## ステップ0(ランナー機で1回だけ・手作業)

sudo や GUI が要るものはインストーラでは行わない。ランナー機の前に座るか、画面共有で行う。

1. **リモートログインを ON**: システム設定 → 一般 → 共有 → リモートログイン
2. **画面共有を ON**(強く推奨。再起動後のログインを手元からやるため)
3. **システムスリープを無効化**: `sudo pmset -a sleep 0`
4. **Xcode を導入**し、1回起動してライセンスに同意(`sudo xcodebuild -license accept` /
   `sudo xcodebuild -runFirstLaunch`)。**版は発行側と揃える**
5. **Homebrew と xcodegen**: `brew install xcodegen`
6. 必要なら Android SDK・AVD、FM を使うならシステム言語を英語にして Apple Intelligence を有効化
7. **ログインしたままにする**(ログアウトしない。ロックはしてよい)

## ステップ1(発行側): 鍵で入れるようにする

```bash
ssh-copy-id <ユーザー>@<ホスト>            # 初回だけパスワードを1回
ssh -o BatchMode=yes <ユーザー>@<ホスト> 'echo ok'   # これが ok を返せば準備完了
```

ディスパッチは `BatchMode=yes`(パスワード入力をしない)で接続するので、**この確認が通ることが
必須**。初回接続のホスト鍵確認(known_hosts への登録)はここで済ませる。

> `StrictHostKeyChecking` を無効にしない。ホスト鍵の検証は「知らないマシンへ
> プロジェクトを送り込んでしまう」経路を実際に塞いでいる唯一の仕掛け。

## ステップ2(ランナー機): ツール一式を入れる

**ランナー機に ssh して**(ログインシェルで PATH が通るため)、次を実行する。

```bash
mkdir -p ~/ftester-runner/work
curl -fsSL https://raw.githubusercontent.com/wave1008/foundation-tester/main/Scripts/install.sh | bash -s -- \
  --work-dir ~/ftester-runner/work \
  --name <プロジェクト名> \
  --skip-extension --skip-mcp --skip-claude-md
```

- **`--name` は手元と同じプロジェクト名**(`TestProjects/<名前>` の名前)にする
- **ディスパッチより前に必ず済ませる**。先にディスパッチするとプロジェクトのディレクトリだけが
  でき、インストーラが「作成済み」と見なして土台(`Package.swift`)を作らない
- 拡張・MCP・CLAUDE.md はランナー機には不要なので入れない(CLI だけで動く)
- プロファイル(machines/apps/runs)はここでは作らない。**手元のものが実行のたびに転送される**
- クローンは `~/ftester-runner/foundation-tester` にできる。**このディレクトリ名は変えない**
  (SPM がパッケージ名をディレクトリ名から決めるため)
- 初回はコールドビルドで数分かかる。exit 0 なら完了、詳細は `~/ftester-runner/work/.ftester/install-<日時>.log`

## ステップ3: 版を揃える

ディスパッチは **git のコミット**と **Xcode/macOS の指紋**の2つを照合し、どちらかが違えば
**何も実行せずに止まる**(黙って古い版で走らせないため)。

```bash
# ランナー機を手元と同じコミットに合わせる(検証用のブランチを試すときは必ずこれ)
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
# ランナー機で(名前を登録する)
ssh <ホスト> '~/ftester-runner/foundation-tester/.build/debug/ftester machine set "<マシン名>"'

# 手元で(そのマシン名のプロファイルを作り、ランナー機に実在するデバイス名を書く)
#   TestProjects/<プロジェクト>/profiles/machines/<マシン名>.json
```

**アプリのバイナリは転送されない。** アプリプロファイルの `appPath` は、ランナー機で解決できる
パス(相対パスなら同じ相対位置にビルド済みのものがある状態)にしておく。

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

- **初回は数分**(リモートでのシナリオビルドとブリッジ供給)。2回目以降は十数秒で始まる
- **Android を回すときは、先にエミュレータを起こしておく**(iOS と違い自動では起きない):
  `ssh <ホスト> 'cd ~/ftester-runner/work && ~/ftester-runner/foundation-tester/.build/debug/ftester devices up --profile <実行プロファイル>'`
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
```

- **`remote clean` は定期的に。** ランナー機は誰も見ないので、results・reports・録画が
  溜まり続けて、ある日ディスクフルで止まる。孤児プロセスやゾンビブリッジの掃除も同時に行う
- **ツールの更新**は両側を同じコミットへ。ランナー機はステップ2と同じコマンドを流し直せばよい(冪等)
- **ランナー機を再起動したら、1回ログインし直す**。ログイン画面のままだとディスパッチは
  「ログイン画面で待機中」と言って止まる(シミュレータの謎の失敗として現れないようにするため)

## うまくいかないとき

| 症状・メッセージ | 原因 | 対処 |
|---|---|---|
| `cannot reach … over ssh` | 鍵で入れない / ホスト名違い | ステップ1(`BatchMode=yes` でパスワードは聞けない) |
| `is sitting at the login window` | ランナー機がログイン画面 | 解錠してログイン(画面共有) |
| `git revision mismatch` | 版がズレている | ステップ3 |
| `toolchain mismatch` | Xcode / macOS が違う | 両機を同じ版に |
| `ftester binary not found on remote` | ビルドされていない | ランナー機で `swift build --product ftester` |
| `unknown package` | クローンのディレクトリ名を変えた | `~/ftester-runner/foundation-tester` に戻す |
| `no running emulator for AVD …` | Android のエミュレータが未起動 | ステップ6 の `devices up` |
| シナリオが0本 / 見つからない | プロジェクト名が手元と違う | ステップ2 の `--name` を手元と揃える |
| アプリのインストールに失敗する | `appPath` がランナー機で解決できない | ステップ4(バイナリは転送されない) |
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
