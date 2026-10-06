# シナリオのサンドボックス(Seatbelt)で得た知見

2026-09-30 に PoC(ブランチ `poc/sandbox`・実行プロファイルで任意に有効化)として、シナリオ実行バイナリを
macOS の Seatbelt(`sandbox-exec`)で包む機能を作った。2026-10-06 に、MCP 経由でエージェントが任意のコードを
実行できる穴への対策として採用し、**常に有効・設定はマシン側だけ**の形で main へ移植した。
この文書は、その過程で**実際に測って分かったこと**と、**調べ方**と、**踏んだ失敗**の記録。

- 設計(型の分担・規則の形・壁の外に残るもの)は [design.md §11.7](design.md)。
- 守る規律は `.claude/rules/executor.md` のサンドボックスの項。
- 利用者向けの説明は [user-docs/reference/tools/mcp_server_ja.md](user-docs/reference/tools/mcp_server_ja.md) §サンドボックスと承認。

数字と挙動は、断りが無い限り M2 Ultra / macOS 27.2 / Xcode 27.0 での実測。

---

## 1. 要点

| 分かったこと | 意味 |
|---|---|
| 全許可を土台にした枠は壁にならない | 書き込みと通信を絞っても、`simctl spawn` と `open -a` で枠の外にプロセスを起こせた |
| 全拒否を土台にしても、シナリオは普通に走る | 必要な許可を足した状態で、フル E2E 344 本が緑・所要は枠なしと同程度 |
| 拒否は `log stream` で拾える | 必要な許可を、推測でなく実行しながら洗い出せる |
| Simulator の操作は親へ移せる | `Shell.run` の1箇所で `xcrun simctl` を横取りすれば、呼び出し元は変えずに済む |
| Seatbelt はドメイン名でも IP でも絞れない | ドメイン単位の許可にはプロキシが要る |
| adb は親へ移せる | `simctl` と同じ横取りで adb の呼び出しを親へ送り、adb サーバと Emulator のポートを枠で閉じる(§8.2) |
| ブリッジの localhost とデバイス経由の持ち出しは残る | 子がドライバである限り閉じられない。閉じるにはドライバごと親へ移す |

---

## 2. Seatbelt そのものの性質

### 2.1 基本

- **枠は子孫へ引き継がれ、外せない**。包んだプロセスが起こす `simctl`・`adb`・`curl` も同じ枠の中で動く。
- **`sandbox-exec` は枠を掛けてから対象を exec する**。pid は変わらない。SIGTERM、親の死の検知
  (`ParentDeathWatch`)、stdin の制御チャネル、拡張のプロセス分類は、包まないときと同じに動いた。
- **起動1回あたりの増分は約 12ms**(`list` の中央値 61ms → 74ms・10 回ずつ)。
  シナリオ1本 = 1プロセスなので毎回払うが、E2E の所要には現れなかった。
- **プロファイルは `-p` で文字列のまま渡せる**。ファイルに置く必要は無い。
- **`sandbox-exec` は Apple が非推奨と明記している**。書式(SBPL)も公式には文書化されていない。
  macOS の更新で挙動が変わりうる。

### 2.2 後に書いた規則が勝つ

`(deny file-write*)` の後に `(allow file-write* (subpath …))`、その後に
`(deny file-write* (subpath …/hooks))` と書けば、許可した場所の中の一部だけを閉じられる。

### 2.3 パスは symlink を解決した後の形で照合される

`/var` は `/private/var`、`/tmp` は `/private/tmp` への symlink。規則に `/var/folders/…` と書いても
当たらない。

- `URL.resolvingSymlinksInPath()` は `/private` を**剥がす**ので使えない。`realpath(3)` を使う。
- まだ存在しないパス(これから作るレポート出力先)は `realpath` が失敗する。
  存在する最も深い祖先を解決して、残りを足す(`ScenarioSandbox.canonicalPath`)。

### 2.4 作れるのは許可した場所そのものから下だけ

`(subpath "/a/b/c")` を許可しても、`/a/b` が無ければ `mkdir -p /a/b/c` は失敗する(途中の親を作れない)。
レポート出力先は、親が先に作ってから子を起こす。

### 2.5 通信の条件で書けるホストは `*` と `localhost` だけ

```
(deny network-outbound (remote ip "1.1.1.1:*"))
→ sandbox-exec: host must be * or localhost in network address
```

IP アドレスもドメイン名も書けない。書けるのは `"localhost:8080"`・`"*:443"`・`"localhost:*"` の形だけ。

- **`localhost` は自機の全アドレスを含む**。この Mac の LAN 側のアドレス(`10.0.0.104`)への接続も
  `(remote ip "localhost:*")` で通った。
- LAN 越しのブリッジ(実機)を開けるには、ポートで絞るしかない(`"*:<port>"`)。

### 2.6 `network*` に `(local ip "localhost:*")` を書くと全部通る

