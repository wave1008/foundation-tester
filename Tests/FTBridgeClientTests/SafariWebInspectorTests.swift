// Safari(シミュレータ)を WebKit remote inspector で読む経路の純粋ロジック(`SafariWebInspector`。
// 2026-08-13)。I/O(unix socket / lsof / ps)はデバイスが要るのでここでは触らない。
// 守るのは**フレーム境界がずれないこと**・**別アプリ/別ソケットを読まないこと**・
// **Target 越しでないと Runtime に届かないという罠を踏まないこと**の3つ。

import XCTest
import FTCore
@testable import FTBridgeClient

final class SafariWebInspectorTests: XCTestCase {

    // MARK: - フレーミング(4byte BE 長 + 本体)

    func testEncodeThenExtractRoundTrips() {
        let body = Data("hello".utf8)
        let framed = SafariWebInspector.encodeFrame(body)
        let extracted = SafariWebInspector.extractFrame(from: framed)
        XCTAssertEqual(extracted?.body, body)
        XCTAssertEqual(extracted?.rest, Data())
    }

    /// **境界に満たないバッファは nil**(呼び出し側が読み増して再試行する契約)。
    /// ここを「あるだけ返す」にすると、recv がフレーム途中で timeout したときに
    /// 短い本体を1つのフレームとして誤って切り出し、以降ずっとバイト境界がずれる
    func testExtractFrameReturnsNilWhenBodyIncomplete() {
        let framed = SafariWebInspector.encodeFrame(Data("hello world".utf8))
        XCTAssertNil(SafariWebInspector.extractFrame(from: framed.prefix(6)))
        XCTAssertNil(SafariWebInspector.extractFrame(from: Data([0, 0])))
    }

    /// 複数フレームが1バッファに連結されていても、1回の呼び出しでは**先頭の1つだけ**切り出し、
    /// 残りは rest に残す(呼び出し側がループしてもう一度呼ぶ設計)
    func testExtractFrameLeavesTrailingBytesInRest() {
        let first = SafariWebInspector.encodeFrame(Data("A".utf8))
        let second = SafariWebInspector.encodeFrame(Data("BB".utf8))
        var combined = first
        combined.append(second)

        let firstExtraction = SafariWebInspector.extractFrame(from: combined)
        XCTAssertEqual(firstExtraction?.body, Data("A".utf8))
        let secondExtraction = SafariWebInspector.extractFrame(from: firstExtraction!.rest)
        XCTAssertEqual(secondExtraction?.body, Data("BB".utf8))
        XCTAssertEqual(secondExtraction?.rest, Data())
    }

    func testUInt32BERoundTrips() {
        for value: UInt32 in [0, 1, 255, 256, 65535, 65536, 0xFFFF_FFFF] {
            XCTAssertEqual(SafariWebInspector.readUInt32BE(SafariWebInspector.writeUInt32BE(value)), value)
        }
    }

    // MARK: - plist メッセージ(selector/argument の組み立て・分解)

    func testPlistMessageRoundTrips() throws {
        let data = try SafariWebInspector.encodePlistMessage(
            selector: "_rpc_reportIdentifier:", argument: ["WIRConnectionIdentifierKey": "ABC-123"])
        let decoded = try SafariWebInspector.decodePlistMessage(data)
        XCTAssertEqual(decoded.selector, "_rpc_reportIdentifier:")
        XCTAssertEqual(decoded.argument["WIRConnectionIdentifierKey"] as? String, "ABC-123")
    }

    // MARK: - アプリ選択(**別プロセスを Safari と誤認しない**)

    private static let sampleApps: [String: [String: Any]] = [
        "PID:33764": ["WIRApplicationNameKey": "Safari",
                      "WIRApplicationBundleIdentifierKey": "com.apple.mobilesafari"],
        "PID:8357": ["WIRApplicationNameKey": "amsengagementd",
                     "WIRApplicationBundleIdentifierKey": "com.apple.amsengagementd"],
        "PID:33818": ["WIRApplicationNameKey": "com.apple.WebKit.WebContent",
                      "WIRApplicationBundleIdentifierKey": "process-com.apple.WebKit.WebContent"],
    ]

