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
    //   in-app / XCUITest ランナー → Sources/FTCore/BridgeDTO.swift の bridgeProtocolVersion
    //   Android                    → AndroidRunner/build.sh の VERSION_CODE と
    //                                Sources/FTAndroid/AndroidBridge.swift の expectedBridgeVersionCode
    // 3実装でルートが異なるのは仕様(in-app は同一プロセスしか見えないので /drag・/appswitcher・
    // /home を持たず、/locale は Android だけ)。
    private static let inAppRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /clear", "POST /press", "POST /pressEnter", "POST /session",
        "POST /swipe", "POST /tap", "POST /terminate", "POST /type",
    ]

    private static let xcuiTestRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /appswitcher", "POST /clear", "POST /drag", "POST /home",
        "POST /press", "POST /pressEnter", "POST /session",
        "POST /swipe", "POST /tap", "POST /terminate", "POST /type",
    ]

    private static let androidRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /clear", "POST /locale", "POST /press", "POST /pressEnter",
        "POST /session", "POST /settle", "POST /swipe", "POST /tap",
        "POST /terminate", "POST /type",
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
            file: "Runner/FTesterRunnerUITests/BridgeRouter.swift",
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
            "InAppBridge/Sources/InAppBridge.swift": "b8fa4745ea8b946f9769c3511090f03c7ea11ec642af76c258c5c7e86511f288",
            "InAppBridge/Sources/InAppHTTPServer.swift": "1d987f76a251ab475b632f24df272b000bb433054c7607e38f0447b6181e58bb",
            "InAppBridge/Sources/InAppInput.h": "acc35263e4306db4f7f5d8e544c406c292b5d1b873c953c5aa741a2de63f66eb",
            "InAppBridge/Sources/InAppInput.m": "8046707ebfc7ca1681283bd82df22afee690ea66d01e8ef6b40036001b92af53",
            "InAppBridge/Sources/InAppSettle.swift": "73998e66210231557a05de7a1f4bfec95f801fe3217c77c852495e1a5dedbde1",
            "InAppBridge/Sources/InAppSnapshot.swift": "b061131e9e2b109ef2399ee1d3b4b8f132d23b5f7a55df7654a5d756d5f2ca90",
            "InAppBridge/Sources/InAppWebViewDOM.swift": "b4053272dfffb11508b64bd315695123d1199768ed7ceed20f2b8272a5b10551",
            "InAppBridge/Sources/boot.m": "b23fc93fbc99ce2579c9fd8ae75a6f9bbfd0ec6122bec60eb6cd00775dd635ef",
            "InAppBridge/build.sh": "afc02d752c97a009dd48aa6cf18934af0c6f8be662d75af37cdc8c4affbc454d",
            "Sources/FTCore/BridgeDTO.swift": "d48e67a3e7eb54fbe9e76d1d47f0dd7e531a81483cfdb92600a72ffa5a658a26",
            "Sources/FTCore/WebViewDOMSnapshot.swift": "3b0b20dfb2b8451f9ce19564c7d8701674f9361bbcb5b1c5afbb3570324011af",
        ],
        .xcuitest: [
            "Runner/FTesterRunnerUITests/BridgeHTTPServer.swift": "2659f97c1116efd8beaa6d7c0d74a205f307436f1e8d0869a73c81bc96033e5c",
            "Runner/FTesterRunnerUITests/BridgeRouter.swift": "25ac42e9ae47eebd00b75792f2650ac40bf6997e2c8e4ef62b82073845861fde",
            "Runner/FTesterRunnerUITests/BridgingHeader.h": "f7ff424d9283644d0e7a0c6e202911ecbf2d9c12d469eea330d91471c4788272",
            "Runner/FTesterRunnerUITests/FTesterBridgeTests.swift": "5a3521fc332ff690cfa4a105ab8486c612814b05b637451401244e632e7c6e9e",
            "Runner/FTesterRunnerUITests/FastInput.swift": "701d7730e38d77a20682625880d32bcb387274200529f4bd28119c08038b6102",
            "Runner/FTesterRunnerUITests/ObjCExceptionCatcher.h": "5a98cdbeefb031137a985b2f4430a5e12fec447a492599f8f4da1bd2c7101edc",
            "Runner/FTesterRunnerUITests/ObjCExceptionCatcher.m": "8b41a8a81bc8199bca13a364717614684f8003999c7675d9a63242c8e74c26be",
            "Sources/FTCore/BridgeDTO.swift": "d48e67a3e7eb54fbe9e76d1d47f0dd7e531a81483cfdb92600a72ffa5a658a26",
        ],
        .android: [
            "AndroidRunner/AndroidManifest.xml": "a4d6db096f2cb7da4a4431d6c13aa5828247922b19f411091a34645b1a6f7076",
            "AndroidRunner/build.sh": "666cd57fd27b3a39cb9ecea0c7776577301181df87419ddfc76ff58c6ed8a5d7",
            "AndroidRunner/src/com/example/ftbridge/BridgeHttpServer.java": "11b86fcb58fe8a1feea246011af80ae1f28202b02105f2fe597513895be8bde2",
            "AndroidRunner/src/com/example/ftbridge/BridgeInstrumentation.java": "d4c8ea3f40159f0221dcc5668a215eb0e41da8a85a332b612ce03a6fdd4623d0",
            "AndroidRunner/src/com/example/ftbridge/BridgeRouter.java": "91b2013b838701a5ebc26e1eba150bcb22b838b64b4b931162dcfde8cc14c9c1",
            "AndroidRunner/src/com/example/ftbridge/InputInjector.java": "66a7c76d17a80f6bcf031cd4b66113feb8a3a205e1bf924e6d6086fb8e9538e6",
            "AndroidRunner/src/com/example/ftbridge/QuietWaiter.java": "bed0d4c3bbafa9a4038aabfbf1e29ebaeb0198eaf4bee926cbd842b7907c3c29",
            "AndroidRunner/src/com/example/ftbridge/SnapshotBuilder.java": "2e90b2d767240888d47d54c01e52446980d9e80e55d72a01e7b83c23772d92d3",
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
    private let swiftRoutePattern = #"case \("(GET|POST)", "(/[A-Za-z]+)"\)"#
    /// Java 側: `case "GET /status":` → `GET /status`
    private let javaRoutePattern = #"case "(GET|POST) (/[A-Za-z]+)":"#

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