```
(deny network*)
(allow network* (local ip "localhost:*") (remote ip "localhost:*"))
```

これで外部(`1.1.1.1:443`・`https://example.com`)へ普通に繋がった。外向きの接続にも
`local ip` の条件が当たるため。向きごとに分け、外向きは宛先だけで絞る。

```
(deny network*)
(allow network-outbound (remote ip "localhost:*"))
(allow network-bind (local ip "localhost:*"))
(allow network-inbound (local ip "localhost:*"))
```

この誤りは、最初に書いた単体テストが落ちて見つかった。文字列の形だけを見るテストでは見つからない。

### 2.7 unix ソケットは、名指しの許可に加えて書き込みも要る

`(allow network-outbound (remote unix-socket (path-literal "…")))` だけでは繋がらず、
そのパスへの `file-write*` も要った。親の broker のソケットは一時領域(書ける場所)に置く。

`(remote unix-socket)` をパス無しで書くと全部の unix ソケットが開く。Docker のソケットのような
強い口に届くので書かない。

### 2.8 SwiftPM は枠の中では動かない

SwiftPM は Package.swift の評価に自前の `sandbox-exec` を使う。外側に枠があると

```
sandbox-exec: sandbox_apply: Operation not permitted
```

で落ちる。外側のプロファイルをどう緩めても変わらない。`--disable-sandbox` を付ければ通るが、
SwiftPM 自身の保護を外すことになる。

fleetest は**ビルドを親で済ませてから子を包む**ので、この制約には当たらない。
fleetest 自体を枠の中で起こすと(エージェントのサンドボックスなど)、ビルドの段でこのエラーになる。

---

## 3. 全許可の枠がなぜ壁にならないか

最初の実装は「全許可 → 書き込みと通信だけ絞る」だった。次の2つで枠の外へ出られた。

| 経路 | 実測 |
|---|---|
| CoreSimulator | 書き込みを絞った枠の中から `xcrun simctl spawn <udid> defaults write <枠の外のパス> k v` が成功し、枠の外にファイルができた。Simulator の中のプロセスは Mac 上の普通のプロセスで、枠を継がない |
| LaunchServices | 枠の中から `open -g -a "Script Editor"` を打つと、アプリが枠の外で起動した |

`launchctl submit` は枠の中から断られた(exit 1・ジョブは実行されない)。

`simctl` だけを塞いでも足りない。`open` のほかに AppleEvents や各種の XPC サービスが同じ形の口になる。
**口を1つずつ塞ぐのではなく、全拒否から必要なものだけ開ける**。

---

## 4. 全拒否の枠で要った許可

`(deny default)` に次を足した状態で、フル E2E(この Mac・iOS in-app 4 SUT + Android 4 SUT・344 本)が緑。

### 4.1 無いと動かないもの

| 許可 | 無いときの症状 |
|---|---|
| `process-exec*`・`process-fork`・`file-read*`・`sysctl-read` | 起動しない |
| `signal (target same-sandbox)`・`process-info*` | 子プロセスの管理ができない |
| mach: `opendirectoryd.libinfo`・`notification_center`・`logd`・`diagnosticd` | 起動時の基本サービス |
| mach: `bsd.dirhelper`・`opendirectoryd.membership` | 一時ディレクトリとグループの解決。1 シナリオで数十回引かれる |
| iokit: `IOSurfaceRootUserClient`・`AGXDeviceUserClient`・`IOSurfaceAcceleratorClient` | 画像照合が `Failed to create CVPixelBufferPool` で落ちる |
| iokit: `H1xANELoadBalancerDirectPathClient`、mach: `com.apple.appleneuralengine` | Core ML が `espresso error: -1` で落ちる |
| xpc: `com.apple.MTLCompilerService` | Metal のシェーダをコンパイルできない |
| `file-issue-extension`(`~/Library/Caches/<実行バイナリ名>/`) | Core ML がコンパイルキャッシュを ANE のデーモンへ見せられない |
| `network-outbound` の `/private/var/run/syslog` | ログの送り先 |

**Vision / Core ML の許可は、閉じると落ちるより先に遅くなる**。IOSurface と GPU を閉じた状態では、
E2E-CMP の iOS 1 プロファイルが 120 秒 → 1,478 秒になった。OCR が遅い経路へ落ち、
待ちの予算(120 秒)に当たる操作が出た。**「通ったが異常に遅い」は許可の不足を疑う。**

### 4.2 機能を使うときだけ要るもの

| 許可 | 条件 |
|---|---|
| mach: `com.apple.trustd.agent` | 許可ドメインへ `URLSession` で HTTPS を撃つとき。無いと証明書を検証できず -1202 で落ちる。curl は自前で検証するので要らない |
| mach: `com.apple.modelmanager` | FoundationModels の推論。**開けてあるが、通ることは未確認**(この日は FM が死んでいた) |

### 4.3 拒否のまま残したもの

