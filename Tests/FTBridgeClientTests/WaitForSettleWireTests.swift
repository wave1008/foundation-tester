// waitForSettle(`POST /waitForSettle`)のワイヤと、ドライバの層ごとの経路の固定。
// 全画面の撮影は XCUITest ランナー(v174〜)と Android(v100〜)だけが持ち、in-app は持たない(501)。
// 経路を取り違えると、in-app が毎回 501 を拾うだけで済む(遅いだけ)か、素通しの書き忘れが
// 既定実装の 501 に落ちて「どちらの経路でも未対応」になる。

import XCTest
@testable import FTBridgeClient
import FTCore

final class WaitForSettleWireTests: XCTestCase {

    private static let settled = #"{"settled":true,"elapsedMs":600,"frames":6}"#
    private static let request = WaitForSettleRequest(
        region: FTRect(x: 10, y: 20, width: 30, height: 40), quietMs: 700, timeoutMs: 9_000)

    private func client(_ stub: RecordingStubServer) -> BridgeClient {
        BridgeClient(port: stub.port, interactionTimeout: 5, sessionTimeout: 5)
    }

    // MARK: - BridgeClient のワイヤ

    /// パス・メソッドと、要求の全欄が本文に載ること(欄を落とすと比べる範囲や窓がブリッジの既定に化ける)
    func testPostsTheRequestToWaitForSettle() async throws {
        let stub = try RecordingStubServer(body: Self.settled)
        defer { stub.stop() }

        _ = try await client(stub).waitForSettle(Self.request, timeoutSeconds: 10)

        XCTAssertEqual(stub.paths, ["POST /waitForSettle"])
        let raw = try XCTUnwrap(stub.body(for: "POST /waitForSettle"))
        let sent = try JSONDecoder().decode(WaitForSettleRequest.self, from: Data(raw.utf8))
        XCTAssertEqual(sent, Self.request, "本文が要求と一致しない: \(raw)")
    }

    /// region == nil(画面全体)は欄ごと省かれて届き、そのまま nil に戻ること
    func testNilRegionTravelsAsWholeScreen() async throws {
        let stub = try RecordingStubServer(body: Self.settled)
        defer { stub.stop() }
        let whole = WaitForSettleRequest(region: nil, quietMs: 500, timeoutMs: 3_000)

        _ = try await client(stub).waitForSettle(whole, timeoutSeconds: 10)

        let raw = try XCTUnwrap(stub.body(for: "POST /waitForSettle"))
        let sent = try JSONDecoder().decode(WaitForSettleRequest.self, from: Data(raw.utf8))
        XCTAssertEqual(sent, whole)
        XCTAssertNil(sent.region)
    }

