# 検証の詳細と落とし穴

CLAUDE.md「ビルド・検証」からの詳細分。コマンドと最重要ゲートは CLAUDE.md 側に残し、
ここには**頻度は低いが踏むと痛い罠と判定規律**を置く。読者は保守者(Claude Code)。

## flake・性能の判定規律(1回の結果で断じない)

- **flake の修正は「1回グリーン」で判定しない**。flake は確率的で、低負荷なら偶然通る。
  確認は**反復+負荷**で叩く(該当シナリオ単独 ×10、または該当プロファイルをフル並列で ×4〜6)。
  実害: 「v10 で直した・10連続グリーン」と報告した直後にフル並列で再発し、修正コードが**実際には
  実行されていなかった**と判明した(2026-07-23。type(ref) をホスト側で tap+ref:nil に分解していて
  ブリッジの ref 経路に到達していなかった)
- **修正を入れたら、その修正コードが実行される経路か確認する**。層をまたぐ実装(ホスト↔ブリッジ、
  driver↔StepExecutor)では上の層が下の層の入力を作り替えていて下の修正が空振りすることがある。
  症状が消えないときは「直したはずの箇所に本当に到達しているか」をログ/ブレークで確かめてから次を疑う
- **性能・不具合を1回の観測で断じない**。壁時計はコールドスタートの供給や一過性のブリッジ切断で
  大きく揺れ、どちらも定常性能ではない。各プロファイル 2〜3 回計測して定常値を取る。
  揺れの要因・数値・誤評価の実害事例は docs/performance-tuning.md §7 に集約(数値の更新はそちらで)
- **「この指標が異常個体を表す」は1個体でなく全数で確かめる**。壊れた個体だけを見ると、たまたま
  高い指標が原因に見える。実害: 凍結した1台の Metal エラー増加速度(+148/5分)を見て「速度で
  異常機を特定できる」と結論しかけたが、**フリート8台を集計すると健全機の方が高かった**
  (最大 288/分)。指標が個体を分離できるかは「異常機 vs 健全機」を並べて初めて言える
  (このケースの結論と全数データは performance-tuning.md §7)

## `Scripts/e2e.sh`(ftester 自身の E2E)

- SUT(`E2EApp/` 他)の鮮度を見て必要なら再ビルドし、各プロファイルを順に回す。オプション:
  `--rebuild` / `--ios` / `--android` / `--cmp` / `--ios-native` / `--android-native` / `--flutter` /
  `--record`(録画パイプラインの整合チェック付き。詳細は下記「録画」節)
- **両OSを1プロファイルにまとめない**: platform 未指定シナリオは既定 platform のキューにしか入らず
  他方のワーカーが空回りする(design.md §11.4)。SUT はネットワーク依存ゼロなのでバックエンド死活の
  切り分けは不要
- **フレームワーク差の退行は SUT を跨がないと出ない**。ブリッジのスナップショット/型写像
  (`SnapshotBuilder`・`BridgeRouter`)を触ったら SUT を絞らず全部回す。片方だけ通って
  もう片方が黙って空振りする類の退行が実際に出る(Compose の Button は `Cell`、View/XML は `Button` 等)

## 常駐プロセスの掃除

- 再ビルド後の検証前に旧バイナリの常駐プロセス(monitor/host-metrics)を kill する
  (生き残って検証を汚す・旧ブリッジを自動再起動する。docs/performance-tuning.md §7)
- **調査で `ftester api monitor` を手で回すときは stdin を開いたままにする**
  (`tail -f /dev/null | ftester api monitor ...`)。**stdin の EOF が終了指示**なので、
  スクリプトからバックグラウンド実行すると /dev/null が即 EOF になり、
  **1行も出さずに正常終了**する(「監視が何も返さない」ように見える罠)

## macOS / Xcode ベータの整合

- macOS ベータを更新したら Xcode も同じベータへ揃えてフルリビルド。FoundationModels の ABI 不整合で
  全バイナリが dyld クラッシュする(swift build は SDKROOT/--sdk を無視するため Xcode 側を揃えるしかない)
