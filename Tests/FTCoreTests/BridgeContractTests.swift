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
    //   /gesture   … XCUITest ランナーと Android だけ(iOS 126 / Android 72)。in-app は持たず、hybrid は
    //                 既定の 501 で XCUITest へ回す(指ごとの時刻つき経路を1回で再生する)
    //   /hold      … XCUITest ランナーと Android だけ。in-app は持たず、hybrid は XCUITest へ回す
    //                 (指を置いたら応答を返す = 置いている間に木を読める)
    static let inAppRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /appstate", "POST /clear", "POST /doubletap", "POST /hidekeyboard", "POST /pinch",
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
        // engine=xcuitest は主ドライバと同じブリッジを共有するので、
        // 旧経路(POST /session springboard)だとアプリのセッションが巻き添えになる。
        // drag / swipe は座標を **SpringBoard 基準**で撃つ(版 80)—— tapAppIcon は
        // home() の直後に呼ぶので、セッションのアプリを原点にする /drag では
        // 背面アプリの座標解決でランナーごと落ちる(BridgeRouter.systemUIAnchor)
        "GET /systemui/snapshot", "POST /systemui/tap",
        "POST /systemui/drag", "POST /systemui/swipe",
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /appstate", "POST /appswitcher", "POST /clear", "POST /doubletap", "POST /drag",
        "POST /gesture", "POST /hidekeyboard", "POST /hold", "POST /home", "POST /pinch", "POST /press",
        "POST /pressEnter", "POST /rotate", "POST /session", "POST /swipe", "POST /tap", "POST /terminate",
        "POST /type",
    ]

    static let androidRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /clear", "POST /doubletap", "POST /gesture", "POST /hold", "POST /locale", "POST /pinch", "POST /press",
        "POST /pressEnter", "POST /scrollAction", "POST /session", "POST /settle", "POST /swipe",
        "POST /tap", "POST /terminate", "POST /type",
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
            "InAppBridge/Sources/InAppBridge.swift": "be970c2283250254a9967c23f5c434944c1133db07734b4e2349e4944732810d",
            "InAppBridge/Sources/InAppHTTPServer.swift": "549ee40d08db2a479bb9bbf5ea1b3843549e079652c7ea6d36128573b1678ecb",
            "InAppBridge/Sources/InAppInput.h": "8e8463e115844721d0bc6c7b018549236f042604dd2168d0efba4c9c69bea8a2",
            "InAppBridge/Sources/InAppInput.m": "3eb5aa511f3f8803a36cd99dcdbf8a1128ea08897bef7f0fc21d9f5320982162",
            "InAppBridge/Sources/InAppSettle.swift": "5871ae6c3ecb272614528e7d1657aa6c6bcaee31fa6db3f3e02b6a81caa61c80",
            "InAppBridge/Sources/InAppSnapshot.swift": "e12ac1a0f6d1fbd6a15ad411797db8705645a249d855c8941cf606222e370a02",
            "InAppBridge/Sources/InAppWebViewDOM.swift": "7c1cc1c37e4d8f79fc67d5adbda91febc53f7e017d10fd23f3cc3259a402afca",
            "InAppBridge/Sources/boot.m": "b23fc93fbc99ce2579c9fd8ae75a6f9bbfd0ec6122bec60eb6cd00775dd635ef",
            "InAppBridge/build.sh": "7a0c3b6359ecb213cc028afee402efb227e85c3c06f61d1d065c70288b1e3e4a",
            "Sources/FTCore/AXFrameRescale.swift": "2e09609619aefcc33658163d57e1751f475771dc3841c79f9ca0b721c8fd1250",
            "Sources/FTCore/BridgeDTO.swift": "5fdd64392016d2e662c9493ca7e6b2d22bd4129f9c163c5119f6811b29e55e49",
            "Sources/FTCore/TypeReadback.swift": "c9080f52f741398ba61e2d7f1ab7a880721379c27f33ee09ef1dedf5b768e9c8",
            "Sources/FTCore/UIFrameworkMarkers.swift": "1601c9feecaa817d73deea4445523522341ae1b777086b55c33c6e0a74fef6b8",
            "Sources/FTCore/WebViewDOMSnapshot.swift": "7e254f20bc68685cad1ecb85e4c6ccf9628d7e33d9697d47a9ca26b3b72fed36",
        ],
        .xcuitest: [
            "Runner/FleetestRunnerUITests/BridgeHTTPServer.swift": "0b78c5bf0d29f3088a49d741dc840590f37b4cdd8179329ce253124de29ccaf7",
            "Runner/FleetestRunnerUITests/BridgeRouter+Snapshot.swift": "55f5bdc9607198d489299ee946d4c2521802836219e3f9d2712bc06adace4334",
            "Runner/FleetestRunnerUITests/BridgeRouter+TextInput.swift": "7b71ad3f8f69da5426879061271d50092a6897d1842047334622614e10f3b831",
            "Runner/FleetestRunnerUITests/BridgeRouter.swift": "5608481871cd46a1dd301a4d238a7b904e04147272ef2461090efa34d8b69b6a",
            "Runner/FleetestRunnerUITests/BridgingHeader.h": "f7ff424d9283644d0e7a0c6e202911ecbf2d9c12d469eea330d91471c4788272",
            "Runner/FleetestRunnerUITests/CoordinatePinch.swift": "2fe85aaf98e42be9310de3dc95602831ec8a6ea9997b26daac84056b3da50f30",
            "Runner/FleetestRunnerUITests/DisplayHeartbeat.swift": "c62c30a45e842d5ec7aff60210284d679b76f6e44358a3f4c97429fe918e5ffa",
            "Runner/FleetestRunnerUITests/QuiescenceWait.swift": "6eb216bdc7f6a012ee3352b269ac6e6fe593763bf27687566b501c1c68135399",
            "Runner/FleetestRunnerUITests/FleetestBridgeTests.swift": "f067851e91fad9b386d9152501efa5ceed836d5afd40687ab9ce5e13c806a719",
            "Runner/FleetestRunnerUITests/InterruptionGuard.swift": "413462f639dac179b10155b07ff77ffe244fcf5e1cb8be4073b62853c0c805b2",
            "Runner/FleetestRunnerUITests/ObjCExceptionCatcher.h": "5a98cdbeefb031137a985b2f4430a5e12fec447a492599f8f4da1bd2c7101edc",
            "Runner/FleetestRunnerUITests/ObjCExceptionCatcher.m": "8b41a8a81bc8199bca13a364717614684f8003999c7675d9a63242c8e74c26be",
            "Sources/FTCore/AXFrameRescale.swift": "2e09609619aefcc33658163d57e1751f475771dc3841c79f9ca0b721c8fd1250",
            "Sources/FTCore/BridgeDTO.swift": "5fdd64392016d2e662c9493ca7e6b2d22bd4129f9c163c5119f6811b29e55e49",
            "Sources/FTCore/SnapshotDedupe.swift": "f987a913f2010e8cd81e381c595c15242f58225c71a11a9be206590baccf8c9b",
            "Sources/FTCore/TypeReadback.swift": "c9080f52f741398ba61e2d7f1ab7a880721379c27f33ee09ef1dedf5b768e9c8",
        ],
        .android: [
            "AndroidRunner/AndroidManifest.xml": "cf43535a8f8e3361bafd6761b99cbf9e4347afd9ac76d42ed82da0e032908b17",
            "AndroidRunner/build.sh": "b136074f6bd0753af9c4186ec066407492125748aef24dd13e6556cfd3c3524a",
            "AndroidRunner/src/com/example/ftbridge/BridgeHttpServer.java": "863ec6982e6dd41c6bda8f8f6fe998c17c95b0f250c7f57345e6c5cb617f26ac",
            "AndroidRunner/src/com/example/ftbridge/BridgeInstrumentation.java": "78fe5cc272782a091bbbc512d1693bed0a192cf363548699a586cb0f3d614824",
            "AndroidRunner/src/com/example/ftbridge/BridgeRouter.java": "b6a55cb3168a7156f9d99f553532a3deef89fd49f8e52b5109f480d24e5e4298",
            "AndroidRunner/src/com/example/ftbridge/DisplayHeartbeat.java": "b00ff62b9a909e7e46df1a7a1aa1f39ba0a5711834092148adfee9f6bd6c7d9a",
            "AndroidRunner/src/com/example/ftbridge/ImeOnboarding.java": "fe2d90d892046f64e4893c008148d47886e36bceb244dd9e68e560b368f0193b",
            "AndroidRunner/src/com/example/ftbridge/KeyboardPrimerActivity.java": "f5a4751486cd8349a8f10b65332d6a3e1d77c3d82e0528e8518ec646aad152d9",
            "AndroidRunner/src/com/example/ftbridge/InputInjector.java": "86fca917693683aeb08807e72010c7e885a8f4067368a54986efbc1805ba5cc7",
            "AndroidRunner/src/com/example/ftbridge/QuietWaiter.java": "b939eb89d48c6a3591a78b8457b31f851cd95c0f188fffdaa1668f557153347d",
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