拒否されても動作に影響が無く、開けると面が広がるもの。

| 拒否 | 残す理由 |
|---|---|
| mach: `com.apple.CoreServices.coreservicesd` | LaunchServices。`open` の経路 |
| mach: `com.apple.windowserver.active`・`com.apple.tccd.system` | 画面と権限。シナリオの駆動に要らない |
| mach: `com.apple.AppSSO.service-xpc`・`com.apple.usymptomsd`・`com.apple.analyticsd` | 認証・通信の診断・利用統計 |
| mach: `com.apple.DiskArbitration.diskarbitrationd`・`distributed_notifications` | ディスクの通知・全体通知 |
| `system-info vfs.disk-space` | 空き容量の問い合わせ。フル E2E で 8,000 回以上拒否されるが影響は無い |

---

## 5. 子が書く場所

「書けない」は静かに効く。3通りの方法で洗い出した。

### 5.1 E2E で赤になったもの

`clearAppData` が 14 本落ちた。Simulator のアプリのデータコンテナ
(`~/Library/Developer/CoreSimulator/Devices/<udid>/data/Containers/Data/Application/…`)の中身を、
`FileManager` で直接消していたため。正規表現で、データコンテナだけを開けた
(アプリ本体の `Bundle/` と、コンテナの外は開けない)。

### 5.2 コードの棚卸しで見つかったもの

E2E では赤にならないが、書けないと**黙って効かなくなる**もの。

| 場所 | 書けないとき |
|---|---|
| `~/Library/Caches/fleetest/`(`FMLock`・`FMBreaker`) | ロックは「取れた」ことになり、機械全体の FM の並列枠が無言で効かなくなる。ブレーカは落ちた事実を残せない |
| ツール本体側の `.fleetest/`(受け手の外部パッケージ構成) | in-app ブリッジの記録が更新されず、次の供給が残骸を見誤る |
| `~/Library/HTTPStorages/<実行バイナリ名>/` | `URLSession.shared` の既定の保存先 |
| `FT_*_DIR` で差し替えた置き場 | 保守者用のダンプ・台帳が書けない |

**赤にならない不足は、デバイス実行を何周しても見つからない。** 書き込みの呼び出し形
(`write(to:`・`createDirectory`・`removeItem`・`open(O_CREAT)` など)を grep で列挙し、
子の実行時に通るかを呼び出し元まで辿って仕分けた。

### 5.3 書ける場所に入れてはいけないもの

**そこに置いた物が、枠の外で実行・解釈されないか**を先に見る。

- `<root>/.fleetest/hooks/<pid>.json` は、次の run が読んで `teardown.sh` を枠の外で実行する。
  `.fleetest/` は書けるようにしたが、`hooks/` だけ拒否に戻した。
- `/private/tmp` は入れない(共有の置き場)。**ユーザーごとの一時領域(`/var/folders/xx/yy/`)も丸ごとは開けない**
  (他のツールが信じて読む `T/xcrun_db`・`C/clang` のモジュールキャッシュ・VSCode のシェル統合のファイルを
  書き換えられる)。開けるのは次の5つだけ:
  - 子専用の `T/fleetest-sandbox/<実行バイナリ名>/`(子の `TMPDIR`)と `C/<実行バイナリ名>/`
  - Foundation の作業フォルダ `T/TemporaryItems/NSIRD_<実行バイナリ名>_…`
  - Core ML のコンパイル先 `T/model_*.mlmodelc` と Create ML の学習の出力先 `T/CreateMLModels/`(どちらも名前に
    プロセス名が入らず、他のプロセスのものにも当たる)

  **OS の部品は `TMPDIR` を見ない**(`NSTemporaryDirectory()`・`FileManager.temporaryDirectory`・`MLModel.compileModel`・
  Create ML。実測)。子に入るコードは `TemporaryDirectory.url` を使う(`TemporaryDirectoryScanTests`)。OS の部品の
  書き先を閉じると**黙って縮退する**: Core ML のコンパイル先を閉じた版では分類器が「“model.mlmodelc” couldn’t be moved」で
  全 SUT で使えず、a11y で読めない部品(E2E-iOS の `#radio_a`)だけが赤になり、読める部品は a11y へ倒れて緑のままだった。
  Create ML の出力先は、学習済みのキャッシュを消す `Scripts/e2e.sh --retrain-classifiers` で初めて見つかった(学習は見本を
  変えたときしか通らない)。縮退を見つける仕組みは docs/verification.md の該当節。
  Metal のシェーダキャッシュ `C/com.apple.metal/` はユーザー全体で共有されるので閉じたまま(E2E-CMP の iOS で拒否は
  約 1,400 件出るが、所要は変わらなかった)。