- Xcode(beta)単体の更新でも同様: iOS ランタイム導入(`xcodebuild -downloadPlatform iOS`)+
  ランナー再ビルドで整合させる。不整合はアプリが数操作で「Application is not running」クラッシュする
  (`ftester doctor` が DTXcodeBuild 不一致を警告。2026-07-21 実害)

## テストが接続拒否(「ドライバへの接続が拒否されました」)で全滅したら

まず**プロファイル経路で走ったか**を確かめる。実行プロファイル未指定だと `--platform/--port` の
直接ポート接続に落ち、**ブリッジが自動供給されない**ため、事前に `bridge up` していなければ
全シナリオが即失敗する(拡張は 2026-07-26 から未指定で実行を止めるが、CLI では今も起こる)。

- **run.json の `machine` がホスト名なら非プロファイル経路**(プロファイル経由ならマシン
  プロファイル名が入る)。`scutil --get ComputerName` と比べれば一目で分かる
- **全シナリオが数十 ms・run 全体が数秒**なら供給が一度も走っていない(供給は数十秒かかる)
- 生きているブリッジは `curl -s 127.0.0.1:<port>/status` で確認する。`.ftester/bridge-<port>.log`
  や `bridge-<port>.inapp` は**残骸が残る**ので、ファイルの存在は稼働の証拠にならない。
  `/status` の `sessionBundleID` で「どのアプリのブリッジか」まで見ること(別 SUT のブリッジが
  生きていても対象アプリには使えない)

## テストが「Application is not running」で全滅したら

ランナーや自分の変更を疑う前に **SUT のバックエンド死活を確認**する
(sut-ec-mobile は localhost:8090 の dev サーバ。停止中はアプリが非同期例外でクラッシュする)。
apps プロファイルの healthCheckURL が実行開始時に警告を出す。

## Android 凍結まわりの検証の罠

- **画面 OFF(KEYCODE_SLEEP)はフェイク凍結として万能ではない**: screencap は実凍結と同一の
  一様フレーム(<30KB)になるため **blank 検出・事前修復パスの検証には使える**(検出→sleep/wake
  修復→回復、が決定論的に再現する)。しかし **a11y 駆動(tap/type/textIs)は画面 OFF でも全て通る**
  (実測: シナリオ実行中に画面 OFF にしても 18/18 成功)ため、「シナリオ失敗→凍結判定→修復」の
  実行中経路は発火させられない。さらにシナリオの launch が画面を起こす過渡で別種の失敗が出る
  (注入アーティファクト。実凍結の症状ではない)。実行中修復パスの実発火はフェイクで強制できず、
  本番ログの「実行中の画面凍結を修復」で観測する
- **実凍結は事前修復が先に治すため「実行中だけ凍結」を意図的に作れない**(実凍結の誘発は
  8台並列 run の反復のみ。1台単独負荷・アイドルでは発生しない。performance-tuning.md §7)
- **凍結のホスト側証跡は `~/Library/Logs/ftester/emulator/<AVD>.log`**(DeviceBooter が
  emulator stdout/stderr を保存。ブート毎 truncate)。根因の Metal エラー
  (`GLDRendererMetal command buffer completion error` / `IOGPUCommandQueueErrorDomain 518`)は
  ここにしか出ない(2026-07-25 実測)。凍結個体を調べるときはまずこのログを見る
- **エミュレータ操作は既定で emulator gRPC(EmulatorController)経由**(スクショ/キー・タッチ注入/
  停止等。実機・gRPC 失敗個体は自動で adb フォールバック。`Sources/FTAndroid/EmulatorControl.swift`)。
  gRPC 起因を疑うときは **`FT_EMULATOR_CONTROL=adb`** で全面 adb に切り替えて比較できる
  (拡張側 `vscode-ftester/src/emulatorGrpc.ts` も同じ環境変数)。挙動差の切り分けはまずこれ。
  **iOS のシミュレータ列挙も同様に CoreSimulator 直叩きが既定**(design.md §16.4)で、
  **`FT_SIMULATOR_CONTROL=simctl`** が殺しスイッチ
