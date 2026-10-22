// ブリッジ実装が変わったことを検出し、版数の引き上げを促す。検出は2段:
//   ルート表  … エンドポイントの増減(どのルートが変わったかまで言える)
//   ソース指紋 … 実装ファイルの内容変化(ルートが同じでハンドラだけ変えた場合を捕まえる)
//
// 事故の形(実害2回): 実装を変えたのに版数を上げず、稼働中の旧ブリッジが「版一致」として
// 再利用され、変更が反映されないまま緑になる。
// 版数は片側だけ上げても検出できるが(iOS = BridgeAPI.bridgeProtocolVersion は
// ホスト・in-app・XCUITest ランナーの共有定数 / Android = AndroidBridgeVersionSyncTests)、
// 「そもそも上げ忘れた」は人間の規律だけが頼りだった。
//
// **このテストの限界**: 版数を上げること自体は強制できない(ここの期待値だけ更新して版数を
// 据え置くことは手続き上できてしまう)。リポジトリ内の期待値は書き換え可能なので原理的に
// これ以上は詰められない。目的は「無音で緑になる」状態を「版数の判断を意識的に迫られる」
// 状態へ変えることまで。
//
// 指紋は生バイトで取るため、**コメント編集でも落ちる**(意図的な設計)。文字列リテラル中の
// `//` を素朴に削るコメント除去は変更を見逃す側に倒れるので、誤検出の側を選んでいる。
// 落ちたら「版を上げるべき変更か」を判断し、上げないなら期待値だけ貼り替える。
// 入力ファイルの一覧は Sources/FTCore/BridgeSourceSet.swift(定義はそこ1箇所)。

import XCTest
import FTCore

final class BridgeContractTests: XCTestCase {