- 同じ理由で拒否に戻したもの(2026-10-06 の棚卸し): `<root>/.fleetest/DerivedData*`(ランナーの xctestrun と .app を
  親が xcodebuild で起動する。子はランナーをビルドしない)・`bridge-*.{pid,endpoint,device,toolchain,ready,adopt,log}`
  (親が kill・外への接続・デバイスの帰属・追記に使う。**`.inapp` は子の `InAppLauncher` が書くので開けたまま** ——
  代わりに読む側が udid と bundleID を文法で検める)・`~/.fleetest/ftbridge.apk`(親が全 Android 端末へ入れる)・
  `~/.fleetest/dispatch.lock` と `dispatch.queue`(1マシン1 run の門)。
- **根そのものは書かせない**。subpath は根自身にも当たるので、子は空にした根を `rmdir` して同じパスに symlink を
  作れた(実測)。次の起動で `canonicalPath` がその先を書ける場所に入れる。根は `(deny file-write* (literal …))` で
  閉じ、親が起動前に作って symlink なら止める(`prepareWritableRoots`)。アプリのデータコンテナも同じ型で、
  正規表現を `Application/<UUID>/` より下だけにした(`<UUID>` を symlink に差し替えると、親の `clearAppData` が
  先を消す。差し替えは実測で通った。`clearAppData` 側でも symlink を断る)。

---

### 5.4 移植後のフル E2E で見つかったもの(2026-10-06)

緑の PoC から6日分の機能が増えた状態で常に有効にし、フル E2E(この Mac・8 プロファイル 391 本)を回すと
13 本が赤になった。サンドボックスの無い HEAD で同じシナリオを回す対照で、9 本が枠の中でだけ落ちると確定した。

| 赤 | 原因 | 対処 | 拒否ログ |
|---|---|---|---|
| 画像照合 7 本(「同じ画像に違う特徴量」「単色」) | 子から画像判定の補助プロセス(§67 の `VisionHelperHost`)への unix ソケットの接続が EPERM。ANE が壊れた機械で Vision の異常を救えなかった | `Scope.helperSockets` で名指しして開ける | **出なかった**(unix ソケットの connect の拒否は `log stream` に載らないことがある。失敗文の `connect: errno 1` で気づいた) |
| チェック状態 2 本(分類器) | Create ML が見本の画像を1枚も見つけられない(`No data found for label`)。UTType の判定に LaunchServices の DB の読み取り専用の写像 `com.apple.lsd.mapdb` が要る | `machServices` に足す(`coreservicesd`・`lsd.modifydb` は閉じたまま。`open -a` は断られることを確かめた) | 3 件出ていた(害が無いと誤って読み流しうる) |
| OCR だけの判定の反転 4 本 | この機械の FM の死(ANE のエラー 53。枠の外でも同じ) | なし(サンドボックスと無関係) | — |

**分類器の赤は、学習済みのモデルのキャッシュが無い作業ツリーでしか出ない**。main の E2E は 9/19 に学習した
モデルを読むだけで、学習の経路を1度も通らない。受け手が見本を初めて置いたときには必ず通る経路なので、
**キャッシュの有無で通る経路が変わる機能は、キャッシュを消した状態でも1回通す**。

## 6. Simulator の操作を親へ移す

### 6.1 横取りの場所

シナリオ実行バイナリに入るコードには、`xcrun simctl` の呼び出しが 40 箇所以上ある
(`BridgeClient`・`InAppDriver`・`FastLaunchDriver`・`InAppLauncher` など)。1つずつ書き換えず、
**`Shell.runRaw` の入口で横取りした**。`FT_SANDBOX_BROKER` が立っているときだけ、
`xcrun simctl …` を unix ソケットで親へ送る。呼び出し元は1行も変えていない。

- 環境変数は `Shell.run` の流儀(先頭の `NAME=VALUE`)のまま運ぶ。
  `InAppLauncher` の `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=…` がそのまま親へ届く。
- CoreSimulator の直叩き(`FTCoreSimShim`)は `FT_SIMULATOR_CONTROL=simctl` で止める。
  既存の殺しスイッチがそのまま使えた。
- stdout の NDJSON に相乗りせず、専用のソケットにした。同期の呼び出し元から
  「送って、返事を待つ」を素直に書ける。

### 6.2 親が断るもの

| 断るもの | 理由 |
|---|---|
| 列挙に無い動詞(`erase`・`delete`・`io`・`push` など) | 使っていない操作を開けない |
| レーン以外のデバイス | 他のレーンのデバイスを壊せる |
| `spawn` の固定2形以外 | Simulator の中 = 枠の外で任意のコマンドを起こす口 |
| 子が書ける場所からの `install` | 枠の中で作った実行物を Simulator で動かせる |
| `launch` の環境変数のうち、決まった4つ以外 | 起動するアプリ(枠の外のプロセス)へ任意の環境を渡せる |
| ツール本体の `InAppBridge/build/` 以外の `DYLD_INSERT_LIBRARIES` | 任意のライブラリを注入できる |