- **run が遅くなったら負荷トリアージを先に**: ① `top` で qemu の空転(劣化個体はアイドルでも
  ~73%/台消費しホスト全体を遅くする)② run 同梱の `host-metrics.ndjson`(遅い run だけ CPU 飽和
  していれば環境要因)。Spotlight/mediaanalysisd のインデックスストームは CPU 数百%でも run を
  ほぼ遅くしない(M2 Ultra 実測)ので容疑から外してよい
- **guest reboot の完了判定は「1 でなくなる」→「1 になる」の2段で見る**: `adb reboot` 直後は
  まだ旧セッションが `sys.boot_completed=1` を返すため、いきなりブート待ちに入ると即成功して
  再判定が**凍結したままの旧画面**に当たる(run 前トリアージの実装 `ProfileWorkerFactory.rebootGuest`)。
  また再起動中は screencap 自体が失敗し、blank プローブは安全側の「非 blank」に倒れるので、
  **ブート完了を確認できない個体を blank 再判定に掛けてはいけない**(復帰と誤認する)
- **CPU 描画(swiftshader)フォールバックは emulator プロセスを再起動しないと戻らない**
  (`-gpu` は起動引数固定。ゲスト再起動・gRPC RESET では戻らない)。戻す経路はモニターの
  「GPUで再起動」「デバイスを全て起動」と、実行プロファイルの `recoverCpuFallbackToGpu`
  (design.md §11)。**例外**: Wipe Data の再ブートは `startEmulator` の既定 `-gpu host` で
  起き上がるため、しきい値超過の個体は副作用で GPU に戻る(意図した復帰機能ではない)
- **凍結調査は両経路スイープで**(`adb screencap` サイズと gRPC スクショの画素一様判定を並記)。
  readback 白化と host キャプチャ黒は独立に壊れるため片経路だけでは誤診する。シナリオ成功率は
  表示層の劣化を映さない(凍結9/14台でも 18/18 成功する)。変種一覧・スケール上限・Metal エラー
  指標の正本は performance-tuning.md §7

## 実機(kind: physical)の検証

プロファイルの書き方は design.md §11.2。ここは実機でだけ踏む罠だけを置く。

### Android 実機

- **画面ロックは「なし」にしておく**。PIN/パターンが設定されていると adb から解除できず、
  ロック中は `UiAutomation.getRootInActiveWindow()` が対象アプリにならないので **全シナリオが
  launch 500(「アプリの画面が表示されませんでした」)で落ちる**
- run 前に `AndroidPhysicalDevice.prepareForRun` が点灯・ロック解除・消灯抑止
  (`svc power stayon true`)を行う。`stayon usb` では**効かない**ことがある(AC として認識される
  ケーブル/ハブがあり、bitmask が USB=2 だけだと外れる。true=AC|USB|WIRELESS=7 を使う)
- **ロック状態の判定に `isKeyguardShowing` と `mCurrentFocus` を使ってはいけない**。
  Pixel 4a/Android 13 実測(2026-07-25)で、実際には解除されランチャーが見えている状態でも
  `true` / `NotificationShade` を返し続けた。**信用できるのは `topResumedActivity` の有無だけ**
  (ロック中はどのアクティビティも resume されないので行ごと消える)
- `wm dismiss-keyguard` は非同期で **解除完了まで実測 3〜7 秒**。待たずに launch すると
  run の初回シナリオだけが落ちる(8 run 中 1 件の flake として現れた)
- **画面凍結(blank-screen)判定は実機では動かない**。閾値(30KB)が 1080x2424 エミュレータ較正で、
  誤判定すると健全な実機に `adb reboot` を撃つため、事前トリアージ・事後プローブ・失敗時の
  blank 証跡判定のいずれからも実機を除外してある
- ブリッジ起動時のアニメーション無効化と `hidden_api_policy=1` は **実機では設定が永続する**
  (使い捨てのエミュレータと違う)。戻すときは端末の開発者オプションから
