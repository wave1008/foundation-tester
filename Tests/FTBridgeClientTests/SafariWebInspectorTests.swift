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

// MARK: - 実機経路(usbmuxd → lockdown → TLS)の純粋ロジック。デバイスが要る TLS ハンドシェイク
// 自体は対象外(`PhysicalSafariInspector.connect` は実機接続で検証。docs/報告参照)

final class PhysicalSafariInspectorTests: XCTestCase {

    // MARK: - usbmuxd フレーミング(16byte リトルエンディアンヘッダ + XML plist)

    func testUsbmuxdEnvelopeRoundTrips() {
        guard let encoded = UsbmuxdEnvelope.encode(["MessageType": "ListDevices"], tag: 7) else {
            return XCTFail("encode failed")
        }
        guard let header = UsbmuxdEnvelope.parseHeader(encoded) else { return XCTFail("header parse failed") }
        XCTAssertEqual(header.length, UInt32(encoded.count))
        XCTAssertEqual(header.version, 1)
        XCTAssertEqual(header.message, 8)
        XCTAssertEqual(header.tag, 7)
        let body = encoded.subdata(in: UsbmuxdEnvelope.headerSize..<encoded.count)
        let payload = UsbmuxdEnvelope.decodePayload(body)
        XCTAssertEqual(payload?["MessageType"] as? String, "ListDevices")
    }

    /// **不完全なヘッダは nil**(16byte 未満)。境界判定を緩めると、後続の read が
    /// 途中のヘッダを誤ってフルヘッダとして解釈し、以降ずっとバイトがずれる
    func testUsbmuxdEnvelopeHeaderRejectsShortBuffers() {
        XCTAssertNil(UsbmuxdEnvelope.parseHeader(Data([0, 1, 2])))
    }

    /// PortNumber は usbmuxd 側へネットワークバイト順で積む。**実測値で固定**
    /// (2026-08-13 実機・lockdownd ポート 62078 → 32498。ここがずれると Connect 自体は
    /// 200 で返るが繋いだポートが lockdownd ではなく無関係な相手になる)
    func testConnectPortValueMatchesMeasuredNetworkByteOrder() {
        XCTAssertEqual(UsbmuxdEnvelope.connectPortValue(62078), 32498)
    }

    // MARK: - ReadPairRecord / ListDevices の応答パース

    func testParsePairRecordExtractsCredentials() {
        let inner: [String: Any] = ["HostID": "HOST-1", "SystemBUID": "BUID-1",
                                    "HostCertificate": Data("cert".utf8), "HostPrivateKey": Data("key".utf8)]
        let innerData = try! PropertyListSerialization.data(fromPropertyList: inner, format: .xml, options: 0)
        let record = UsbmuxdEnvelope.parsePairRecord(["PairRecordData": innerData])
        XCTAssertEqual(record?.hostID, "HOST-1")
        XCTAssertEqual(record?.systemBUID, "BUID-1")
        XCTAssertEqual(record?.hostCertificate, Data("cert".utf8))
        XCTAssertEqual(record?.hostPrivateKey, Data("key".utf8))
    }

    /// 鍵が1つでも欠ければ nil(TLS を張れないまま先へ進んで訳の分からない失敗にしない)
    func testParsePairRecordRejectsMissingKey() {
        let inner: [String: Any] = ["HostID": "HOST-1", "SystemBUID": "BUID-1", "HostCertificate": Data("cert".utf8)]
        let innerData = try! PropertyListSerialization.data(fromPropertyList: inner, format: .xml, options: 0)
        XCTAssertNil(UsbmuxdEnvelope.parsePairRecord(["PairRecordData": innerData]))
    }

    func testParsePairRecordRejectsMissingPairRecordData() {
        XCTAssertNil(UsbmuxdEnvelope.parsePairRecord([:]))
    }

    func testDeviceIDPicksMatchingSerialNumber() {
        let response: [String: Any] = ["DeviceList": [
            ["DeviceID": 12, "Properties": ["SerialNumber": "OTHER-UDID"]],
            ["DeviceID": 94, "Properties": ["SerialNumber": "00008130-001819863E60001C"]],
        ]]
        XCTAssertEqual(UsbmuxdEnvelope.deviceID(forHardwareUDID: "00008130-001819863E60001C", in: response), 94)
    }