    func testPicksSafariByBundleId() {
        XCTAssertEqual(SafariWebInspector.pickSafariApplicationId(Self.sampleApps), "PID:33764")
    }

    /// **名前の部分一致では選ばない**: `WebContent` プロセスの `WIRApplicationNameKey` には
    /// "Safari" という文字列は含まれないが、この規則が bundle id を見ていることを固定するため、
    /// 紛らわしい名前を持つ非 Safari アプリでも選ばれないことを直に確認する
    func testDoesNotPickByNameSubstring() {
        let apps: [String: [String: Any]] = [
            "PID:1": ["WIRApplicationNameKey": "Safari Helper",
                      "WIRApplicationBundleIdentifierKey": "com.example.safarihelper"],
        ]
        XCTAssertNil(SafariWebInspector.pickSafariApplicationId(apps))
    }

    func testNoSafariMeansNilNotCrash() {
        XCTAssertNil(SafariWebInspector.pickSafariApplicationId([:]))
    }

    // MARK: - ページ選択

    private func page(id: Int, type: String = "WIRTypeWebPage") -> [String: Any] {
        ["WIRPageIdentifierKey": id, "WIRTypeKey": type, "WIRURLKey": "https://example.com/\(id)"]
    }

    /// **id が最大のページを選ぶ**(実測: 後から開いたタブほど大きい id を持ち、
    /// フォアグラウンドのタブと一致した。フラグが無いのでこれが唯一の手掛かり)
    func testPicksTheHighestPageId() {
        let listing: [String: [String: Any]] = ["1": page(id: 1), "2": page(id: 2)]
        XCTAssertEqual(SafariWebInspector.pickPageId(listing), 2)
    }

    /// **WIRTypeWebPage 以外は候補にしない**(例: サービスワーカーやエクステンションページ)
    func testIgnoresNonWebPageTypes() {
        let listing: [String: [String: Any]] = ["1": page(id: 1, type: "WIRTypeServiceWorker"),
                                                 "2": page(id: 2)]
        XCTAssertEqual(SafariWebInspector.pickPageId(listing), 2)
    }

    func testEmptyListingMeansNil() {
        XCTAssertNil(SafariWebInspector.pickPageId([:]))
    }

    // MARK: - Target 包み/剥がし(**Runtime を素で撃たない罠を踏まない**)

    func testTargetCreatedIdExtractsFromEvent() {
        let message: [String: Any] = ["method": "Target.targetCreated",
                                      "params": ["targetInfo": ["targetId": "page-53"]]]
        XCTAssertEqual(SafariWebInspector.targetCreatedId(message), "page-53")
    }

    func testTargetCreatedIdIsNilForOtherMethods() {
        XCTAssertNil(SafariWebInspector.targetCreatedId(["method": "Target.dispatchMessageFromTarget"]))
    }

