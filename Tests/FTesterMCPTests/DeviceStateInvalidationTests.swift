// engineKey に紐づく状態の後始末(2026-08-13)。
//
// engineKey は `direct:ios:<port>:<serial>` で、iOS のポートは同じセッション中に動く
// (監視が別ポートで建て直す)。つまり死んだポートが後で別のシミュレータに再利用され得る。
// forgetConnection が drivers/connections/connectedPorts しか消していなかったので、
// lastSnapshots・refGenerations・launchedBundleIDs は**前の機のもの**が生き残り、
// 古い ref が別の機の木を起点に解決され、ft_open_url が前の機のアプリへ配送していた。
//
// 出力がずれるだけの記憶と違い、これは**操作が別物へ届く型**なので、この後始末は
// 「全部捨てる。ただし nextRefBase だけは残す」を不変条件として固定する。

import XCTest
import FTCore
@testable import ftester_mcp

final class DeviceStateInvalidationTests: XCTestCase {

    private let key = "direct:ios:8128:"

    private func serverWithFullStateForKey() -> MCPServer {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        let snapshot = SnapshotResponse(
            sessionBundleID: "com.example.old",
            screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [ElementInfo(ref: 1, type: "button", identifier: nil, label: "OK",
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 1)],
            truncatedCount: 0)
        server.drivers[key] = FakeDriver()
        server.connections[key] = "port 8128"
        server.connectedPorts[key] = 8128
        server.engines[key] = "inapp"
        server.udids[key] = "AAA"
        server.versionSkew[key] = "mismatch"
        server.lastSnapshots[key] = snapshot
        server.refGenerations[key] = [(base: 100, snapshot: snapshot)]
        server.nextRefBase = 200
        server.launchedBundleIDs[key] = "com.example.old"
        server.uiFrameworkHints[key] = "compose"
        server.lastScreenshots[key] = StaleFrameDetector.Record(imageHash: 1, treeFingerprint: 2)
        server.rememberedSnapshotFilters[key] = ["interactiveOnly": true]
        server.sheetRescueFutile[key] = ["fingerprint"]
        server.pendingWarnings[key] = ["stale warning"]
        return server
    }

    /// **操作が別物へ届く型の記憶が1つでも残らないこと**。ref の起点(lastSnapshots /
    /// refGenerations)と ft_open_url の既定(launchedBundleIDs)がここでの本命
    func testForgetConnectionDropsEveryMemoThatCanMisdirectAnAction() {
        let server = serverWithFullStateForKey()

        server.forgetConnection(key)

        XCTAssertNil(server.drivers[key])
        XCTAssertNil(server.lastSnapshots[key], "古い木が残ると ref が別の機の要素へ解決される")
        XCTAssertNil(server.refGenerations[key], "古い ref 世代が残ると番号一致で別要素に当たる")
        XCTAssertNil(server.launchedBundleIDs[key],
                     "前の機で起動したアプリが残ると ft_open_url がそこへ配送する")
        XCTAssertNil(server.udids[key] ?? nil)
        XCTAssertNil(server.engines[key])
        XCTAssertNil(server.versionSkew[key])
        XCTAssertNil(server.uiFrameworkHints[key])
        XCTAssertNil(server.lastScreenshots[key])
        XCTAssertNil(server.rememberedSnapshotFilters[key])
        XCTAssertNil(server.sheetRescueFutile[key])
        XCTAssertNil(server.pendingWarnings[key])
        XCTAssertNil(server.connections[key])
        XCTAssertNil(server.connectedPorts[key])
    }

    /// **nextRefBase だけは残す**。0 へ戻すと捨てた世代と同じ base が新しい世代へ再配布され、
    /// 世代管理が防いでいる「番号は同じだが別要素」を後始末の側から作ってしまう
    func testNextRefBaseSurvivesSoRefsStayUniqueForTheWholeSession() {
        let server = serverWithFullStateForKey()

        server.forgetDeviceState(key)

        XCTAssertEqual(server.nextRefBase, 200,
                       "nextRefBase が巻き戻された — 捨てた世代の ref 番号が再配布される")
    }

    // MARK: - 同じキーが別の機を指し始めたかの判定(版ズレ拒否は drivers[key] しか消さないので、
    // ドライバ生成側でも同じ後始末を撃つ必要がある)

    func testKeyChangedDeviceReportsThePreviousUDIDOnlyWhenItActuallyChanged() {
        XCTAssertEqual(MCPServer.keyChangedDevice(previous: "AAA", now: "BBB"), "AAA")
        XCTAssertNil(MCPServer.keyChangedDevice(previous: "AAA", now: "AAA"))
    }