`spawn` で残した2形は、`launchctl list` と、`clearAppData` 後の
`launchctl kickstart -k system/com.apple.cfprefsd.xpc.daemon`。

### 6.3 親を落とされない

子が接続を先に閉じると、親の応答の `write` が SIGPIPE になり、**親(run 全体)が落ちた**。
`SO_NOSIGPIPE` を accept 後に掛けても、相手が既に閉じていると `setsockopt` が失敗して効かない。
**待受のソケットに掛ける**(accept したソケットが引き継ぐ)。

枠の外で動く受け口は、相手が悪意を持つ前提で書く。

---

## 7. ドメイン単位の通信

Seatbelt では名前で絞れないので(§2.5)、親がプロキシを起動し、子には `HTTP(S)_PROXY` で場所を渡す。
子から見えるのは localhost のポートだけなので、枠の規則は変えなくてよい。

| クライアント | 結果 |
|---|---|
| `curl`(環境変数のプロキシを読む) | 許可した宛先は 200、それ以外は届かない |
| `URLSession`(既定の設定) | 環境変数を読まないので、直接繋ごうとして拒否される |
| `URLSession` + `connectionProxyDictionary` | 許可した宛先は 200(`trustd.agent` を開けてから。閉じたままだと -1202) |

- 名前の照合は接続の前に行い、解決は親が行う。
- `*` 単独や途中のワイルドカードは受けない(「全部通す」を書けなくする)。
- `*.example.com` は `example.com` 自身を含まない。接尾辞の一致は区切りを跨がせない
  (`evilcdn.example.net` を `*.cdn.example.net` に当てない)。

---

## 8. 壁の外に残るもの

### 8.1 シナリオ実行バイナリは、起こし方に関わらず利用者のコードを実行しうる

`_Main.swift` もシナリオの置き場にある。だから、シナリオの本体を実行しない起動
(一覧取得 `list`・OCR のコンパイル `compile-ocr`)も同じ枠で包む。

PoC の最初の実装では `fleetest run --dry-run` が包まれていなかった(証人シナリオで発覚)。
`--dry-run` はプロファイルも `--set` も使わない作りで、シナリオの本体は dry-run でも実行される。
PoC はプロファイルから `sandbox` だけを先に読む口を全呼び手に足して塞いだ。**移植では常に有効にしたので、
包む判断は入口の中で完結し、呼び手は何も運ばない**(配線の取りこぼしが起きる場所自体が無くなった)。

### 8.2 localhost

子はドライバそのもので、ブリッジへ繋ぐ。`localhost:*` を開けている。

- **adb は親が代行する**(`AdbPolicy`。2026-10-06)。子からは adb サーバ(5037)と Emulator の
  コンソール / adbd(5554〜5585)へ繋げない(`localhost:*` の許可より後で拒否)。adb の鍵(`~/.android`)と
  コンソールの鍵も読ませない。閉じる前は、adb サーバ経由で Emulator の shell に届き、Emulator から外部へ
  通信できた(`10.0.2.2` でホストのループバックにも届く)。証人シナリオで、枠の中から 5037・5554・5555 への
  接続・`adbkey` の読み取り・adb の CLI の直接起動がすべて失敗し、同じシナリオの操作は動くことを確かめた。
- マシン側の `allowDirectAdb: true` で、子が adb / bundletool を自分で使う形に戻せる(ポートと `~/.android` を開け、
  子の `FT_SANDBOX_DIRECT_ADB=1` で横取りを止める。この環境変数は経路を選ぶだけで、閉じたポートは開かない)。
  性能差は実測で無視できる(2026-10-06・E2E-Android の android 43本 × 3回ずつ交互: シナリオ合計の中央値は
  代行 457.4s / 直接 451.6s で差 1.3%・条件内の振れ 5.6s と同程度、壁時計は暖機を除いて両方 108〜109s。
  adb 1回の中央値は代行 25.1ms / 直接 24.6ms)。
- Android のブリッジは `adb forward` がホスト側のポートを動的に取るので、ポート単位には絞れていない。
  他のデバイスのブリッジ・Emulator の gRPC・Mac の localhost で動く他のサービスには届く。
- これらまで閉じるには、ドライバごと親へ移す(子は DSL の評価だけを行い、`AppDriver` の呼び出しを
  全部親へ頼む)。今回はやっていない。

### 8.3 デバイスを介した持ち出し

シナリオはアプリやブラウザに文字を入力できる。読めたファイルの中身は、UI 操作で外へ送れる。
ドライバを親へ移しても閉じない。効くのは**読ませないこと**だけ。

読み取りは「全部読める − 拒否の一覧」の形。一覧は内蔵の `defaultDenyReadHomeSubpaths`(認証情報・個人データの
定番の置き場)にマシン側の `denyRead` を足したもの(置き換えはできない)。一覧に無い場所は読める。

### 8.4 テスト対象のアプリ