- 検証実績: Pixel 4a(Android 13 / arm64)で E2E-Android 全 21 シナリオ×6 連続グリーン
  (消灯状態からの復帰込み。2026-07-25)

### iOS 実機

- **署名が要る**。`~/.config/ftester/config.json` の `developmentTeam`(または環境変数
  `FT_DEVELOPMENT_TEAM`)に Apple Developer の Team ID を入れる。bundle id プレフィックスは
  `bundleIDPrefix` / `FT_BUNDLE_ID_PREFIX`(既定 `com.example` のままだと他チームが登録済みの
  App ID と衝突しうる)。ビルドは `-allowProvisioningUpdates` 付きで走る
- **Team ID は証明書の OU**。`security find-identity -v -p codesigning` の
  `Apple Development: <you> (XXXXXXXXXX)` の**括弧内は証明書 ID であって Team ID ではない**
  (取り違えると `No Account for Team "..."` で落ちる。2026-07-25 に実際に踏んだ)。正しくは:
  ```
  security find-certificate -c "Apple Development: <you>" -p | openssl x509 -noout -subject
  # → subject= UID=..., CN=Apple Development: ... (証明書ID), OU=GF42S2868Q, ...  ← OU が Team ID
  ```
- 端末側は「このコンピュータを信頼」と **Developer Mode の有効化**が前提。
  `xcrun devicectl list devices` に出ることを先に確認する
- **端末のロックを解除しておく**(Android と同じ前提)。ロックされていると xcodebuild が
  `Unlock <name> to Continue` で無言のまま止まる。テスト中に再ロックされないよう
  **設定 → 画面表示と明るさ → 自動ロック を「なし」**にしておくこと。この条件は
  「失敗」ではなく「進まない」だけなので、検出しても throw せず待ちながら 1 回だけ促す
  (`IOSDeviceTransport.blockingCondition`)
- **端末で開発者証明書の信頼が要る**。ビルドとインストールが成功しても、起動時に
  `The application could not be launched because the Developer App Certificate is not trusted.`
  で落ちる。iPhone の **設定 → 一般 → VPN とデバイス管理** からデベロッパ App の証明書を「信頼」する。
  **「初回だけ」ではない**: 証明書やプロビジョニングプロファイルが作り直されると再度必要になる
  (2026-07-26 に一度信頼済みの端末で再発)
- **端末が起動を拒否した条件は xcodebuild の終端マーカーを待ってはいけない**。証明書未信頼の
  エラーはログの 20 秒時点に出ていたのに、`** TEST EXECUTE FAILED **` も `Testing failed:` も
  最後まで出ず、締切 181 秒まで待たされたうえ「LAN アドレスを取得できません」という無関係な
  理由で失敗した(2026-07-26 実測)。証明書未信頼・Developer Mode 無効は単独で終端扱いにする
  (`IOSDeviceTransport.runnerFailureReason`)。理由を特定できない失敗だけは誤検知を避けるため
  従来どおりマーカー待ち
- `devicectl list devices` の **Identifier 列(UUID)と `hardwareProperties.udid`(`00008130-...`)は
  別物**。`xcodebuild -destination id=` が受け付けるのは後者だけ(`devicectl --device` はどちらでも
  通る)。プロファイルの `udid` には後者を書く(前者を書いても解決はする)
- **`connection.state` は当てにならない**: USB 接続中で `devicectl list devices` が
  `available (paired)` と表示している実機でも `disconnected` のままだった。未接続の実機は
  そもそも一覧に出てこないので、一覧に居ること自体を到達性の主信号にしている
- `hardware.reality`(CoreDevice の `DeviceReality`)は **`physical` / `simulated` / `virtual`(VM)
  の三値**だが、**実機は値を出さずキーごと省略する**(Xcode 27 beta 4 実測: 68 台中 67 台が
  `simulated`、実機 1 台はキー欠落)。`"physical"` 一致で拾うと**実機が 1 台も見えない**ので、
  必ず「`simulated` 以外」で弾くこと
