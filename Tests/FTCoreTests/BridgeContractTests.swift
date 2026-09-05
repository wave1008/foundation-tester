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
    // 3実装でルートが異なるのは仕様。共通コアは11本で、差分は:
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
        "POST /hidekeyboard", "POST /home", "POST /pinch", "POST /press", "POST /pressEnter",
        "POST /rotate", "POST /session", "POST /swipe", "POST /tap", "POST /terminate",
        "POST /type",
    ]

    static let androidRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /clear", "POST /doubletap", "POST /locale", "POST /pinch", "POST /press",
        "POST /pressEnter", "POST /session", "POST /settle", "POST /swipe",
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
            "InAppBridge/Sources/DisplayHeartbeat.swift": "d3c4064aba162654bb568ff1823a4b4977b5e0421b48c9724a5cda69e8bd87f4",
            "InAppBridge/Sources/InAppBridge.swift": "1051a69ba54f3ce59ee9d40badfb97400de21b1fa138d32e27b29c5c3597a48a",
            "InAppBridge/Sources/InAppHTTPServer.swift": "0c5402ec749354725ef5a9b13d2e7b42cef11488a56f969d7dbe6667f79a5aea",
            "InAppBridge/Sources/InAppInput.h": "cb980dcf8b80c38a97a841946354460ce6fd960baf53ada67aa939e16e373a65",
            "InAppBridge/Sources/InAppInput.m": "87a55266d20b0f32ceeb3f65187014e484f4ed61a49be2b81c5d6cab35558ada",
            "InAppBridge/Sources/InAppSettle.swift": "62ae8446e108a68b4a72ef1f8226d530d77683087fde133cfe7a05ee13a2a6e1",
            "InAppBridge/Sources/InAppSnapshot.swift": "3f12b7e72931611a0d0f7483fc10c7ba3515368d2974b36d0ada2dcf54b28de4",
            "InAppBridge/Sources/InAppWebViewDOM.swift": "8bd0367a7bd877fa89341418bbce853aa7293869c0029df7ad46bd2f1e29eb3d",
            "InAppBridge/Sources/boot.m": "b23fc93fbc99ce2579c9fd8ae75a6f9bbfd0ec6122bec60eb6cd00775dd635ef",
            "InAppBridge/build.sh": "73f53b3434d29114cf1bd0fd68264d373dc2730585d9f0c001d750dfd2844794",
            "Sources/FTCore/BridgeDTO.swift": "1a2482f6caa49eaf6d6af53221ab10ea56d0e48f6bbb482e7aedf62a3380fd3d",
            "Sources/FTCore/WebViewDOMSnapshot.swift": "649134e9ee668e692000ad362c71f5821ac21f351485ba5c985ec75d64594726",
        ],
        .xcuitest: [
            "Runner/FleetestRunnerUITests/BridgeHTTPServer.swift": "05fca42b7ba467553b96f100f46597f8e4fb1cae75813ca520e5028c4d23bf59",
            "Runner/FleetestRunnerUITests/BridgeRouter.swift": "ef346dd22c5cc8304583c0da8d91a4c523c21d2030ec2b2af69379a4eefe3adc",
            "Runner/FleetestRunnerUITests/BridgingHeader.h": "f7ff424d9283644d0e7a0c6e202911ecbf2d9c12d469eea330d91471c4788272",
            "Runner/FleetestRunnerUITests/DisplayHeartbeat.swift": "c62c30a45e842d5ec7aff60210284d679b76f6e44358a3f4c97429fe918e5ffa",
            "Runner/FleetestRunnerUITests/FastInput.swift": "50f5c3893a1eeb9faf0e0a7e7f66050abe31efb87d35f454dac78ac38becb748",
            "Runner/FleetestRunnerUITests/FleetestBridgeTests.swift": "7535575cb78a9bf236c0174ea47df497c95991c5bb1095573c72f69956186a8b",
            "Runner/FleetestRunnerUITests/ObjCExceptionCatcher.h": "5a98cdbeefb031137a985b2f4430a5e12fec447a492599f8f4da1bd2c7101edc",
            "Runner/FleetestRunnerUITests/ObjCExceptionCatcher.m": "8b41a8a81bc8199bca13a364717614684f8003999c7675d9a63242c8e74c26be",
            "Sources/FTCore/BridgeDTO.swift": "1a2482f6caa49eaf6d6af53221ab10ea56d0e48f6bbb482e7aedf62a3380fd3d",
            "Sources/FTCore/SnapshotDedupe.swift": "12a22200bd2048a2b3140c38e7816e341f6c56e25e1ab3a6d1b9d5c5259a56f8",
            "Sources/FTCore/TypeReadback.swift": "0bb50d073aa62a78711571794ee655afa609513de9baa7f208fbde78337b8351",
        ],
        .android: [
            "AndroidRunner/AndroidManifest.xml": "bae5a24f97e5539df0fe73d09efea998054ef498a0ab365752367fcfe21ddc9c",
            "AndroidRunner/build.sh": "b136074f6bd0753af9c4186ec066407492125748aef24dd13e6556cfd3c3524a",
            "AndroidRunner/src/com/example/ftbridge/BridgeHttpServer.java": "b609667ed2731774020ec9ba5dc3c3da99cb48eab8b5fd1b2f708ff202dc4f00",
            "AndroidRunner/src/com/example/ftbridge/BridgeInstrumentation.java": "9f27998ec3d464f120396612876dbc19f4942cf6274ab00829ad0e4d4ec70bf2",
            "AndroidRunner/src/com/example/ftbridge/BridgeRouter.java": "ef1cb1226fedbc6ca2c80944336806e62cb6305dabeeae2db7ea903e4a9b9ea9",
            "AndroidRunner/src/com/example/ftbridge/DisplayHeartbeat.java": "34c91b37e01829307897825e7104d250c8662f00ce9734512f3c41da8bccd956",
            "AndroidRunner/src/com/example/ftbridge/InputInjector.java": "bf8c0abcaca1347fe8757732f94ad0da1f7885f4b3eb247629347fd6c0a713d4",
            "AndroidRunner/src/com/example/ftbridge/QuietWaiter.java": "bed0d4c3bbafa9a4038aabfbf1e29ebaeb0198eaf4bee926cbd842b7907c3c29",
            "AndroidRunner/src/com/example/ftbridge/SnapshotBuilder.java": "00fc8edb5f4456daee41bc25107e5f1d530eb86ae108e02210fbd56d4efa9fdd",
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