Simulator の中のアプリは、Mac 上では枠の外のプロセスで、ユーザーのホームを読み書きできる。
親がインストールするアプリ(プロファイルの `appPath`)は信頼の前提。

### 8.5 設定の置き場と環境変数

PoC では実行プロファイルと構成ファイル(プロジェクトの中)に設定があり、プロジェクトを書き換えられる相手は
枠を外せた。移植では**設定をマシン側の `~/.config/fleetest/config.json` の `sandbox` だけ**に置き、受け手の
`.claude/settings.json` にそのフォルダの Edit deny を書く。

移植の途中で、PoC が**環境変数から枠の形を作っていた**ことに気づいて塞いだ(環境変数は `.mcp.json` の `env`
やコマンド行で差し替えられる):

| PoC の形 | 起きうること | 移植の形 |
|---|---|---|
| ホームを `HOME` から取る | 偽のホームに `~/.ssh` の拒否が組まれ、本物が読める | `getpwuid` |
| 設定を `XDG_CONFIG_HOME` から探す | 別の設定へ向けて `disabled` を立てられる | 実ホームの固定パス |
| `TMPDIR` を書ける場所に足す | `TMPDIR=~/Library/LaunchAgents` で任意の場所が書ける | 子の `TMPDIR` を明示して渡す |
| `FT_*_DIR` を書ける場所に足す | 同上 | 書ける場所の中を指すときだけ通し、外なら起動前に止める |
| `FT_TOOL_ROOT` の `.fleetest` を足す | 任意の場所の `.fleetest` が書ける | ツール本体の目印があるときだけ |

**子へ渡す環境そのものも許可リストで絞る**(`ScenarioSandbox.inheritedEnvironment`)。親の環境を丸ごと継がせると、
`.mcp.json` の `env` やシェルのトークン(`GITHUB_TOKEN`・`ANTHROPIC_API_KEY`・`AWS_*`)をシナリオが読み、
UI 操作で持ち出せる(§8.3)。渡すのは `FT_*`・`LC_*` と、Sources の `environment["…"]` / `getenv` を
棚卸しした鍵だけ(`PATH`・`HOME`・`DEVELOPER_DIR`・`ANDROID_HOME` など)。一覧取得は `/usr/bin/env -i` で
起こす(`Shell.run` は `/usr/bin/env` 経由で、`-i` が無いと親の環境を継ぐ)。**利用者が環境変数でシナリオへ値を
渡す口は無くなった**(必要になったら、マシン側の設定で鍵を名指しする形で足す)。

### 8.5.1 塞いだ低コストの穴(2026-10-06)

| 穴 | 実測・根拠 | 塞ぎ方 |
|---|---|---|
| `/dev` を丸ごと書けた | 枠の中から同じユーザーの `/dev/ttys000` を書き込みで開けた(他の端末へ偽の表示・エスケープシーケンス。TIOCSTI は `file-ioctl` の拒否で通らない) | `/dev/null`・`/dev/zero`・`/dev/tty`・`/dev/random`・`/dev/urandom`・`/dev/dtracehelper` の literal と `/dev/fd` だけ |
| 全 Simulator のデータコンテナが書けた | 正規表現の UDID が `[^/]+` | レーンの UDID(iOS の Simulator・UUID の形)が分かるときはその1台だけ。ポートだけを指定した run は従来どおり全台 |
| 読ませない一覧の抜け | `~/.gradle`(署名鍵のパスワード)・`~/.m2`・App Store Connect の API 鍵・fastlane のセッション・シェルの履歴など | `defaultDenyReadHomeSubpaths` に足した。**`Library/Mobile Documents` は入れない**(iCloud の「デスクトップと書類」では `~/Documents` の実体がその下にあり、そこのプロジェクトを読めなくなる) |
| 親の環境変数が全部子へ渡っていた | `ScenarioHost` が親の環境に入口の分を `merging` していた | 上の許可リスト |
| 書ける場所の根・データコンテナを symlink に差し替えられた | 実測(§5.3) | 根は literal で拒否・親が作って symlink なら止める・正規表現を `<UUID>/` より下に |
| 親が信じる台帳・成果物を書けた | コード(§5.3) | 拒否に足した |

| ユーザーの一時領域 `/var/folders/xx/yy/` を丸ごと書けた | 書ける集合の根が T・C・0・X の親だった(xcrun が細工した `xcrun_db` を信じるかは未実測) | 子専用の一時フォルダ・キャッシュ・作業フォルダだけ(§5.3) |
| broker の判定と実行の間にパスを差し替えられた | 子が送ったパスの文字列のまま実行していた(途中に子が書ける場所の symlink を挟むと「子が書けない場所」として検めさせ、実行の直前に向きを変えられる)。devicectl の出力ファイルは親が子の場所へ書いていた | 検めたパスを実体パスに固定して実行する(`BrokerPolicy.pinned`。install の元・注入するライブラリ・`.apks`)。devicectl の出力は親だけの一時ファイルに書かせ、中身を応答で返して子が枠の中で書く |