    /// 包んだ結果は**内側が JSON 文字列**(辞書のままではない) —— WebKit 側の要求形。
    /// ここを辞書のまま送る実装に戻すと、応答が一切来ず「原因不明のタイムアウト」になる
    func testWrapInTargetEncodesInnerAsJSONString() throws {
        let wrapped = try SafariWebInspector.wrapInTarget(
            targetId: "page-53", envelopeId: 50, inner: ["id": 1, "method": "Runtime.evaluate"])
        XCTAssertEqual(wrapped["method"] as? String, "Target.sendMessageToTarget")
        let params = try XCTUnwrap(wrapped["params"] as? [String: Any])
        XCTAssertEqual(params["targetId"] as? String, "page-53")
        let messageText = try XCTUnwrap(params["message"] as? String)
        let reparsed = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(messageText.utf8))) as? [String: Any])
        XCTAssertEqual(reparsed["method"] as? String, "Runtime.evaluate")
    }

    /// `Target.dispatchMessageFromTarget` を剥がすと内側の辞書が出てくる(内側は文字列で積まれている)
    func testUnwrapTargetMessageDecodesInnerString() throws {
        let inner = ["id": 1, "result": ["result": ["value": "{}"]]] as [String: Any]
        let innerText = String(data: try JSONSerialization.data(withJSONObject: inner), encoding: .utf8)!
        let wire: [String: Any] = ["method": "Target.dispatchMessageFromTarget",
                                   "params": ["targetId": "page-53", "message": innerText]]
        let unwrapped = try XCTUnwrap(SafariWebInspector.unwrapTargetMessage(wire))
        XCTAssertEqual(unwrapped["id"] as? Int, 1)
    }

    /// 包まれていないメッセージ(将来の保険)はそのまま通す
    func testUnwrapTargetMessagePassesThroughUnwrappedMessages() {
        let message: [String: Any] = ["method": "Target.targetCreated", "params": [:]]
        let result = SafariWebInspector.unwrapTargetMessage(message)
        XCTAssertEqual(result?["method"] as? String, "Target.targetCreated")
    }

    /// **id が一致するときだけ**値を取り出す。CDP は要求と無関係なイベントも流すため、
    /// id 照合を飛ばすとイベントの中身を評価結果と取り違える
    func testExtractEvaluateResultRequiresMatchingId() {
        let matching: [String: Any] = ["id": 1, "result": ["result": ["value": "{\"nodes\":[]}"]]]
        XCTAssertEqual(SafariWebInspector.extractEvaluateResult(matching, expectingId: 1), "{\"nodes\":[]}")

        let mismatched: [String: Any] = ["id": 2, "result": ["result": ["value": "should not be read"]]]
        XCTAssertNil(SafariWebInspector.extractEvaluateResult(mismatched, expectingId: 1))

        let event: [String: Any] = ["method": "Target.targetCreated"]
        XCTAssertNil(SafariWebInspector.extractEvaluateResult(event, expectingId: 1))
    }

    // MARK: - ソケット選択(**別シミュレータのソケットを読まない**)

    private static let lsofOutput = """
    p6578
    f10
    n/private/var/tmp/com.apple.launchd.EVdpOjQuv9/com.apple.webinspectord_sim.socket
    f12
    n/private/var/tmp/com.apple.launchd.EVdpOjQuv9/com.apple.webinspectord_sim.socket
    p7989
    f10
    n/private/var/tmp/com.apple.launchd.rES0VI59Si/com.apple.webinspectord_sim.socket
    """

    private static let psOutput = """
     6578 launchd_sim /Users/x/Library/Developer/CoreSimulator/Devices/E38DCA93-95F2-4DDF-B1FE-29527205D3EE/data/var/run/launchd_bootstrap.plist
     7989 launchd_sim /Users/x/Library/Developer/CoreSimulator/Devices/C96A69C4-FE49-42EE-8C7F-ED5F603C346B/data/var/run/launchd_bootstrap.plist
    """

    private static let sockets = [
        "/private/var/tmp/com.apple.launchd.EVdpOjQuv9/com.apple.webinspectord_sim.socket",
        "/private/var/tmp/com.apple.launchd.rES0VI59Si/com.apple.webinspectord_sim.socket",
    ]

    func testParsesLsofPidsByPath() {
        let pids = SafariWebInspector.parseLsofPidsByPath(Self.lsofOutput)
        XCTAssertEqual(pids["/private/var/tmp/com.apple.launchd.EVdpOjQuv9/com.apple.webinspectord_sim.socket"], 6578)
        XCTAssertEqual(pids["/private/var/tmp/com.apple.launchd.rES0VI59Si/com.apple.webinspectord_sim.socket"], 7989)
    }

    func testParsesPsCommandsByPid() {
        let commands = SafariWebInspector.parsePsCommandsByPid(Self.psOutput)
        XCTAssertEqual(commands[6578]?.contains("E38DCA93-95F2-4DDF-B1FE-29527205D3EE"), true)
        XCTAssertEqual(commands[7989]?.contains("C96A69C4-FE49-42EE-8C7F-ED5F603C346B"), true)
    }

    func testExtractsUDIDFromLaunchdSimCommandLine() {
        let cmd = "launchd_sim /Users/x/Library/Developer/CoreSimulator/Devices/" +
            "E38DCA93-95F2-4DDF-B1FE-29527205D3EE/data/var/run/launchd_bootstrap.plist"
        XCTAssertEqual(SafariWebInspector.udid(fromLaunchdSimCommandLine: cmd), "E38DCA93-95F2-4DDF-B1FE-29527205D3EE")
    }

    /// 桁数が違えば UDID として認めない(たまたま "CoreSimulator/Devices/" を含む別の文字列に釣られない)
    func testRejectsMalformedUDIDShapes() {
        XCTAssertNil(SafariWebInspector.udid(fromLaunchdSimCommandLine: "x CoreSimulator/Devices/not-a-udid/y"))
        XCTAssertNil(SafariWebInspector.udid(fromLaunchdSimCommandLine: "no marker here"))
    }

    /// **対象 UDID のソケットだけを選ぶ**。ここを妥協すると別シミュレータの Safari の DOM を
    /// 自分の木へ混ぜる(Android の pid 取り違えと同型の事故)
    func testPicksTheSocketOfTheGivenUDID() {
        let picked = SafariWebInspector.socketPath(
            forUDID: "C96A69C4-FE49-42EE-8C7F-ED5F603C346B", sockets: Self.sockets,
            lsofOutput: Self.lsofOutput, psOutput: Self.psOutput)
        XCTAssertEqual(picked, "/private/var/tmp/com.apple.launchd.rES0VI59Si/com.apple.webinspectord_sim.socket")
    }

    func testUnknownUDIDMeansNoSocket() {
        let picked = SafariWebInspector.socketPath(
            forUDID: "00000000-0000-0000-0000-000000000000", sockets: Self.sockets,
            lsofOutput: Self.lsofOutput, psOutput: Self.psOutput)
        XCTAssertNil(picked)
    }

    // MARK: - 木への差し込み(座標の写し・WebView 選択)は `FTCore.WebViewDOM` へ移設済み
    // (`Tests/FTCoreTests/WebViewDOMSnapshotTests.swift` に集約。iOS 固有の density: 1 の
    // 呼び方はそちらの `testElementsWithDensityOneAddsOnlyTheOrigin` が守る)

    // MARK: - 殺しスイッチ(**既定オン**。`FT_BROWSER_DOM=off` のときだけ無効)

    func testEnabledByDefault() {
        XCTAssertTrue(SafariWebInspector.isEnabled(env: [:]))
        XCTAssertTrue(SafariWebInspector.isEnabled(env: ["FT_BROWSER_DOM": "1"]))
    }

    func testOffDisables() {
        XCTAssertFalse(SafariWebInspector.isEnabled(env: ["FT_BROWSER_DOM": "off"]))
    }

    // MARK: - ソケットの探索範囲

    /// **根は2つ必要**(2026-08-13 に実データで踏んだ)。ソケットの置き場所は
    /// シミュレータを起こしたプロセスの `TMPDIR` で決まり、macOS では `/private/tmp` と
    /// `/private/var/tmp` は**別ディレクトリ**。片方だけ見ていたとき、シェルから
    /// `simctl boot` した1台が丸ごと見えず `read` が黙って nil を返した
    func testLooksInBothTemporaryRoots() {
        XCTAssertTrue(SafariWebInspector.socketRoots.contains("/private/var/tmp"))
        XCTAssertTrue(SafariWebInspector.socketRoots.contains("/private/tmp"),
                      "シェルから起こしたシミュレータはこちらに出る")
        XCTAssertEqual(Set(SafariWebInspector.socketRoots).count,
                       SafariWebInspector.socketRoots.count, "同じ根を二度走査しない")
    }
}