    func testDeviceIDReturnsNilWhenNoSerialMatches() {
        let response: [String: Any] = ["DeviceList": [["DeviceID": 12, "Properties": ["SerialNumber": "OTHER"]]]]
        XCTAssertNil(UsbmuxdEnvelope.deviceID(forHardwareUDID: "MISSING", in: response))
    }

    func testConnectSucceededRequiresNumberZero() {
        XCTAssertTrue(UsbmuxdEnvelope.connectSucceeded(["Number": 0]))
        XCTAssertFalse(UsbmuxdEnvelope.connectSucceeded(["Number": 1]))
        XCTAssertFalse(UsbmuxdEnvelope.connectSucceeded([:]))
    }

    // MARK: - lockdown プロトコル(request 組み立て・response 判定)

    func testStartSessionRequestCarriesHostIdentity() {
        let request = LockdownProtocol.startSessionRequest(hostID: "HOST-1", systemBUID: "BUID-1")
        XCTAssertEqual(request["Request"] as? String, "StartSession")
        XCTAssertEqual(request["HostID"] as? String, "HOST-1")
        XCTAssertEqual(request["SystemBUID"] as? String, "BUID-1")
    }

    func testStartServiceRequestCarriesServiceName() {
        let request = LockdownProtocol.startServiceRequest("com.apple.webinspector")
        XCTAssertEqual(request["Request"] as? String, "StartService")
        XCTAssertEqual(request["Service"] as? String, "com.apple.webinspector")
    }

    func testEnableSessionSSLRequiresExplicitTrue() {
        XCTAssertTrue(LockdownProtocol.enableSessionSSL(["EnableSessionSSL": true]))
        XCTAssertFalse(LockdownProtocol.enableSessionSSL(["EnableSessionSSL": false]))
        XCTAssertFalse(LockdownProtocol.enableSessionSSL([:]))
    }

    func testServiceStartParsesPortAndSSLFlag() {
        let start = LockdownProtocol.serviceStart(["Port": 52086, "EnableServiceSSL": true])
        XCTAssertEqual(start?.port, 52086)
        XCTAssertEqual(start?.enableSSL, true)
    }

    /// **範囲外の Port は拒否**(0 や 65536 超はプロトコル違反。UInt16 化する前に弾かないと
    /// 意味不明な数値でトンネルを張りに行くことになる)
    func testServiceStartRejectsOutOfRangePort() {
        XCTAssertNil(LockdownProtocol.serviceStart(["Port": 0]))
        XCTAssertNil(LockdownProtocol.serviceStart(["Port": 70000]))
        XCTAssertNil(LockdownProtocol.serviceStart([:]))
    }

    func testIsInvalidServiceDetectsTheSpecificError() {
        XCTAssertTrue(LockdownProtocol.isInvalidService(["Error": "InvalidService"]))
        XCTAssertFalse(LockdownProtocol.isInvalidService(["Error": "SomethingElse"]))
        XCTAssertFalse(LockdownProtocol.isInvalidService([:]))
    }

    // MARK: - FrameBuffer(生ソケット/TLS 共通の受信バッファリング)

    func testFrameBufferExtractsAFrameAcrossMultipleChunks() {
        let frame = SafariWebInspector.encodeFrame(Data("hello".utf8))
        let firstHalf = frame.prefix(3)
        let secondHalf = frame.suffix(from: 3)
        var chunks: [FrameBuffer.ChunkResult] = [.data(Data(firstHalf)), .data(Data(secondHalf))]
        let buffer = FrameBuffer()
        let body = buffer.receiveFrame(deadline: Date().addingTimeInterval(5)) { _ in
            chunks.isEmpty ? .timeout : chunks.removeFirst()
        }
        XCTAssertEqual(body, Data("hello".utf8))
    }

    /// 締切を過ぎたら nil で諦める(readChunk が呼ばれ続けて無限に待たない)
    func testFrameBufferGivesUpAtDeadline() {
        let buffer = FrameBuffer()
        let body = buffer.receiveFrame(deadline: Date(timeIntervalSinceNow: -1)) { _ in .timeout }
        XCTAssertNil(body)
    }

    func testFrameBufferClosedChunkEndsWithoutRetrying() {
        let buffer = FrameBuffer()
        var calls = 0
        let body = buffer.receiveFrame(deadline: Date().addingTimeInterval(5)) { _ in calls += 1; return .closed }
        XCTAssertNil(body)
        XCTAssertEqual(calls, 1, "EOF は即座に諦める(タイムアウトと違って再試行しない)")
    }