- SUT の実機ビルド例: `E2EAppIOS/scripts/build-ios-device.sh`(`-sdk iphoneos` + 自動署名 →
  `dist/ios-device/`)。シミュレータ版(`dist/ios-simulator/`)とは実体が別なので
  **apps プロファイルを分ける**(`ft_e2e_ios_device.json` / 実行は `ios-device`)
- **xcodebuild のテストログは CRLF**。Swift では `"\r\n"` が 1 つの Character なので
  `split(separator: "\n")` は CRLF を**一切分割しない**(ログ全体が 1 行になる)。
  ランナーの `FT_BRIDGE_ADDR` 宣言を拾う所で踏んで 180 秒待って失敗した。
  ログを行単位で見るコードは `split(whereSeparator: \.isNewline)` を使うこと
- ブリッジの到達手段の確立に失敗したら**必ず `launcher.stop()` する**。xcodebuild は実機で
  走り続けるので、止めないと失敗のたびに常駐ランナーが端末に溜まる(実測で 5 本残った)
- **実機とシミュレータを同じ run に混ぜられる**が、xctestrun は種別ごとに別物なので
  `prepareSharedBuilds` は**種別ごとに build-for-testing する**(1 つだけビルドすると、
  選ばれなかった側が `xctestrunNotFound` で落ちる)
- 検証実績: iPhone 15 Pro(iOS 26.5.2)で E2E-iOS 全 20 シナリオ = LAN ×3・USB ×6 連続グリーン
  (2026-07-25〜26)。ブリッジ供給は約 8 秒。壁時計は USB 181〜211s / LAN 241〜259s
- **トランスポートは端末の接続形態で決まる**: `devicectl` の `transportType` が `wired` でなければ
  (= WiFi のみ)**iproxy は USB トンネルを張れない**ので lan に落ちる。ここを見ずに
  「iproxy があれば usb」で選ぶと、`network connection was lost` で 180 秒待って失敗するだけの
  無情報な結果になる(2026-07-25 に実際に踏んだ)。明示指定 `FT_IOS_DEVICE_TRANSPORT` は尊重する
- **端末ロックの検出は締切後にもう一度ログを読む**。xcodebuild は諦めた時点で初めて
  `Unlock <name> to Continue`(deviceprep Code=-3)を書くことがあり、待機ループ内の読み取りだけでは
  間に合わずタイムアウトとしか出ない(`BridgeLauncher.waitUntilReady` の physicalDiagnosis)
- **ブリッジのトランスポートが 2 択**(デバイス内のループバックはホストから見えない。
  Xcode 27 の devicectl にポート転送は無い)。`FT_IOS_DEVICE_TRANSPORT=lan|usb` で明示、
  未指定なら iproxy があれば usb、無ければ lan。**usb を強く推奨**(下記実測):

  | 経路 | 1 往復(`/status`) | ばらつき | E2E-iOS 20 本 |
  |---|---|---|---|
  | シミュレータ(loopback) | 1.1 ms | σ 0.2 | 174.6s(6 台並列で壁 38.5s) |
  | 実機 **usb**(iproxy) | **4.7 ms** | σ 0.7 | **181.3s** |
  | 実機 lan(WiFi) | 47.9 ms | σ 26.9 | 241.1s |

  LAN が遅いのは **iOS の WiFi 省電力**(ICMP でも avg 74ms / σ 32ms)。DSL の 1 ステップは
  セレクタ解決・操作・整定確認で 8〜13 回ブリッジを往復するため、48ms × 10 回 ≈ +0.5s/ステップに
  なる。ペイロードは 0.1KB なので**帯域ではなく往復回数**の問題(2026-07-25 実測)。
  usb にすると 1 シナリオあたり 12.1s → 9.1s で、シミュレータ(8.7s)とほぼ同等になる:
  - `lan` … ランナーが `0.0.0.0` に bind し(`FT_BIND_ALL=1` を xctestrun に注入)、自分の
    LAN IPv4 を `FT_BRIDGE_ADDR=<ip>:<port>` としてテストログ(`.ftester/bridge-<port>.log`)に
    1 行出す。ホストはそれを読んで宛先にする。**Mac と端末が同じネットワークに居ること**
    (クライアント分離 WiFi では不可)
  - `usb` … `iproxy`(`brew install libimobiledevice`)で USB トンネルを張り 127.0.0.1 を維持する
