---
paths:
  - "Sources/FTCore/AccessibilityClassHint*.swift"
  - "Sources/FTCore/AccessibilityClassHint.swift"
  - "Sources/FTCore/AndroidPackageInspector.swift"
  - "Sources/FTCore/AppFrameworkLedger.swift"
  - "Sources/FTCore/AppUIFramework*.swift"
  - "Sources/FTCore/AppUIFrameworkQuery.swift"
  - "Sources/FTCore/BridgeDTO.swift"
  - "Sources/FTCore/StepExecutor*.swift"
  - "Sources/FTCore/UIFrameworkMarkers*.swift"
  - "Sources/FTCore/UIFrameworkMarkers.swift"
  - "Tests/FTBridgeClientTests/AppUIFrameworkQueryWiringTests.swift"
  - "Tests/FTCoreTests/AccessibilityClassHintTests.swift"
  - "Tests/FTCoreTests/AndroidPackageInspectorTests.swift"
  - "Tests/FTCoreTests/AppUIFrameworkQueryTests.swift"
  - "Tests/FTCoreTests/ElementInfoCodingTests.swift"
---

# UI フレームワーク判定・容器推定・スクロールの端 の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **空打ち(スクロール探索の終端)を撃つかは、アプリの UI フレームワーク(`AppUIFrameworkQuery`)→
  掴んだ要素のクラス名の順で決める**(後者は `ElementInfo.axClass` =
  XCUITest ランナーが XCTest の**非公開**属性 5004 から載せる。Compose / Flutter の要素は
  `UIAccessibilityElement`、RN は `UIView`、SwiftUI は `NSObject`。`AccessibilityClassHint`)。
  どれも無ければ撃たない(打って外れると行が押される = 取り消せない側)。**木の形・型の名前から
  フレームワークを推定しない**(実アプリの 10/22 画面が Compose と同形・RN は Flutter と同形。
  docs/verification.md)。③は非公開属性なので `Tests/Fixtures/AXClass/` の等号テストで Xcode の版の
  変化を検出し、取れなければ nil = 撃たない側へ縮退する
- **アプリの UI フレームワークは `FTCore.AppUIFrameworkQuery` だけで決める**(語彙 `AppUIFramework` =
  iOS: compose / flutter / reactNative / swiftUI / uikit、Android: compose / flutter / reactNative / androidView)。
  順は**静的(.app / .ipa / .apk の目印 → iOS シミュレータに入っているバンドル → 台帳 `AppFrameworkLedger`)→
  動的(in-app ブリッジの自己申告)→ `.unknown`**。**iOS の目印の規則は `UIFrameworkMarkers` の1ファイルを
  ホストと in-app ブリッジが共有する**(build.sh の SWIFT_SOURCES と BridgeSourceSet に入っている =
  触ったらブリッジの版を上げる。別々に持っていた頃はホストだけ SkikoUIView を見るようになり答えが割れた)。
  Android は `AndroidPackageInspector`(ブリッジは申告しない)。守る規律5つ:
  **①不明を既定値で埋めない**(呼び手が安全側を選ぶ)/ **②パッケージは宣言した bundle ID(パッケージ名)が
  対象と一致するときだけ使う**(プロファイルのアプリとシナリオの対象アプリは別になりうる)/
  **③自己申告は `bridgeReport(_:about:)` を通し、対象アプリ自身の申告のときだけ使う**・
  台帳にもプロセス内の控えにも入れない(`AppUIFrameworkQueryWiringTests` が `StatusResponse.uiFramework` の
  直読みをソース走査で落とす)/ **④目印・順序を変えたら規則の版(`rulesVersion`)を上げる**(台帳は版の違う
  控えを使わない)/ **⑤台帳と控えは OS で分ける**(CMP は iOS の bundle ID と Android のパッケージ名が同じ)。
  **呼び手は「自前描画か」(`isSelfRendered`)で分岐する** —— 個別の値(`== .uikit` 等)で分けると語彙を
  足した日に黙って外れる(RN / SwiftUI を uikit から分けたとき、in-app の木の正規化はそれらにも掛け続ける必要があった)。
  Android の compose は「Compose を含む」であって全画面が Compose とは限らない(View/XML に混ぜた E2EAppAndroid もこちら)
- **容器推定(`StepExecutor.clippingContainer`)は scrollable 申告の祖先を優先する**。
  この関数はタップの座標補正・ghost 判定・MCP にも効くので、触ったら 5 SUT のフル E2E
  **+ `--ios-xcuitest`**。**フルスイートは iOS を in-app で回すので、これだけでは守れない** ——
  現にこの規則の導入(`8a416bc0`)が xcuitest 限定の退行を入れ、フル E2E 緑のまま通った
  (**5日後の `931897d6` で修正済み** —— 申告の祖先へ倒すのは「深さ由来の候補が要素を収められない」
  ときだけ。経緯と壊れ方は maintainer-notes §4.5.1)
  **座標ドラッグは `StepExecutor.dragWithFallback` だけから撃つ**(in-app は drag が 501。
  `driver.drag` を直に呼ぶと hybrid で黙って不発になる)
- **端送りは「最後に動いてから `edgeClaimGraceAfterMove`(1.0 秒)」経つまで端と確定しない**(窓の外に描き足す
  RN の FlatList で途中止まりした)。**ドライバの `atEdge: false`(= 確かに動かした)は事実を知っている経路だけが返す**
  (in-app の contentOffset・Android の CDP)。**AX の scroll の受理は含めない** —— Compose は端でも受理し、含めた版は
  端送りが毎回 maxSwipes まで回った(緑のまま)→ maintainer-notes §36