    /// **「分からない」を「変わった」と読まない** —— udid を採れない構成で毎回記憶が飛ぶ
    func testUnknownUDIDOnEitherSideIsNotTreatedAsAChange() {
        XCTAssertNil(MCPServer.keyChangedDevice(previous: nil, now: "BBB"),
                     "初回(前の udid が無い)を機の入れ替わりと読んだ")
        XCTAssertNil(MCPServer.keyChangedDevice(previous: "AAA", now: nil),
                     "udid を採れなかった回を機の入れ替わりと読んだ")
        XCTAssertNil(MCPServer.keyChangedDevice(previous: nil, now: nil))
    }

    /// 警告は**捨てたものを名指しする**(「何かが消えた」だけだと手元の ref を撃ち続ける)
    func testReusedPortWarningNamesBothDevicesAndWhatWasDropped() {
        let warning = MCPServer.reusedPortWarning(port: 8128, previousUDID: "AAA", nowUDID: "BBB")
        XCTAssertTrue(warning.contains("8128"), warning)
        XCTAssertTrue(warning.contains("AAA"), warning)
        XCTAssertTrue(warning.contains("BBB"), warning)
        XCTAssertTrue(warning.contains("ft_snapshot"), warning)
    }

    // MARK: - 同型の再発を落とす(足し忘れの検出)

    /// **engineKey で引く記憶を新設して forgetDeviceState へ足し忘れると落ちる**。
    /// この後始末は網羅が本体で、1つ漏れると「ほとんど捨てたが1つだけ前の機のまま」という
    /// 最も分かりにくい形になるので、人の注意力ではなくソース走査で守る。
    /// `nextRefBase` だけは**意図して残す**ので、ここに理由付きで明記する
    func testEveryEngineKeyedMemoIsAccountedForHere() throws {
        // 空でよい: `nextRefBase` は 2026-08-13 にセッション共通のスカラーへ変えたので、
        // engineKey で引く記憶ではなくなり、この走査(`[String: …]` 宣言)には掛からない
        let deliberatelyKept: [String] = []

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let declarations = try String(
            contentsOf: root.appendingPathComponent("Sources/ftester-mcp/MCPServer.swift"),
            encoding: .utf8)
        let body = try String(
            contentsOf: root.appendingPathComponent("Sources/ftester-mcp/MCPServer+Dispatch.swift"),
            encoding: .utf8)
        guard let purge = body.range(of: "func forgetDeviceState(_ key: String) {"),
              let end = body.range(of: "\n    }", range: purge.upperBound..<body.endIndex) else {
            return XCTFail("forgetDeviceState が見つからない — 改名したらこのテストも直す")
        }
        let purgeBody = String(body[purge.upperBound..<end.lowerBound])

        var missing: [String] = []
        for line in declarations.split(separator: "\n") {
            // engineKey で引く記憶はすべて `var <name>: [String: …]` の形
            guard line.hasPrefix("    var "), line.contains(": [String: ") else { continue }
            let name = String(line.dropFirst("    var ".count).prefix { $0 != ":" })
            guard !deliberatelyKept.contains(name),
                  !purgeBody.contains("\(name)[key] = nil") else { continue }
            missing.append(name)
        }
        XCTAssertEqual(missing, [],
                       "engineKey で引く記憶が forgetDeviceState で捨てられていない: "
                       + "\(missing.joined(separator: ", "))。"
                       + "キーが別の機を指し始めたときに前の機の値が残り、操作が別物へ届く")
    }