- 実機とシミュレータで DerivedData を分けてある(`.ftester/DerivedData-device`)。混在させると
  `findXCTestRun` が iphoneos/iphonesimulator の誤った方を掴む
- **engine=xcuitest なら実機で動く、は誤り**だった箇所: `FastLaunchDriver`(xcuitest でも既定 ON・
  中身は `simctl terminate`+`launch`)と `LaunchPreflightDriver`(`simctl get_app_container`)は
  実機では無効化される(`--physical`)。素の `XCUIApplication.launch()` 経路に落ちる
- アプリは `xcrun devicectl device install app` で入る(**署名済みの .app/.ipa が要る**)。
  SUT のシミュレータ用ビルド(`-sdk iphonesimulator`)はそのままでは使えない
- **UDID の先頭は機種共通**(`00008130-` は iPhone 15 Pro 系の固定値)。先頭 8 文字を
  識別子として表示すると同型機が全部同じ表示になる。個体固有なのはハイフン以降

### iOS 実機ブリッジが立たないとき(3 大原因)

原因はほぼこの 3 つ。**いずれも現在は原因が名指しで報告される**ので、まずメッセージを読む
(そうなるまでに 3 回とも「180 秒待って無情報なタイムアウト」を踏んでいる)。
ログは `.ftester/bridge-<port>.log`:

| 症状・ログ | 原因 | 対処 |
|---|---|---|
| `Unlock <name> to Continue`(deviceprep Code=-3) | 端末ロック | 解除+自動ロック「なし」 |
| `Developer App Certificate is not trusted` | 証明書未信頼 | 設定 → 一般 → VPN とデバイス管理 |
| `network connection was lost` が延々続く | WiFi 接続なのに usb を選んだ | USB で繋ぐ(自動で lan に落ちる) |

検出側の設計上の要点(**同じ間違いを繰り返さないため**):
- ロックは「失敗」ではなく「進まない」だけなので throw せず促す。ただし xcodebuild は
  **諦めた時点で初めて**理由を書くことがあるので、待機ループ内だけでなく**締切後にもう一度**
  ログを読む(`BridgeLauncher.waitUntilReady` の physicalDiagnosis)
- 証明書未信頼・Developer Mode 無効は**終端マーカーを待たずに確定**させる(理由を特定できない
  失敗だけマーカー待ち)。詳細は上の「iOS 実機」節
- トランスポートは `transportType` で決める。`FT_IOS_DEVICE_TRANSPORT` の明示指定は尊重する

### 実機とモニター・API

- `api list-devices` / `api monitor` は実機を返す。**状態判定は両者で共有**(`determineStates`)なので、
  片方を直せば両方直る。実機で踏んだ罠:
  - **Android 実機は `avd` が無いので、AVD 前提のままだと永久に offline**(「avd が未設定です」)。
    `serial` を `adb devices` の接続一覧で確認する分岐が要る
  - **iOS 実機の `/status` は device に機種名("iPhone")を返す**。マシンプロファイルのデバイス名
    (例「iPhone wave(実機)」)と一致しないため、名前照合では永久に connected にならない。
    ランナープロセスの `-destination id=<UDID>` で帰属を決める(`BridgeLauncher.portsMatching`)
  - LAN 経由の実機ブリッジは 127.0.0.1 に居ないので、ポートスキャンは `.endpoint` を見る
  - **`ps -p <pid列>` を使ってはいけない**: 範囲外の pid が 1 つ混じるとエラーになり、
    **生きている分も含めて出力が空になる**(pid ファイルは壊れた値を持ち得る)。全プロセスを
    列挙して pid で引く。また monitor は 2 秒間隔でこれを呼ぶので、pid ごとに `ps` を spawn すると
    常駐ブリッジ本数 × 0.5 回/秒のプロセス生成になる(1 回にまとめる)
