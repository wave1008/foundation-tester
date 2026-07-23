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

## `Scripts/e2e.sh`(ftester 自身の E2E)

- SUT(`E2EApp/` 他)の鮮度を見て必要なら再ビルドし、各プロファイルを順に回す。オプション:
  `--rebuild` / `--ios` / `--android` / `--cmp` / `--ios-native` / `--android-native` / `--flutter`
- **両OSを1プロファイルにまとめない**: platform 未指定シナリオは既定 platform のキューにしか入らず
  他方のワーカーが空回りする(design.md §11.4)。SUT はネットワーク依存ゼロなのでバックエンド死活の
  切り分けは不要
- **フレームワーク差の退行は SUT を跨がないと出ない**。ブリッジのスナップショット/型写像
  (`SnapshotBuilder`・`BridgeRouter`)を触ったら SUT を絞らず全部回す。片方だけ通って
  もう片方が黙って空振りする類の退行が実際に出る(Compose の Button は `Cell`、View/XML は `Button` 等)

## 常駐プロセスの掃除

- 再ビルド後の検証前に旧バイナリの常駐プロセス(monitor/host-metrics)を kill する
  (生き残って検証を汚す・旧ブリッジを自動再起動する。docs/performance-tuning.md §7)

## macOS / Xcode ベータの整合

- macOS ベータを更新したら Xcode も同じベータへ揃えてフルリビルド。FoundationModels の ABI 不整合で
  全バイナリが dyld クラッシュする(swift build は SDKROOT/--sdk を無視するため Xcode 側を揃えるしかない)
- Xcode(beta)単体の更新でも同様: iOS ランタイム導入(`xcodebuild -downloadPlatform iOS`)+
  ランナー再ビルドで整合させる。不整合はアプリが数操作で「Application is not running」クラッシュする
  (`ftester doctor` が DTXcodeBuild 不一致を警告。2026-07-21 実害)

## テストが「Application is not running」で全滅したら

ランナーや自分の変更を疑う前に **SUT のバックエンド死活を確認**する
(sut-ec-mobile は localhost:8090 の dev サーバ。停止中はアプリが非同期例外でクラッシュする)。
apps プロファイルの healthCheckURL が実行開始時に警告を出す。

## 録画(record:true)の検証

録画パイプライン(Recorder/Finalizer/Coordinator/`RecordingWallClock`)を触ったら、
ユニットテストでは AVFoundation・デバイス境界を捕まえられないため、record:true の実 run で確認する:

- **クリップ数 = シナリオ数**(シナリオが来なかったアイドルワーカーの録画は破棄される)、
  **クリップ長 ≒ シナリオ durationMs**(ミリ秒オーダーで一致するのが正常)、index.json(schemaVersion 2)の整合
- **VFR の罠**: simctl/screenrecord は「画面が変化した時だけ」フレームを吐く。切り出しは
  「区間開始前の最後のフレームを retime して先頭に置く」+「endSession で区間終了まで保持」が無いと
  先頭/末尾が欠ける(実測: 11.1s ソースが endSession 無しで 8.7s に縮んだ)
- **codec は H.264 固定**(再生側 = 拡張 webview の Chromium は HEVC 不可)。simctl に bitrate ノブは
  無く、圧縮はファイナライズの再エンコードで行う(ノブは `VideoRecordingFinalizer` の
  targetBitRate / shrinkThreshold。閾値を誤ると Android ソースの二重縮小になる実害があった)
- **サイズの目安**: 1テスト 0.1〜3MB(iOS 約50〜150KB/s、Android は静止的で約8〜30KB/s)。
  大きく外れたら解像度判定(shrinkThreshold)かビットレートを疑う
- Android screenrecord は180秒上限のセグメントループ。停止は**デバイス側プロセスへ kill -2**
  (ホストの adb クライアント kill ではファイルが壊れる)。iOS simctl は SIGINT 停止・SIGKILL 禁止