    /// 走査そのものが効いていることの確認(常に空を返す走査を「漏れ0」と読まないため)
    func testTheScanActuallySeesTheDeclarations() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let declarations = try String(
            contentsOf: root.appendingPathComponent("Sources/ftester-mcp/MCPServer.swift"),
            encoding: .utf8)
        let found = declarations.split(separator: "\n")
            .filter { $0.hasPrefix("    var ") && $0.contains(": [String: ") }
        XCTAssertGreaterThan(found.count, 10,
                             "宣言の書式が変わって走査が空振りしている(漏れを検出できない)")
    }

    /// 別のキーの状態は巻き込まない(1台の後始末が他の機の探索を壊さない)
    func testOtherKeysAreUntouched() {
        let server = serverWithFullStateForKey()
        let other = "direct:android:0:emulator-5554"
        server.launchedBundleIDs[other] = "com.example.other"
        server.drivers[other] = FakeDriver()

        server.forgetDeviceState(key)

        XCTAssertEqual(server.launchedBundleIDs[other], "com.example.other")
        XCTAssertNotNil(server.drivers[other])
    }

    // MARK: - キャッシュ命中のドライバの同一性(2026-08-13・軸②「ブリッジ建て直し」の監査で実機再現)

    /// **確認を払う呼び出しの見分け**。記憶に依存する形だけが「機が変わると黙って別物へ届く」
    func testOnlyCallsThatLeanOnRememberedStatePayForTheIdentityCheck() {
        // ref を持つ = 世代から引く
        XCTAssertTrue(MCPServer.usesRememberedDeviceState(["ref": 4]))
        // ft_batch は先頭ステップだけ ref を受ける
        XCTAssertTrue(MCPServer.usesRememberedDeviceState(["steps": "tap ref: 4; tap '#x'"]))
        // bundleId 省略の ft_open_url = 記憶した起動アプリへ配る
        XCTAssertTrue(MCPServer.usesRememberedDeviceState(["url": "https://example.com"]))

        // 記憶を使わない呼び出しには払わせない
        XCTAssertFalse(MCPServer.usesRememberedDeviceState([:]))
        XCTAssertFalse(MCPServer.usesRememberedDeviceState(["x": 10, "y": 20]))
        XCTAssertFalse(MCPServer.usesRememberedDeviceState(["selector": "#btn"]))
        XCTAssertFalse(MCPServer.usesRememberedDeviceState(["steps": "tap '#a'; tap '#b'"]))
        XCTAssertFalse(MCPServer.usesRememberedDeviceState(
            ["url": "https://example.com", "bundleId": "com.example.app"]))
    }

    /// 断り文は**捨てたものを名指しする** —— 「別の機だ」だけだと手元の ref を撃ち直す
    func testMovedDeviceRefusalNamesBothDevicesAndWhatWasDropped() {
        let message = MCPServer.movedDeviceRefusal(port: 8123, previousUDID: "AAA", nowUDID: "BBB")
        XCTAssertTrue(message.contains("8123"), message)
        XCTAssertTrue(message.contains("AAA"), message)
        XCTAssertTrue(message.contains("BBB"), message)
        XCTAssertTrue(message.contains("ft_snapshot"), message)
    }

    /// ポートが分からないときも文が壊れない(記憶を消した後に組み立てても同じ)
    func testMovedDeviceRefusalWithoutAPortStillReads() {
        let message = MCPServer.movedDeviceRefusal(port: nil, previousUDID: "AAA", nowUDID: "BBB")
        XCTAssertFalse(message.contains("port "), message)
        XCTAssertTrue(message.contains("AAA"), message)
    }

    // MARK: - 掃討の網羅(2026-08-13): 片方の経路にだけ確認を入れると、その経路の利用者にだけ穴が残る

    /// **ドライバのキャッシュ命中は2箇所ある**(profile 経路と直接ポート経路)。
    /// 2026-08-13 に直接ポート側だけへ確認を入れ、**profile 側を取りこぼした**。
    /// 新しいキャッシュ命中を足したときも落ちるよう、ソース走査で網羅を守る
    func testEveryDriverCacheHitVerifiesDeviceIdentity() throws {
        let source = try String(contentsOf: Self.driverSourceURL(), encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var hits = 0
        for (index, line) in lines.enumerated() where line.contains("if let cached = drivers[key]") {
            hits += 1
            // 命中ブロックの中(次の 12 行以内)で確認を呼んでいること
            let window = lines[index..<min(index + 12, lines.count)].joined(separator: "\n")
            XCTAssertTrue(window.contains("deviceIdentityChanged"),
                          "\(index + 1) 行目のキャッシュ命中が同一性を確かめていない —— "
                          + "この経路の利用者にだけ、機が変わっても古い ref が通る穴が残る")
        }
        XCTAssertEqual(hits, 2,
                       "キャッシュ命中の箇所数が変わった(実測 \(hits))。増えたなら確認も入れる")
    }

    /// **ガードが動くのに必要な材料を、両経路とも記録していること**。
    /// `deviceIdentityChanged` は `udids` と `connectedPorts` が揃ったときだけ動くので、
    /// 片方を書き忘れると**確認を呼んでいるのに黙って no-op** になる(今日踏んだ形)
    func testBothPathsRecordWhatTheIdentityGuardNeeds() throws {
        let source = try String(contentsOf: Self.driverSourceURL(), encoding: .utf8)
        XCTAssertTrue(source.contains("connectedPorts[key] = provisioned.port"),
                      "profile 経路が connectedPorts を記録していない —— ガードが常に no-op になる")
        XCTAssertTrue(source.contains("udids[key] = provisioned.udid"),
                      "profile 経路が udid を記録していない")
        XCTAssertTrue(source.contains("connectedPorts[key] = port"),
                      "直接ポート経路が connectedPorts を記録していない")
    }

    /// 材料が欠けているときは**何もしない**(誤って毎回記憶を捨てない)。
    /// no-op であること自体は正しいので、上の2本と対で意味を持つ
    func testIdentityGuardDoesNothingWithoutTheRecordedPort() async {
        let server = serverWithFullStateForKey()
        server.connectedPorts[key] = nil

        let verdict = await server.deviceIdentityChanged(key, args: ["ref": 1])

        XCTAssertNil(verdict)
        XCTAssertNotNil(server.refGenerations[key], "材料が無いのに記憶を捨てた")
    }

    private static func driverSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ftester-mcp/MCPServer+Driver.swift")
    }
}