- `api installed-devices` は `ios.physicalDevices` / `android.physicalDevices` に接続中の実機を返す
  (既存の `devices` / `avds` はシミュレータ・AVD のまま。追加フィールド=後方互換)。
  AVD には `model`(config.ini の `hw.device.name`)と `os`(`image.sysdir.1` の `android-<API>`
  から導出)も付く — エミュレータはプロファイルに機種/OS を持たないため、表示はここが唯一の出所
- `kind`("virtual"/"physical")を `list-devices` と `monitor` の各デバイスに追加した。
  拡張側は欠落を "virtual" に正規化する(旧 CLI 互換)

### 実機と VSCode 拡張

- マシンプロファイル編集フォームは実機で表示が変わる: iOS は機種/OS 行を隠し **udid** を、
  Android は AVD 行の代わりに **serial** を readonly 表示する(いずれも実体を指すので変更不可)。
  実機で識別子を空にした保存は拒否する(`updateDeviceInMachineProfile`)
- デバイスタイルは実機に「実機」バッジを出す。右クリックの起動/停止は**項目を残したまま
  ラベルを「ブリッジを起動/停止」に変える**(実機は端末そのものを起動・停止せず、操作対象は
  ブリッジだけ)。**項目を隠してはいけない**: 隠すとモニターから実機のブリッジを起動できず、
  タイルが「接続中」のまま何もできなくなる(2026-07-25 に実際にそうしてしまった)
- `kind`/`serial` は拡張側の 2 箇所(`config.ts` の `MachineDeviceEntry` と `monitorModel.ts` の
  同名型)に独立定義がある。**両方直すこと**(vscode 非依存を保つための意図的な重複)
- webview→拡張の `machineDeviceUpdate.fields` に `serial` を足した。**拡張と webview のバンドルは
  別々に更新されうる**ので、受信側は欠落を "" に補う(旧 webview と混ぜても壊さない)
- 機種/OS はプロファイルに無ければ `installedDevicesRequest` で取りに行くが、**要求は
  1 デバイス 1 回に絞ること**。この要求は毎回 `ftester api installed-devices` を spawn する
  (devicectl + adb getprop で数秒)ので、値が埋まらないデバイス(未接続の実機・`hw.device.name`
  の無い AVD)では 応答→再描画→再要求 が閉じず CLI を叩き続ける(2026-07-25 のレビューで検出)
- **ネイティブ `title` は表示遅延を指定できない**(ブラウザ/OS 固定で約 1 秒)。省略表示の全文を
  素早く出したい所は自前ツールチップ(`hoverTip.js`、0.2 秒)を使う。要点は
  ① `position: fixed` で body 直下に出す(名前ピルの親 `.tile-header`/`.lane-header` は
  `overflow: hidden` なので子要素方式だと切られる)② 対象に `title=""` を置いて祖先の `title` が
  遅れて二重に出るのを止める

### 実機の画面配信(ftester-devicepoll)

**実機は両OSとも `ftester-devicepoll`**(スクリーンショットのポーリング → MJPEG)に一本化した。
既存の 2 ヘルパーが実機で使えないため:

- `ftester-simstream` は CoreSimulator/SimulatorKit の私有 API で deviceSet から UDID を引くので
  **iOS 実機では原理的に不可**。macOS 27 では iOS 実機を AVCaptureDevice として出す
  **DAL プラグインも消えている**(`/System/Library/CoreMediaIO/Plug-Ins/DAL` が存在せず、
  カメラ権限を付与した Info.plist 埋め込みバイナリでも CoreMediaIO デバイス数 0。2026-07-25 実測)
  ので、QuickTime 方式の代替も無い
- `ftester-androidstream`(adb screenrecord)は Android 実機だと **画面が動いている間しか
  フレームが流れない**(操作中 455KB / 静止画面はキープアライブの 20 バイトのみ)。
  エミュレータは静止時もフレームが出るためこの差は顕在化しない
- あわせて **`screenrecord --time-limit 0`(無制限)は API 34 以上でしか使えない**ことも判明
  (Android 13 実機は即終了して 47 バイト)。androidstream は API レベルで `0` / `180` を選ぶ