    // MARK: - PKCS#12 経由の SecIdentity 生成(実機不要。openssl で自己署名鍵を作って検証)

    /// **難所の実地確認**: ペアリング記録相当の PEM(証明書+秘密鍵)から `SecIdentity` を
    /// 作れるか。実機の鍵の代わりに openssl でその場生成した自己署名鍵を使う —— 形式
    /// (PEM 証明書 + PEM 秘密鍵)が同じなので、実機無しでもインポート経路そのものを検証できる
    func testImportIdentityFromASelfSignedKeyPair() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fleetest-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("key.pem").path
        let certPath = dir.appendingPathComponent("cert.pem").path
        let generated = try Shell.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                                       "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", keyPath,
                                       "-out", certPath, "-days", "1", "-subj", "/CN=fleetest-test"])
        try XCTSkipUnless(generated.status == 0, "openssl が使えない環境: \(generated.tail)")

        let certData = try Data(contentsOf: URL(fileURLWithPath: certPath))
        let keyData = try Data(contentsOf: URL(fileURLWithPath: keyPath))
        let identity = PairingIdentityImporter.importIdentity(hostCertificate: certData, hostPrivateKey: keyData)
        XCTAssertNotNil(identity, "PEM の証明書+鍵から SecIdentity を作れること")
    }

    /// 壊れた PEM(鍵無し)は nil で諦める(TLS を張れないまま先に進まない)
    func testImportIdentityRejectsGarbageInput() {
        let identity = PairingIdentityImporter.importIdentity(
            hostCertificate: Data("not a certificate".utf8), hostPrivateKey: Data("not a key".utf8))
        XCTAssertNil(identity)
    }

    // MARK: - 実機ライブ検証(`FT_LIVE_PHYSICAL=1` のときだけ。usbmuxd → lockdown → TLS →
    // webinspector の全経路を実機で1回通す。CI では走らない。SimulatorCatalogCoreSimTests の
    // FT_LIVE_SIM と同じ作法)

    func testReadsDOMFromAConnectedPhysicalDevicesSafari() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FT_LIVE_PHYSICAL"] == "1",
                          "FT_LIVE_PHYSICAL=1 のときのみ(実機接続 + Safari 起動が前提)")
        guard let devices = try? IOSPhysicalDeviceCatalog.devices(), let device = devices.first(where: { $0.connected })
        else { throw XCTSkip("接続中の実機が無い") }

        let start = Date()
        let payload = await SafariWebInspector.read(physicalUDID: device.udid)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        guard let payload else {
            throw XCTSkip("DOM を取得できなかった(Safari 未起動・タブ無し・未ペアリングのいずれか。"
                          + "\(device.name) / \(device.udid), \(elapsedMs)ms)")
        }
        let nodeCount = payload.nodes?.count ?? 0
        print("fleetest [live physical]: \(device.name) (\(device.udid)) から DOM を読めた — "
              + "\(nodeCount) nodes, \(elapsedMs)ms")
        XCTAssertGreaterThan(nodeCount, 0)
    }

    // MARK: - 実機の分割送信(1通が大きいと黙って捨てられる)

    /// フレーム長は「ソース長 × 一定」ではない(JSON エスケープの膨張率が場所で違う)。
    /// 実測を模した非線形なコストで、**どの式も予算を超えない**ことを見る
    private func nonlinearFrameSize(_ expression: String) -> Int {
        let quotes = expression.filter { $0 == "\"" }.count
        return expression.utf8.count + quotes * 3 + 500
    }

    func testSplitsSoThatEveryMessageFitsTheBudget() throws {
        let js = String(repeating: "var x = \"あいう\"; // コメント\n", count: 200)
        let budget = 2000
        let parts = try XCTUnwrap(SafariWebInspector.assemblyExpressions(
            javaScript: js, budget: budget, frameSize: nonlinearFrameSize))
        XCTAssertGreaterThan(parts.count, 1, "この大きさなら1通には収まらないはず")
        for part in parts {
            XCTAssertLessThanOrEqual(nonlinearFrameSize(part), budget, "予算を超える通が混ざった")
        }
    }

    /// **積み直したら元と1文字も違わないこと**。共有 JS を壊すと OS 間で木が食い違う
    func testTheChunksReassembleIntoTheOriginalSource() throws {
        let js = "if (a > 1 && b < 2) { s = \"引用符\\\\と改行\\n\"; } // 日本語コメント"
        let parts = try XCTUnwrap(SafariWebInspector.assemblyExpressions(
            javaScript: js, budget: 700, frameSize: nonlinearFrameSize))
        var rebuilt = ""
        for part in parts {
            let literal = String(part.dropFirst(part.hasPrefix("globalThis.__ftSrc=") ? 19 : 20).dropLast(5))
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(("[" + literal + "]").utf8)) as? [String])
            rebuilt += try XCTUnwrap(decoded.first)
        }
        XCTAssertEqual(rebuilt, js)
    }

    /// 1通目は代入、2通目以降は追記(全部代入だと最後の塊しか残らない)
    func testFirstChunkAssignsAndTheRestAppend() throws {
        let parts = try XCTUnwrap(SafariWebInspector.assemblyExpressions(
            javaScript: String(repeating: "abcdefghij", count: 300), budget: 900,
            frameSize: nonlinearFrameSize))
        XCTAssertTrue(parts[0].hasPrefix("globalThis.__ftSrc="))
        for part in parts.dropFirst() { XCTAssertTrue(part.hasPrefix("globalThis.__ftSrc+=")) }
    }

    /// 予算が小さすぎて1文字も載らないなら**組み立て不能を返す**(黙って壊れた式を送らない)
    func testImpossibleBudgetIsRefused() {
        XCTAssertNil(SafariWebInspector.assemblyExpressions(
            javaScript: "abc", budget: 10, frameSize: nonlinearFrameSize))
    }

    /// 実行式は**後片付けまでする**(残すと次の読みが前回の残骸へ足す)
    func testTheRunExpressionCleansUpTheGlobal() {
        XCTAssertTrue(SafariWebInspector.assemblyRunExpression.contains("delete globalThis.__ftSrc"))
        XCTAssertTrue(SafariWebInspector.assemblyRunExpression.contains("eval"))
    }

    /// **測った境界のギリギリを狙わない**(実測で境界が約600バイト揺れた)。
    /// 予算は降順で、最小でも実測の最小境界 7917 に対して余裕があること
    func testBudgetsAreOrderedAndConservative() {
        XCTAssertEqual(SafariWebInspector.messageBudgets, [7000, 4000])
        XCTAssertLessThan(SafariWebInspector.messageBudgets[0], 7917, "実測の最小境界を超えている")
        XCTAssertGreaterThan(SafariWebInspector.messageBudgets[0],
                             SafariWebInspector.messageBudgets[1], "退避は小さいほうへ")
    }

    // MARK: - 人が直せる原因を名指しする

    private let safariApp = ["PID:1": ["WIRApplicationBundleIdentifierKey": "com.apple.mobilesafari"]]
    private let daemons = ["PID:2": ["WIRApplicationBundleIdentifierKey": "com.apple.fitcored"],
                           "PID:3": ["WIRApplicationBundleIdentifierKey": "com.apple.email.maild"]]

    /// 握手すら通らない = 実機で Web インスペクタが無効(実測の形)
    func testRefusedHandshakeNamesTheWebInspectorSetting() throws {
        let hint = try XCTUnwrap(SafariWebInspector.inspectorHint(handshakeRefused: true, apps: [:]))
        XCTAssertTrue(hint.contains("Web Inspector"), hint)
        XCTAssertTrue(hint.contains("Settings"), "どこを触ればよいか言うこと: \(hint)")
    }

    /// 他のアプリは見えるのに Safari だけ居ない = 起動し直しが要る
    func testMissingSafariAsksForARelaunch() throws {
        let hint = try XCTUnwrap(SafariWebInspector.inspectorHint(handshakeRefused: false, apps: daemons))
        XCTAssertTrue(hint.lowercased().contains("relaunch"), hint)
    }

    /// **Safari が居るときは黙る**(毎回出ると読み飛ばされる)
    func testNoHintWhenSafariIsPresent() {
        XCTAssertNil(SafariWebInspector.inspectorHint(handshakeRefused: false, apps: safariApp))
        XCTAssertNil(SafariWebInspector.inspectorHint(handshakeRefused: false,
                                                     apps: daemons.merging(safariApp) { a, _ in a }))
    }

    /// **一覧が空のときは何も言わない** —— 単に Safari 未起動・接続前で、
    /// 「起動し直せ」は的外れ(誤った助言は無いより悪い)
    func testNoHintWhenNothingWasSeenAtAll() {
        XCTAssertNil(SafariWebInspector.inspectorHint(handshakeRefused: false, apps: [:]))
    }
}