    func testDecodesUnsettledResponseWithLastChangeRegion() async throws {
        let stub = try RecordingStubServer(
            body: #"{"settled":false,"elapsedMs":1500,"frames":12,"lastChangeRegion":{"x":1,"y":2,"width":3,"height":4}}"#)
        defer { stub.stop() }

        let response = try await client(stub).waitForSettle(Self.request, timeoutSeconds: 10)

        XCTAssertEqual(response, WaitForSettleResponse(
            settled: false, elapsedMs: 1_500, frames: 12,
            lastChangeRegion: FTRect(x: 1, y: 2, width: 3, height: 4)))
    }

    func testDecodesResponseWithoutLastChangeRegion() async throws {
        let stub = try RecordingStubServer(body: #"{"settled":false,"elapsedMs":1500,"frames":12}"#)
        defer { stub.stop() }

        let response = try await client(stub).waitForSettle(Self.request, timeoutSeconds: 10)

        XCTAssertEqual(response, WaitForSettleResponse(settled: false, elapsedMs: 1_500, frames: 12))
        XCTAssertNil(response.lastChangeRegion)
    }

    // MARK: - HTTP の待ちは呼び手の timeoutSeconds

    /// interactionTimeout(0.3s)より長く待たされる応答でも、timeoutSeconds(10s)の間は待つこと。
    /// 固定予算で撃つと、静止を待っている最中に bridgeUnreachable を誤報する
    func testWaitsLongerThanTheInteractionBudgetWhenTimeoutSecondsIsLong() async throws {
        let stub = try RecordingStubServer(body: Self.settled, delaySeconds: 1.0)
        defer { stub.stop() }
        let shortBudget = BridgeClient(port: stub.port, timeoutSeconds: 30,
                                       interactionTimeout: 0.3, sessionTimeout: 0.3)

        let response = try await shortBudget.waitForSettle(Self.request, timeoutSeconds: 10)

        XCTAssertTrue(response.settled)
    }

    /// 逆向き: 他の予算(30s)が長くても、timeoutSeconds(0.5s)を過ぎたら切れること
    func testTimesOutAtTimeoutSecondsNotAtTheLongerBudgets() async throws {
        let stub = try RecordingStubServer(body: Self.settled, delaySeconds: 3.0)
        defer { stub.stop() }
        let longBudget = BridgeClient(port: stub.port, timeoutSeconds: 30,
                                      interactionTimeout: 30, sessionTimeout: 30)
        do {
            _ = try await longBudget.waitForSettle(Self.request, timeoutSeconds: 0.5)
            XCTFail("応答が 3 秒遅れるのに timeoutSeconds(0.5s)で切れなかった")
        } catch DriverError.bridgeUnreachable {
            // 期待どおり
        } catch {
            XCTFail("タイムアウトは bridgeUnreachable のはず: \(error)")
        }
    }

    // MARK: - InAppDriver は転送しない

    /// in-app は 501 を投げ、ブリッジへは 1 本も撃たない(撃つと in-app ブリッジは未知のルートで 404 を返し、
    /// 画面全体を撮れない構成が「ブリッジの不具合」に見える)。「直して」転送すると、ホストが XCUITest へ回す
    /// 経路(isEngineIncapable)が閉じる
    func testInAppDriverRefusesWithoutSendingARequest() async throws {
        let stub = try RecordingStubServer(body: Self.settled)
        defer { stub.stop() }
        let driver = InAppDriver(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                                 udid: "no-such-udid", port: stub.port)
        do {
            _ = try await driver.waitForSettle(Self.request, timeoutSeconds: 10)
            XCTFail("in-app は全画面を撮れないので 501 で断るはず(応答が返った)")
        } catch {
            XCTAssertTrue(DriverError.isEngineIncapable(error), "501 のはず: \(error)")
        }
        XCTAssertEqual(stub.paths, [], "in-app はブリッジへ転送してはいけない")
    }

    // MARK: - 包むドライバの経路

    /// hybrid: in-app(primary)を試さず最初から XCUITest 側(fallback)へ。primary に本物のクライアントを
    /// 置くので、primary を先に試す実装なら primary のスタブに届いてしまう。attach 側は ensureAttached を挟まない
    func testHybridFallbackSendsStraightToTheXCUITestSide() async throws {
        let primaryStub = try RecordingStubServer(body: Self.settled)
        let fallbackStub = try RecordingStubServer(body: Self.settled)
        defer { primaryStub.stop(); fallbackStub.stop() }
        let driver = HybridFallbackDriver(
            primary: client(primaryStub),
            fallback: AppAttachDriver(port: fallbackStub.port, host: BridgeEndpoint.loopbackHost,
                                      bundleID: "com.example.target", physicalUDID: nil))

        let response = try await driver.waitForSettle(Self.request, timeoutSeconds: 10)

        XCTAssertTrue(response.settled)
        XCTAssertEqual(primaryStub.paths, [], "primary(in-app)を試してはいけない")
        XCTAssertEqual(fallbackStub.paths, ["POST /waitForSettle"],
                       "fallback へ /waitForSettle だけを撃つこと(activate を挟まない)")
    }

    /// WebView 委譲: 通常画面(mode == normal)でも delegated(XCUITest)へ。screenDriver(= primary)へ送ると
    /// 毎回 501 を拾うだけになる
    func testWebViewDelegatingSendsToDelegatedEvenOnNormalScreens() async throws {
        let primaryStub = try RecordingStubServer(body: Self.settled)
        let delegatedStub = try RecordingStubServer(body: Self.settled)
        defer { primaryStub.stop(); delegatedStub.stop() }
        let driver = WebViewDelegatingDriver(
            primary: client(primaryStub),
            delegated: AppAttachDriver(port: delegatedStub.port, host: BridgeEndpoint.loopbackHost,
                                       bundleID: "com.example.target", physicalUDID: nil))

        let response = try await driver.waitForSettle(Self.request, timeoutSeconds: 10)

        XCTAssertTrue(response.settled)
        XCTAssertEqual(primaryStub.paths, [])
        XCTAssertEqual(delegatedStub.paths, ["POST /waitForSettle"])
    }

    /// 残りの包むドライバは base / client の /waitForSettle へそのまま届くこと
    /// (素通しの書き忘れは既定実装の 501 に落ちる = 例外で気付く)
    func testPassThroughWrappersReachTheWire() async throws {
        let wrappers: [(String, (RecordingStubServer) -> AppDriver)] = [
            ("SystemUIDriver", { SystemUIDriver(port: $0.port, host: BridgeEndpoint.loopbackHost, physicalUDID: nil) }),
            ("AppAttachDriver", { AppAttachDriver(port: $0.port, host: BridgeEndpoint.loopbackHost,
                                                  bundleID: "com.example.target", physicalUDID: nil) }),
            ("SessionRecoveryDriver", { SessionRecoveryDriver(base: self.client($0)) }),
            ("LaunchPreflightDriver", { LaunchPreflightDriver(base: self.client($0), udid: "no-such-udid") }),
            ("FastLaunchDriver", { FastLaunchDriver(base: self.client($0), udid: "no-such-udid") }),
        ]
        for (name, make) in wrappers {
            let stub = try RecordingStubServer(body: Self.settled)
            defer { stub.stop() }
            let response = try await make(stub).waitForSettle(Self.request, timeoutSeconds: 10)
            XCTAssertTrue(response.settled, name)
            XCTAssertEqual(stub.paths, ["POST /waitForSettle"], "\(name): \(stub.paths)")
        }
    }

    // MARK: - 転送し忘れの検出

    /// ジェスチャを素通しするクラスは waitForSettle も宣言していること(包むドライバを足した日に
    /// 書き忘れると、既定実装の 501 に黙って落ちる)。走査が空振りしていないことも数で確かめる。
    /// コメント行は落としてから探す(doc コメントに名前が出るだけで通らないように)
    func testEveryGestureForwardingDriverAlsoDeclaresWaitForSettle() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("Sources/FTBridgeClient")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var checked: [String] = []
        var missing: [String] = []
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            guard code.contains("func gesture(_ request: GestureRequest)") else { continue }
            checked.append(file.lastPathComponent)
            if !code.contains("func waitForSettle(") { missing.append(file.lastPathComponent) }
        }

        XCTAssertGreaterThanOrEqual(checked.count, 5, "走査が空振りしている(対象 \(checked))")
        XCTAssertTrue(missing.isEmpty, "gesture を素通しするのに waitForSettle が無い: \(missing)")
    }
}