devicepoll の要点:
- 宛先は iOS が `--host/--port`(ブリッジの `/screenshot`)、Android が `--serial/--adb`
  (`exec-out screencap -p`)。拡張は `api monitor` の `kind`/`host`/`port`/`serial` で振り分ける
- 出力は **v1(MJPEG)固定**。`--max-width` は既存ヘルパーと同じく**幅**の上限
  (ImageIO の `kCGImageSourceThumbnailMaxPixelSize` は**長辺**基準なので長辺換算して渡すこと。
  そのまま渡すと 1080x2340 で 360 指定 → 166x360 になる)
- 実測(2026-07-25、fps=2 / max-width 360): Android 実機 360x780 が 7 秒で 13 枚、
  iOS 実機 360x781 が 8 秒で 16 枚。**静止画面でも出る**のがこの方式の要点

## 常駐ブリッジのセッション(iOS xcuitest を CLI で直接叩くとき)

`bridge up` で立てた常駐ランナーへ curl 等で直接 `/snapshot`・`/tap` すると、最初の1回が
`409`(セッション無し)で返ることがある。ランナーはアプリ参照(`sessionBundleID`)を `/session`
で初めて確立するため。**先に `POST /session` を投げる**こと(Runner/FTesterRunnerUITests/BridgeRouter.swift)。

- `simctl launch` で既に起動済みのアプリへ後付けで繋ぐ場合は `{"bundleID":"...","attachOnly":true}`。
  attachOnly は activate/launch せず前面到達だけ確認する(前面に無ければ即エラー)。通常 run は
  driver が自動で `/session` を張るのでこの手順は不要=CLI 直叩き時だけの話。
- **`/status` の `sessionBundleID` は次の `/session` まで残る in-memory 値**。対象アプリを
  アンインストールしても消えないため、削除済みアプリの死んだ参照が見えることがある(無害。
  次の `/session` で上書きされる)。`/status` の session 欄=「今アタッチ可能」の保証ではない。

## 録画(record:true)の検証

録画パイプライン(Recorder/Finalizer/Coordinator/`RecordingWallClock`)を触ったら、
ユニットテストでは AVFoundation・デバイス境界を捕まえられないため、record:true の実 run で確認する:

- **録画パイプラインの退行は `Scripts/e2e.sh --record` で検知できる**(各プロファイルの一時コピーに
  record:true を付けて実行し、`Scripts/check-recordings.py` が schemaVersion・クリップ数・
  クリップ長・mp4 存在を機械チェックする。元のプロファイルは書き換えない)
- **クリップ数 = シナリオ数**(シナリオが来なかったアイドルワーカーの録画は破棄される)、
  **クリップ長 ≒ シナリオ durationMs**(ミリ秒オーダーで一致するのが正常)、index.json(schemaVersion 2)の整合
- **VFR の罠**: simctl/screenrecord は「画面が変化した時だけ」フレームを吐く。切り出しは
  「区間開始前の最後のフレームを retime して先頭に置く」+「endSession で区間終了まで保持」が無いと
  先頭/末尾が欠ける(実測: 11.1s ソースが endSession 無しで 8.7s に縮んだ)
- **codec は H.264 固定**(再生側 = 拡張 webview の Chromium は HEVC 不可)。simctl に bitrate ノブは
  無く、圧縮はファイナライズの再エンコードで行う(bitrate は run profile の recordBitrateKbps、
  解像度は recordFullResolution。`VideoRecordingFinalizer` の shrinkThreshold を誤ると Android
  ソースの二重縮小になる実害があった)
- **サイズの目安**: 1テスト 0.1〜3MB(iOS 約50〜150KB/s、Android は静止的で約8〜30KB/s)。
  大きく外れたら解像度判定(shrinkThreshold)かビットレートを疑う
- Android screenrecord は180秒上限のセグメントループ。停止は**デバイス側プロセスへ kill -2**
  (ホストの adb クライアント kill ではファイルが壊れる)。iOS simctl は SIGINT 停止・SIGKILL 禁止
