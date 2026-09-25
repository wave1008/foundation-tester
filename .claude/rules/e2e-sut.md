---
paths:
  - "E2EApp*/**"
  - "E2EAppCMP/docs/ui-contract.md"
  - "E2EAppCMP/scripts/build-ios-device.sh"
  - "E2EAppIOS/Sources/UI/OverlayWindow.swift"
  - "E2EAppIOS/scripts/build-ios-device.sh"
  - "Scripts/e2e.sh"
  - "TestProjects/E2E-*/**"
  - "Tests/FleetestTests/DeepLinkSchemeSyncTests.swift"
---

# fleetest 自身の E2E(SUT) の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **iOS だけが持つ witness**: `E2EAppIOS/Sources/UI/OverlayWindow.swift` = **キーウィンドウに
  しない別 UIWindow のモーダル**(全画面 / 上部バナーの2形)と、診断画面の `#btn_request_photos`
  = **OS(SpringBoard)の権限アラートがアプリを覆う形**(別プロセスなので in-app の木に載らない。
  緑の回帰は `scenarios/16_システムアラート.swift`・**陽性対照は `_disabled/94_システムアラート.swift`**)。
  覆い・別ウィンドウに関わる変更は `TestProjects/E2E-iOS/scenarios/15_別ウィンドウのモーダル.swift`
  の4本で対照を取る(docs/verification.md)。**4本目は条件判定**(`ifCanSelect`)——
  **perform を通らないので操作・検証を直しても守られない**
- **要素の testTag/`#id`/ラベルの唯一の正は `E2EAppCMP/docs/ui-contract.md`**(全 SUT とシナリオが
  これを参照。片方だけ変えない。`uiContractSync.test.mjs` が「SUT 側の `#id` が母体に実在するか」を
  検出)。**型語彙・OS/フレームワーク固有の罠だけ**は各 SUT の `<SUT>/docs/ui-contract.md` に置く
  (同じ `#id` でも型は SUT ごとに違う。例: ボタンは CMP/Android で `Cell`、View/XML なら `Button`)
- **シナリオは画面の解像度に依存しない形で書く**(ユーザー方針 2026-09-05)。**背の高い
  シミュレータで緑になっても、背の低い実機では落ちる** —— 逆向き(小さい画面で通したら
  大きい画面が落ちる)も同じだけ起きるので、**どちらか片方だけで判定しない**。
  判定は「その手順が窓の高さに依存していないか」の1点で、具体的には5つ:
  **①折り返しの下にある要素は `tap(..., scroll:)` / `scrollTo` で到達させる**
  (見えている前提で `tap` を書かない)/ **②送りの始点・終点は「その画面で確実に窓の中に
  居る要素」だけを使う** —— 見切れた要素はクランプされた座標を返すので、そこから払うと
  容器に当たらず1pt も動かない / **③1回の送りで届く距離を前提にしない**。慣性の量は
  窓の高さで変わる(実測: 3行×2回 < 4行×1回)/ **④`notExist` を「画面外へ出た」の観測に
  使わない** —— リストの再利用窓に残るかは窓の高さ次第(実測: 短い画面で4行・高い画面で5〜6行)。
  距離で担保するなら**両方の画面で実測してから**書く / **⑤対にして検証する2要素**
  (上端の結果表示と下端のボタン等)は、**最小サポート画面で同時にツリーへ載る**ことを
  SUT 側で保証する(`E2EAppCMP/docs/ui-contract.md` 全体規約)。載らないなら
  シナリオ側で回避せず SUT の配置を直す —— 送ってから読み返す形にすると `:above()` の
  相手がクランプされた残骸になり、検証そのものが成立しない。
  **確かめ方**: 変更したシナリオは**背の低い実機と背の高いシミュレータの両方**で回す
  (片方だけの緑は根拠にならない)。**iOS の実機は SUT の成果物が別**(`E2EAppIOS/dist/ios-device` /
  `E2EAppCMP/dist/ios-device`)—— `e2e.sh` は実機用を一度作ってある機械ならソースの鮮度で作り直すが、
  `e2e.sh` を通さずに SUT を変えたら各 SUT の `scripts/build-ios-device.sh` を先に打つ(古いアプリのまま足した `#id` が not found で赤になる)。
  **実機の有無は物理端末だけに絞った一覧を全行見て決める**(`xcrun devicectl list devices | grep -i physical` /
  `adb devices -l`。`head` で切った一覧から「つながっていない」と言わない)
- **5 SUT のシナリオはほぼ同内容だが共通化しない**(ユーザー決定・可読性優先)。DSL 変更のたび
  5箇所を編集することになるが、共通化すると SUT 固有の差(型語彙・フレームワーク固有の罠)が
  表現しにくくなる。**共通化を再提案しない**
- **ディープリンクの URL スキームは SUT ごとに固有**(`fte2ecmp`/`fte2eios`/`fte2eandroid`/
  `fte2eflutter`/`fte2ern`。契約は `E2EAppCMP/docs/ui-contract.md` §ディープリンク)。
  iOS は同一スキームを複数アプリが登録していても解決先を1つしか選ばず、E2E のシミュレータには
  iOS の SUT が4つ同居するため共有スキームでは配送先が端末ごとに揺れる。
  `Tests/FleetestTests/DeepLinkSchemeSyncTests.swift` が契約表との一致と SUT 間の重複を検出する
