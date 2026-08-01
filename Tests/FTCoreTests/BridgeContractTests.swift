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
        "POST /clear", "POST /hidekeyboard", "POST /press", "POST /pressEnter",
        "POST /session", "POST /swipe", "POST /tap", "POST /terminate", "POST /type",
    ]

    private static let xcuiTestRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /appswitcher", "POST /clear", "POST /drag", "POST /hidekeyboard",
        "POST /home", "POST /press", "POST /pressEnter", "POST /session",
        "POST /swipe", "POST /tap", "POST /terminate", "POST /type",
    ]

    private static let androidRoutes: Set<String> = [
        "GET /screenshot", "GET /snapshot", "GET /status",
        "POST /clear", "POST /locale", "POST /press",
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
            "InAppBridge/Sources/InAppBridge.swift": "6d14ed554a41c782b0bb41c2a045c229a06ca82e67c74955b23eecdc7a596b26",
            "InAppBridge/Sources/InAppHTTPServer.swift": "1d987f76a251ab475b632f24df272b000bb433054c7607e38f0447b6181e58bb",
            "InAppBridge/Sources/InAppInput.h": "acc35263e4306db4f7f5d8e544c406c292b5d1b873c953c5aa741a2de63f66eb",
            "InAppBridge/Sources/InAppInput.m": "2eff34d11bacb028604dc96d364f2fc11538039d471d1320f3a35ca4bdf14cce",
            "InAppBridge/Sources/InAppSettle.swift": "d7fa2a63009cb184ecec29262de48dcbc6e883ac62be2c8b679abd3f25626e5a",
            "InAppBridge/Sources/InAppSnapshot.swift": "a37d3c89b74eba4925b182c5e9009e09c070e190cb453029d3c443a1e2f21c8d",
            "InAppBridge/Sources/InAppWebViewDOM.swift": "b4053272dfffb11508b64bd315695123d1199768ed7ceed20f2b8272a5b10551",
            "InAppBridge/Sources/boot.m": "b23fc93fbc99ce2579c9fd8ae75a6f9bbfd0ec6122bec60eb6cd00775dd635ef",
            "InAppBridge/build.sh": "afc02d752c97a009dd48aa6cf18934af0c6f8be662d75af37cdc8c4affbc454d",
            "Sources/FTCore/BridgeDTO.swift": "e4251517018d8f80921c8bb227a24f90c961bb19195232052a79f84ee1bc8470",
            "Sources/FTCore/WebViewDOMSnapshot.swift": "3b0b20dfb2b8451f9ce19564c7d8701674f9361bbcb5b1c5afbb3570324011af",
        ],
        .xcuitest: [
            "Runner/FTesterRunnerUITests/BridgeHTTPServer.swift": "2659f97c1116efd8beaa6d7c0d74a205f307436f1e8d0869a73c81bc96033e5c",
            "Runner/FTesterRunnerUITests/BridgeRouter.swift": "d7c4c92c5136bf434d7ef70bb11daf6c7cefb32f236b39fc36d4c9f0854b1e15",
            "Runner/FTesterRunnerUITests/BridgingHeader.h": "f7ff424d9283644d0e7a0c6e202911ecbf2d9c12d469eea330d91471c4788272",
            "Runner/FTesterRunnerUITests/FTesterBridgeTests.swift": "5a3521fc332ff690cfa4a105ab8486c612814b05b637451401244e632e7c6e9e",
            "Runner/FTesterRunnerUITests/FastInput.swift": "701d7730e38d77a20682625880d32bcb387274200529f4bd28119c08038b6102",
            "Runner/FTesterRunnerUITests/ObjCExceptionCatcher.h": "5a98cdbeefb031137a985b2f4430a5e12fec447a492599f8f4da1bd2c7101edc",
            "Runner/FTesterRunnerUITests/ObjCExceptionCatcher.m": "8b41a8a81bc8199bca13a364717614684f8003999c7675d9a63242c8e74c26be",
            "Sources/FTCore/BridgeDTO.swift": "e4251517018d8f80921c8bb227a24f90c961bb19195232052a79f84ee1bc8470",
            "Sources/FTCore/TypeReadback.swift": "8238adeb5146ee2441478a94bf6e2aabb85e6c88c38538ed8df74b2e025bf8ca",
        ],
        .android: [
            "AndroidRunner/AndroidManifest.xml": "a4d6db096f2cb7da4a4431d6c13aa5828247922b19f411091a34645b1a6f7076",
            "AndroidRunner/build.sh": "666cd57fd27b3a39cb9ecea0c7776577301181df87419ddfc76ff58c6ed8a5d7",
            "AndroidRunner/src/com/example/ftbridge/BridgeHttpServer.java": "ad3dcd930eebda953c971dfee7080d438011913ab0cde1ba6a750ee0ce4e1d26",
            "AndroidRunner/src/com/example/ftbridge/BridgeInstrumentation.java": "d4c8ea3f40159f0221dcc5668a215eb0e41da8a85a332b612ce03a6fdd4623d0",
            "AndroidRunner/src/com/example/ftbridge/BridgeRouter.java": "56ae85e15c8b1a1287c0cec54acba12da5d0da0aeece590b60c6a5075fba68ed",
            "AndroidRunner/src/com/example/ftbridge/InputInjector.java": "3bc395cf1ee5ed06ee4adf41b22ab698eb53961848455d896064ee2adf3aac2e",
            "AndroidRunner/src/com/example/ftbridge/QuietWaiter.java": "bed0d4c3bbafa9a4038aabfbf1e29ebaeb0198eaf4bee926cbd842b7907c3c29",
            "AndroidRunner/src/com/example/ftbridge/SnapshotBuilder.java": "6c1540b7627083d41d1b00adf7c6861669c5c3abae53d453d1da7698ea4c529e",
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