    // 期待するルート表。**変更したら対応する版数を必ず上げること**:
    // (この3つは internal = docs/design.md のエンドポイント表と突き合わせる
    //  BridgeDocRouteSyncTests から参照する。**唯一の正はここ**で、あちらは写し)
    //   in-app / XCUITest ランナー → Sources/FTCore/BridgeDTO.swift の bridgeProtocolVersion
    //   Android                    → AndroidRunner/build.sh の VERSION_CODE と
    //                                Sources/FTAndroid/AndroidBridge.swift の expectedBridgeVersionCode
    // 3実装でルートが異なるのは仕様。共通コアは13本で、差分は:
    //   in-app     … 同一プロセスしか見えないので /drag・/appswitcher・/home を持たない
    //   /locale    … Android だけ
    //   /settle    … Android だけ(ホストが adb で撃った操作〈launch・戻るキー〉の整定を
    //                 ブリッジに待たせる口。ブリッジ経由の操作は応答内で待つので不要)
    //   /hidekeyboard … iOS の2実装だけ(中身は 501。Android はホスト側の戻るキーで実現するため
    //                   ルートを持たない)
    //   /appstate  … iOS の2実装だけ
    //   /pinch・/doubletap … 3実装とも持つ(in-app は 2026-08-04 に追加。合成タッチの間隔と
    //                 指の距離を自分で決められるぶん XCTest より正確な場面がある)
    //   /rotate    … iOS の2実装だけ(62)。Android は host-side adb(AndroidDriver)で行うため持たない
    //   /gesture   … XCUITest ランナーと Android だけ(iOS 126 / Android 72)。in-app は持たず、inapp モードは
    //                 既定の 501 で XCUITest へ回す(指ごとの時刻つき経路を1回で再生する)
    //   /hold      … XCUITest ランナーと Android だけ。in-app は持たず、inapp モードは XCUITest へ回す
    //                 (指を置いたら応答を返す = 置いている間に木を読める)
    static let inAppRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /appstate", "POST /clear", "POST /doubletap", "POST /drag", "POST /hidekeyboard", "POST /tapprobe", "POST /pinch",
        "POST /press", "POST /pressEnter", "POST /rotate", "POST /session", "POST /swipe",
        "POST /tap", "POST /terminate", "POST /type",
    ]

    static let xcuiTestRoutes: Set<String> = [
        // GET /hittable は「その ref を撃つと本当に当たるか」を XCUITest 自身に聞く照会
        // (2026-08-14 追加。BridgeRouter.handleHittable の doc に費用の実測がある)
        "GET /hittable",
        // GET /systemalert は「SpringBoard のアラートが載っているか」だけを聞く軽い口
        // (2026-08-21 追加。木を全部撮る /snapshot は約 185ms・こちらはアラート無しで約 73ms)
        "GET /systemalert",
        "GET /systemui/covering",
        // /systemui/* は SpringBoard を**セッションを触らずに**読む/叩く口
        // (2026-08-25 追加・版 79)。ref は専用の名前空間 = ランナーの systemRefFrames。
        // xcuitest モードは主ドライバと同じブリッジを共有するので、
        // 旧経路(POST /session springboard)だとアプリのセッションが巻き添えになる。
        // drag / swipe は座標を **SpringBoard 基準**で撃つ(版 80)—— tapAppIcon は
        // home() の直後に呼ぶので、セッションのアプリを原点にする /drag では
        // 背面アプリの座標解決でランナーごと落ちる(BridgeRouter.systemUIAnchor)
        "GET /systemui/snapshot", "POST /systemui/tap",
        "POST /systemui/drag", "POST /systemui/swipe",
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /appstate", "POST /appswitcher", "POST /clear", "POST /doubletap", "POST /drag",
        "POST /gesture", "POST /hidekeyboard", "POST /hold", "POST /hinge", "POST /home", "POST /pinch", "POST /press",
        "POST /pressEnter", "POST /rotate", "POST /session", "POST /swipe", "POST /tap", "POST /terminate",
        "POST /type",
        // waitForSettle(v174)。画面全体を撮るのでセッションを要さない。in-app は持たない(アプリ自身の描画しか撮れない)
        "POST /waitForSettle",
        // 応答時間計測(v192)。契約は FTCore/ResponseMeasurementWire.swift(Android と共有)
        "POST /responsePrepare", "POST /responseCollect", "POST /responseObservation", "POST /responseObservationStop",
    ]

    static let androidRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /clear", "POST /doubletap", "POST /gesture", "POST /hold", "POST /locale", "POST /pinch", "POST /press",
        "POST /pressEnter", "POST /scrollAction", "POST /session", "POST /settle", "POST /swipe",
        "POST /tap", "POST /terminate", "POST /type",
        "POST /waitForSettle",
        // 応答時間計測(Android v102〜)。in-app は持たない
        "POST /responsePrepare", "POST /responseCollect", "POST /responseObservation", "POST /responseObservationStop",
    ]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    func testInAppBridgeRoutesUnchanged() throws {
        try assertRoutes(
            file: "InAppBridge/Sources/InAppBridge.swift",
            pattern: swiftRoutePattern,
            expected: Self.inAppRoutes,
            versionHint: "Sources/FTCore/BridgeDTO.swift の bridgeProtocolVersion"
                + "(現在 \(BridgeAPI.bridgeProtocolVersion))")
    }

    func testXCUITestRunnerRoutesUnchanged() throws {
        try assertRoutes(
            file: "Runner/FleetestRunnerUITests/BridgeRouter.swift",
            pattern: swiftRoutePattern,
            expected: Self.xcuiTestRoutes,
            versionHint: "Sources/FTCore/BridgeDTO.swift の bridgeProtocolVersion"
                + "(現在 \(BridgeAPI.bridgeProtocolVersion))")
    }

    func testAndroidBridgeRoutesUnchanged() throws {
        try assertRoutes(
            file: "AndroidRunner/src/com/example/ftbridge/BridgeRouter.java",
            pattern: javaRoutePattern,
            expected: Self.androidRoutes,
            versionHint: "AndroidRunner/build.sh の VERSION_CODE と "
                + "Sources/FTAndroid/AndroidBridge.swift の expectedBridgeVersionCode")
    }

    // MARK: - ソース指紋

    /// 相対パス → 内容の SHA256。**実装を変えたら対応する版数を上げてから**貼り替えること。
    /// 貼り付け用のリテラルは失敗メッセージがそのまま出力する(手でハッシュを写さない)。
    private static let expectedFingerprints: [BridgeSourceSet: [String: String]] = [
        .inApp: [
            "InAppBridge/Sources/Bridging.h": "08799e6d190f958eed7c6bb4406f1cbbfea1bed1d252ce4572636273c65a5aad",
            "InAppBridge/Sources/DisplayHeartbeat.swift": "7d907d41d42721c6e7a769aaa610fa74ee0103f95111281cb2231206c748bbc5",
            "InAppBridge/Sources/InAppBridge.swift": "595b2632f95eec354a877200579cf7fa2f2c9a845c209527154edda12d210baa",
            "InAppBridge/Sources/InAppHTTPServer.swift": "2c0dd9eaa35bb794004378e8c9fb8655fc66b42630bd582dd75e73754d361f9c",
            "InAppBridge/Sources/InAppInput.h": "334537da65d98ae36f9fb11fa0b29d5f0b2586e2e4298415d4637bcc36c113cd",
            "InAppBridge/Sources/InAppInput.m": "43e1d8de8a3b175dd5dd8335a65b0dd610ffe1861cdefc4ac8fd1f57839f3b97",
            "InAppBridge/Sources/InAppSettle.swift": "555e1061bab1ee48a532a7e9a38130c5fa0601f3854358187826cd5a5befad57",
            "InAppBridge/Sources/InAppSnapshot.swift": "40a6306db76c1eccd0bdce15a5c6863a554fc8c051c2a67b41507cffa5720515",
            "InAppBridge/Sources/InAppTapProbe.swift": "f612eb38316c5440aeca26df02b56b077f15bcc54702268bd0a8b54a0658e06b",
            "InAppBridge/Sources/InAppWebViewDOM.swift": "d2b3341a539263ac428f67e93deabf1eccd40236a7aaddc3af6372d815b3a17f",
            "InAppBridge/Sources/boot.m": "b23fc93fbc99ce2579c9fd8ae75a6f9bbfd0ec6122bec60eb6cd00775dd635ef",
            "InAppBridge/build.sh": "3cf8cb7316059b4f5d4e2a33d915c6b4cd5318dad7a68718f18a010b630c8713",
            "Sources/FTCore/AXFrameRescale.swift": "eef63f86079f246da9f30f7543f4efb7e912eb70f6a01c721dde6789a1ebe7e7",
            "Sources/FTCore/BridgeDTO.swift": "145a74d3f734f665bcd47a292c5b290b557f7a1a0cb01aebba1159c93aa600e6",
            "Sources/FTCore/TypeReadback.swift": "540049e120e476538772df5e4611e3a78ec5717cd42fb7a683fdb606fad88027",
            "Sources/FTCore/UIFrameworkMarkers.swift": "1601c9feecaa817d73deea4445523522341ae1b777086b55c33c6e0a74fef6b8",
            "Sources/FTCore/WebViewDOMSnapshot.swift": "aa4dea12295f5da76b1f0b97cd59a2c00e4ad2aa8ee838ccbf5d4abc2eba22ca",
        ],
        .xcuitest: [
            "Runner/FleetestRunnerUITests/BridgeHTTPServer.swift": "ef8c6573ab25f9cbdfed21e483ce74f1eb5d1a4345bc57a2d5b9ed2eb86b860e",
            "Runner/FleetestRunnerUITests/BridgeRouter+Snapshot.swift": "55f5bdc9607198d489299ee946d4c2521802836219e3f9d2712bc06adace4334",
            "Runner/FleetestRunnerUITests/BridgeRouter+TextInput.swift": "e493132a3e07695e48af3ed3c135432863792e8b40dc0a87327c4c673c2cd993",
            "Runner/FleetestRunnerUITests/BridgeRouter.swift": "5f7e6fe368b07bd143c25442fb7a62deb439d0b3b4590391d29172b7f3854228",
            "Runner/FleetestRunnerUITests/BridgingHeader.h": "f7ff424d9283644d0e7a0c6e202911ecbf2d9c12d469eea330d91471c4788272",
            "Runner/FleetestRunnerUITests/CoordinatePinch.swift": "0bd945c6548c9eeb2c9a9dacfb9adfbd2fd2479bf606b3fdb627ac5df1506f70",
            "Runner/FleetestRunnerUITests/DisplayHeartbeat.swift": "c62c30a45e842d5ec7aff60210284d679b76f6e44358a3f4c97429fe918e5ffa",
            "Runner/FleetestRunnerUITests/DisplayRouting.swift": "4c2a45c043a5915ffacfb174dc7af5c6561c0fa3223d08779a4956a825e1891c",
            "Runner/FleetestRunnerUITests/FleetestBridgeTests.swift": "f067851e91fad9b386d9152501efa5ceed836d5afd40687ab9ce5e13c806a719",
            "Runner/FleetestRunnerUITests/InterruptionGuard.swift": "1cd4c8a6b2f57e85d7e9c2d6541bef90208228ca3d1278879efa69932de409e3",
            "Runner/FleetestRunnerUITests/ObjCExceptionCatcher.h": "5a98cdbeefb031137a985b2f4430a5e12fec447a492599f8f4da1bd2c7101edc",
            "Runner/FleetestRunnerUITests/ObjCExceptionCatcher.m": "8b41a8a81bc8199bca13a364717614684f8003999c7675d9a63242c8e74c26be",
            "Runner/FleetestRunnerUITests/QuiescenceWait.swift": "653eba2c8bd3eb080d9512418da707e14a0c5ad7b6d0b297a788f3c3e53d84c8",
            "Runner/FleetestRunnerUITests/ResponseMeasurement.swift": "6254e04c6f0a85d4504e45657f847f6d1a761fe2f635819b482457c34dd095b1",
            "Runner/FleetestRunnerUITests/VirtualHID.swift": "8ee358d73f27c9aabefbd6f98e41091dfde837ee8f15e5066997df1d97df802e",
            "Sources/FTCore/AXFrameRescale.swift": "eef63f86079f246da9f30f7543f4efb7e912eb70f6a01c721dde6789a1ebe7e7",
            "Sources/FTCore/BridgeDTO.swift": "145a74d3f734f665bcd47a292c5b290b557f7a1a0cb01aebba1159c93aa600e6",
            "Sources/FTCore/ResponseMeasurementWire.swift": "19f9ba212d1ce05ad3431dd350895329f0fc62a8bdbf6210c362583d22175dcd",
            "Sources/FTCore/SnapshotDedupe.swift": "f987a913f2010e8cd81e381c595c15242f58225c71a11a9be206590baccf8c9b",
            "Sources/FTCore/TypeReadback.swift": "540049e120e476538772df5e4611e3a78ec5717cd42fb7a683fdb606fad88027",
        ],
        .android: [
            "AndroidRunner/AndroidManifest.xml": "cf43535a8f8e3361bafd6761b99cbf9e4347afd9ac76d42ed82da0e032908b17",
            "AndroidRunner/build.sh": "b136074f6bd0753af9c4186ec066407492125748aef24dd13e6556cfd3c3524a",
            "AndroidRunner/src/com/example/ftbridge/BridgeHttpServer.java": "863ec6982e6dd41c6bda8f8f6fe998c17c95b0f250c7f57345e6c5cb617f26ac",
            "AndroidRunner/src/com/example/ftbridge/BridgeInstrumentation.java": "78fe5cc272782a091bbbc512d1693bed0a192cf363548699a586cb0f3d614824",
            "AndroidRunner/src/com/example/ftbridge/BridgeRouter.java": "4fbcac20298f44d3244e26743bf55e3ca0acff2e9da846c4e6cec0a677573bd3",
            "AndroidRunner/src/com/example/ftbridge/DisplayHeartbeat.java": "b00ff62b9a909e7e46df1a7a1aa1f39ba0a5711834092148adfee9f6bd6c7d9a",
            "AndroidRunner/src/com/example/ftbridge/FirstFrameState.java": "378cd2f84f8fa12de57da78bc19354933bf10ef32691d0225c6950b52109770a",
            "AndroidRunner/src/com/example/ftbridge/ImeOnboarding.java": "fe2d90d892046f64e4893c008148d47886e36bceb244dd9e68e560b368f0193b",
            "AndroidRunner/src/com/example/ftbridge/KeyboardPrimerActivity.java": "f5a4751486cd8349a8f10b65332d6a3e1d77c3d82e0528e8518ec646aad152d9",
            "AndroidRunner/src/com/example/ftbridge/InputInjector.java": "6b04fbba91a732c33c06a8f4bba2d55156300ab40678494b4588216a29fb1497",
            "AndroidRunner/src/com/example/ftbridge/QuietWaiter.java": "b939eb89d48c6a3591a78b8457b31f851cd95c0f188fffdaa1668f557153347d",
            "AndroidRunner/src/com/example/ftbridge/ResponseObserver.java": "f2f52a49eb907786fc7a60b89a1c89b87d417fd0e07de0c9b01054a820574f09",
            "AndroidRunner/src/com/example/ftbridge/ResponseProbe.java": "1c49c669fdc21ca27da02833f82e2f65f56dfd209b3264a8dbb2ab9f756801c1",
            "AndroidRunner/src/com/example/ftbridge/SnapshotBuilder.java": "355b052546bff1644a0e223fae31bf7d82435a140090276c2195c0e703a4caa3",
        ],
    ]

    func testInAppBridgeSourcesUnchanged() throws {
        try assertFingerprints(.inApp)
    }

    func testXCUITestRunnerSourcesUnchanged() throws {
        try assertFingerprints(.xcuitest)
    }

    func testAndroidBridgeSourcesUnchanged() throws {
        try assertFingerprints(.android)
    }

    /// 期待値の宣言漏れ(集合を足したのに指紋を書いていない)を検出する
    func testEveryBridgeHasExpectedFingerprints() {
        for set in BridgeSourceSet.allCases {
            XCTAssertNotNil(Self.expectedFingerprints[set],
                            "\(set.rawValue) の期待指紋が未宣言です")
        }
    }

    /// **ファイルが読めない場合は skip せず失敗させる**: 消したから緑、を作らないため
    private func assertFingerprints(_ set: BridgeSourceSet) throws {
        let actual = try set.fingerprints(repoRoot: repoRoot)
        let expected = try XCTUnwrap(Self.expectedFingerprints[set])
        guard actual != expected else { return }

        let added = actual.keys.filter { expected[$0] == nil }.sorted()
        let removed = expected.keys.filter { actual[$0] == nil }.sorted()
        let modified = actual.keys
            .filter { expected[$0] != nil && expected[$0] != actual[$0] }.sorted()

        var message = "\(set.rawValue) ブリッジの実装が変わりました"
        if !modified.isEmpty { message += "(変更: \(modified.joined(separator: ", ")))" }
        if !added.isEmpty { message += "(追加: \(added.joined(separator: ", ")))" }
        if !removed.isEmpty { message += "(削除: \(removed.joined(separator: ", ")))" }
        message += "。**\(set.versionConstantHint) を上げてから**、下記を期待値へ貼り替えること"
        message += "(版を上げないと稼働中の旧ブリッジが再利用され、変更が反映されないまま緑になる。"
        message += "コメントだけの変更など版を上げるに値しないなら、貼り替えだけでよい)"
        if set != .android {
            message += "。現在の bridgeProtocolVersion: \(BridgeAPI.bridgeProtocolVersion)"
        }
        message += "\n" + pasteableLiteral(actual)
        XCTFail(message)
    }

    private func pasteableLiteral(_ fingerprints: [String: String]) -> String {
        fingerprints.keys.sorted()
            .map { "            \"\($0)\": \"\(fingerprints[$0]!)\"," }
            .joined(separator: "\n")
    }

    // MARK: - 抽出

    /// Swift 側: `case ("GET", "/status")` → `GET /status`
    private let swiftRoutePattern = #"case \("(GET|POST)", "(/[A-Za-z][A-Za-z0-9/_-]*)"\)"#
    /// Java 側: `case "GET /status":` → `GET /status`
    private let javaRoutePattern = #"case "(GET|POST) (/[A-Za-z][A-Za-z0-9/_-]*)":"#

    private func assertRoutes(file: String, pattern: String,
                              expected: Set<String>, versionHint: String) throws {
        let url = repoRoot.appendingPathComponent(file)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("\(file) を読めません")
        }
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var found: Set<String> = []
        for match in regex.matches(in: source, range: range) {
            guard let method = Range(match.range(at: 1), in: source),
                  let path = Range(match.range(at: 2), in: source) else { continue }
            found.insert("\(source[method]) \(source[path])")
        }

        XCTAssertFalse(found.isEmpty,
                       "\(file) からルートを1件も抽出できません"
                       + "(ルーティングの書き方を変えたなら、このテストの抽出パターンも直すこと)")
        XCTAssertEqual(found, expected,
                       "\(file) のルート表が変わりました"
                       + "(追加: \(found.subtracting(expected).sorted()) / "
                       + "削除: \(expected.subtracting(found).sorted()))。"
                       + "**\(versionHint) を上げてから**、このテストの期待値を更新すること。"
                       + "上げないと稼働中の旧ブリッジが再利用され、変更が反映されないまま緑になる")
    }
}