**棚卸しで残したもの**(未着手。重い順): ①親が子の書ける場所へ予測できる名前で atomic でなく書く箇所(FM ブレーカの
状態・Metal 異常の履歴など。Android の状態ファイルは子の分が子専用の一時フォルダへ移ったので親の分には届かない)——
symlink を置かれると先を壊す ②子が localhost で偽のブリッジを待ち受けられる ③レポートの Markdown プレビューが
外部の画像を読む。

**他のプロセスの環境変数は枠の中から読めない**(実測: `KERN_PROCARGS2` は macOS 27.2 では argv しか返さない。
枠の外でも同じ)。コマンドラインは枠の外と同じく読める(`process-info*` を開けている)。

### 8.6 ブリッジの HTTP 口

XCUITest ランナー・in-app・Android の3つの全エンドポイントを棚卸しした。Mac 上のファイルの読み書きや
コマンド実行をさせる口は見つからなかった(パスを受ける口は 0 件・スクリーンショットは HTTP 応答で返す)。
UI 操作のハンドラ本体の一部は語句検索だけで、本文は読んでいない。

- Simulator のブリッジに認証は無い(トークンは実機を LAN に出すときだけ)。
- Android の `/session` は `bundleID` を検証せずに端末内の shell コマンドへ連結している。
  端末の中の話で、Mac 上の実行ではない。`UiAutomation.executeShellCommand` は sh を介さず空白で
  区切って実行するので、`;` で別コマンドにはならない(引数の差し込みまで)。ホストの `adb shell` は
  端末側の sh が解釈し直すので、パッケージ名を埋める箇所は全部 `AndroidPackageName` で検めてから撃つ
  (`AndroidDriver.launch` も `/session` の前に検める)。

---

## 9. 調べ方

### 9.1 拒否をログから拾う

`log show`(過去のログの検索)では1件も出なかった。**先に `log stream` を起こしてから**実行すると出る。

```sh
/usr/bin/log stream --style compact --predicate 'sender == "Sandbox"' > deny.raw 2>&1 &
LP=$!; sleep 1.5
sandbox-exec -f profile.sb <コマンド>
sleep 1.5; kill $LP
grep -E 'Sandbox: (fleetest-scenari|xcrun|simctl|adb)' deny.raw
```

```
kernel (Sandbox) Sandbox: fleetest-scenarios-E2E-iOS(2397) deny(1) mach-lookup com.apple.appleneuralengine
kernel (Sandbox) Sandbox: touch(92237) deny(1) file-write-create /private/tmp/…/outside/x
```

- **zsh の `log` は組み込み関数**。`/usr/bin/log` とフルパスで書く
  (組み込みに当たると `too many arguments` で、何も検索されない)。
- システムの他のプロセスの拒否も混ざる(`sharingd`・`rapportd` など)。プロセス名で絞る。
- パスの中の UUID と一時領域の部分を置き換えてから集計すると、種類ごとに数えられる。
- `(deny … (with report))` は書式エラーになる(拒否は既定で報告される)。
  `(allow … (with report))` を書いてもログには出なかった。

### 9.2 証人シナリオ

「包まれているか」「何が断られるか」を、一時的なシナリオで直接確かめる。シナリオの本体の先頭
(`scenario { }` の前)で試し、結果を `print` する。無効で全部通り、有効で全部断られることを両方見る。

```swift
func write(_ path: String) -> String {
    do { try Data("x".utf8).write(to: URL(fileURLWithPath: path)); return "WROTE" } catch { return "DENIED" }
}
print("WITNESS home=\(write(NSHomeDirectory() + "/ft-sandbox-witness.txt"))")
print("WITNESS ssh=\((try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.ssh")) == nil ? "DENIED" : "READ")")
print("WITNESS net=\((try? String(contentsOf: URL(string: "https://example.com")!, encoding: .utf8)) == nil ? "DENIED" : "REACHED")")
// ほかに: `open -g -a <アプリ>` の終了コード・`xcrun simctl list` の終了コード・
// `curl` とプロキシ経由の URLSession(許可した宛先 / していない宛先)
```

- `print` が出力に載らない経路(`api steps`)は、書き込み先のファイルの有無と、
  `open` で起動したアプリの有無で判定する。
- 証人が書いたファイルと、起動したアプリは毎回片付ける。無効の側では実際に書かれ、起動する。
- 証人シナリオは `TestProjects/` に一時的に置き、コミットしない。

### 9.3 E2E

常に有効なので、引数なしの `Scripts/e2e.sh` がそのまま枠の中の実行になる(PoC の `--sandbox` は無い)。

`log stream` を並べて起こしておくと、緑の run で「拒否されたが影響が無かったもの」も分かる。

---

## 10. 踏んだ失敗

| 失敗 | 起きたこと | 学んだこと |
|---|---|---|
| 「拒否はログに出ない」と結論した | `log show` と zsh の組み込み `log` で探して 0 件だった。`log stream` では出ていた | 「無い」の観測は、出る手段が生きているかを先に確かめる。この誤りのせいで、最初は全拒否を「必要な許可が分からないので無理」と退けていた |
| SwiftPM が枠の中で通ったように見えた | Package.swift のコンパイル結果がキャッシュされていて、2回目は内側のサンドボックスを使わなかった | 陽性対照は、キャッシュを外した状態で通す |
| 通信の規則が何も絞っていなかった | `(local ip "localhost:*")` のせいで外部へ繋がった(§2.6)。単体テストで発覚 | 規則は文字列でなく、実際に掛けた結果で確かめる |
| 「自機の LAN アドレスは外部」と想定したテスト | `localhost` は自機の全アドレスを含むので、拒否されなかった | 外部の宛先には、どこにも届かない文書用アドレス(`192.0.2.1`)を使い、**拒否(即 EPERM)と到達不能(時間切れ)を文言で分ける**。ネットワークに出られない環境でも結果が変わらない |
| `nc -U -z` で unix ソケットの到達を確かめた | 枠の外でも exit 1 だった(`nc` 側の制約) | 確認の道具が枠の外で通ることを先に見る。`curl --unix-socket` の終了コード 7(繋げない)で判定した |
| dry-run が包まれていなかった | 単体テストは緑。証人シナリオで発覚 | 配線は実データで1回動かすまで信用しない |
| 必要な許可が足りないまま E2E を回した | 赤が出る前に所要が 12 倍になり、25 分で 1 プロファイルしか終わらなかった | 全数を回す前に、機能ごとの代表(画像照合・OCR・チェック状態・入力)を数本で通す |

---

## 11. エージェントのサンドボックスとの関係

この機能の出発点は「DevContainer の中で fleetest をセットアップしたら preflight で落ちた」だった。

- **コンテナ(Linux)の中では動かせない**。Simulator・Xcode・オンデバイスの FM が無い。
  `install.sh` も Darwin 以外では止まる。
- **エージェントのサンドボックス(Claude Code・Codex)は、エージェントが打つシェルコマンドだけを縛る**。
  MCP サーバと、そこから起動される fleetest は枠の外で動く。`ft_*` は設定なしで全部使える
  (Codex での実測。[user-docs/reference/tools/other_agents_ja.md](user-docs/reference/tools/other_agents_ja.md))。
- **シェル経由の導入・更新は、エージェントの枠の中では通らない**。SwiftPM の入れ子(§2.8)と、
  CoreSimulator への接続が塞がれるため。
- **エージェントを縛っても、エージェントが書いたシナリオは枠の外で動く**。fleetest が実行する
  シナリオのコードを縛るのが、この機能の役割。

---

## 12. 確認したこと・していないこと(2026-10-06 の移植後)

**確認した**:

- **フル E2E(この Mac・in-app・8 プロファイル 391 本)**: 赤 13 本のうち 9 本が枠の中でだけ落ちる(§5.4 で
  対処して全部緑)。残り 4 本は FM の死による OCR だけの判定の反転で、枠と無関係
- **XCUITest エンジン(この Mac・4 プロファイル 201 本)**: 赤は残ったシステムアラートの巻き込み・OCR だけの判定の
  反転・ランナーの自動化エラー(500)で、枠の中でだけ落ちるものは無かった(`システムアラートの操作.S0020` は
  枠の中・外とも 2/2 緑 = 負荷の下の揺らぎ)
- **リモートのランナー**: M1Ultra の E2EX(8 プロファイル 392 本・赤 1 本 = Android のツールチップの既知の性質)、
  手元からの送り出し 1 本、ランナー上の dry-run(🔒 の行)
- **攻撃の止まり方(dry-run の簡易版)**: ホームへの書き込み・`~/.ssh` の読み取り・外部への通信・`open -a` が全部失敗
- **iOS の実機(iPhone SE3・XCUITest エンジン)**: 起動と画面遷移の 1 本と、ディープリンクの 1 本(`launchApp(url:)` =
  実機では `devicectl device process openURL` を親が代行)が枠の中で緑

**確認していない**:

- **iOS の実機の `devicectl` の他の形**(アプリ一覧・プロセス一覧・ロック状態・インストール)は単体テストだけ。
  LAN 越しのブリッジのポートを開ける規則も単体テストだけ
- **FoundationModels**。2026-09-30 と 2026-10-06 はこの Mac の FM が死んでいた(10-06 は枠の外でも ANE の
  エラー 53)。`com.apple.modelmanager` は開けてあるが、枠の中で推論が通るかは未確認
- **受け手の外部パッケージ構成**。ツール本体側の `.fleetest/` を開ける処理は単体テストだけ
- **Android の実機**
