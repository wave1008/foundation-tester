// セッション記憶の**記録が driver() の2経路(新規生成・キャッシュ命中)の両方で起きる**ことを固定する。
//
// 2026-08-12 の実アプリ監査で踏んだ実バグ: 記録がドライバ生成の直後にだけ書かれており、
// キャッシュ命中の早期 return がそれを飛ばしていた。結果、**同じ機を2度目に明示した呼び出しは
// 記憶を動かさず**、A→B→A と触ったあとの省略呼び出しが B へ行く。実害は「iOS を明示 launch した
// 直後の無指定 ft_snapshot が Android のツリーを返す」= 黙って別 OS の機を操作する沈黙する誤り。
//
// MCPSessionDeviceMemoryTests は純粋述語(iosMemoryAfterResolve 等)だけを見ており、
// **述語は全部正しいまま**このバグが成立した — 配線を通すテストが要る。

import XCTest
@testable import ftester_mcp

final class MCPSessionMemoryCacheHitTests: XCTestCase {

    private func server() -> MCPServer { MCPServer(write: { _ in }) }

    // MARK: - 記録点(rememberResolvedTarget)の振る舞い

    /// A(iOS)→ B(Android)→ A(iOS) と明示したら、記憶は最後の A を指す。
    /// **2度目の A がキャッシュ命中でも同じ**でなければならない(これが壊れていた)
    func testThirdCallReclaimsPlatformEvenThoughItRepeatsTheFirstTarget() {
        let s = server()
        s.rememberResolvedTarget(platform: "ios", args: ["udid": "AAA"],
                                 iosPort: 8123, iosUDID: "AAA", androidSerial: nil)
        s.rememberResolvedTarget(platform: "android", args: ["serial": "emulator-5554"],
                                 iosPort: nil, iosUDID: nil, androidSerial: "emulator-5554")
        XCTAssertEqual(s.lastExplicitPlatform, "android")

        // キャッシュ命中の再訪(driver() が early return する経路が渡す形)
        s.rememberResolvedTarget(platform: "ios", args: ["udid": "AAA"],
                                 iosPort: 8123, iosUDID: "AAA", androidSerial: nil)
        XCTAssertEqual(s.lastExplicitPlatform, "ios",
                       "2度目の明示がキャッシュ命中でも platform の記憶を取り戻すこと")
        XCTAssertEqual(s.lastExplicitIOSTarget?.port, 8123)
    }

    /// 無指定呼び出しは記憶を汚さない(キャッシュ命中経路でも述語は同じ規律で効く)
    func testOmittedCallDoesNotRecordOnTheCachedPath() {
        let s = server()
        s.rememberResolvedTarget(platform: "android", args: ["serial": "emulator-5554"],
                                 iosPort: nil, iosUDID: nil, androidSerial: "emulator-5554")
        s.rememberResolvedTarget(platform: "ios", args: [:],
                                 iosPort: 8123, iosUDID: "AAA", androidSerial: nil)
        XCTAssertEqual(s.lastExplicitPlatform, "android", "自動解決は記憶を乗っ取らない")
        XCTAssertNil(s.lastExplicitIOSTarget)
    }

    /// fold が注入した宛先(deviceFromMemoryKey 付き)は記録しない —— ここを通すと、
    /// port 再利用で別デバイスに化けたとき記憶が黙って乗り換わる
    func testInjectedFromMemoryIsNotRecorded() {
        let s = server()
        s.rememberResolvedTarget(
            platform: "ios", args: ["port": 8123, MCPServer.deviceFromMemoryKey: true],
            iosPort: 8123, iosUDID: "AAA", androidSerial: nil)
        XCTAssertNil(s.lastExplicitPlatform)
        XCTAssertTrue(s.seenExplicitIOSPorts.isEmpty)
    }

    /// 延べ集合(曖昧さ判定の材料)もキャッシュ命中で積まれる —— ここが漏れると
    /// 「2台触ったのに1台しか触っていない」ことになり、曖昧なのに注記が黙る
    func testSeenSetsAccumulateAcrossRepeatedExplicitCalls() {
        let s = server()
        s.rememberResolvedTarget(platform: "ios", args: ["port": 8123],
                                 iosPort: 8123, iosUDID: "AAA", androidSerial: nil)
        s.rememberResolvedTarget(platform: "ios", args: ["port": 8125],
                                 iosPort: 8125, iosUDID: "BBB", androidSerial: nil)
        s.rememberResolvedTarget(platform: "ios", args: ["port": 8123],
                                 iosPort: 8123, iosUDID: "AAA", androidSerial: nil)
        XCTAssertEqual(s.seenExplicitIOSPorts, [8123, 8125])
        XCTAssertEqual(s.lastExplicitIOSTarget?.port, 8123)
    }

    /// iOS の記録には port が要る(キャッシュ命中経路は connectedPorts から採る)。
    /// 採れなかったら**記録しない**(古い記憶を残す)——「port 不明のまま platform だけ
    /// 動かす」と、行き先が決まらないのに platform だけ乗り換わって最悪の状態になる
    func testIOSWithoutAResolvedPortRecordsNothing() {
        let s = server()
        s.rememberResolvedTarget(platform: "android", args: ["serial": "emulator-5554"],
                                 iosPort: nil, iosUDID: nil, androidSerial: "emulator-5554")
        s.rememberResolvedTarget(platform: "ios", args: ["udid": "AAA"],
                                 iosPort: nil, iosUDID: "AAA", androidSerial: nil)
        XCTAssertEqual(s.lastExplicitPlatform, "android")
    }

    // MARK: - 配線(driver() のキャッシュ命中枝が記録点を呼ぶか)

    /// **ソース走査**: キャッシュ命中の早期 return が記録点を通ることを固定する。
    /// driver() のこの枝は makeDriver 注入がもっと手前で短絡するため実行では踏めない
    /// (注入ドライバはキャッシュ自体を使わない)。踏めない枝の退行はソースで止める
    /// —— 元のバグはまさに「早期 return が記録を飛ばす」形だった
    func testCachedDriverBranchCallsTheRecorder() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ftester-mcp/MCPServer+Driver.swift"),
            encoding: .utf8)
        // `if let cached = drivers[key] {` … `return cached` の間に記録点があること。
        // profile 経由の枝(こちらは記憶を持たない)と混ざらないよう、platform 版の
        // キャッシュ判定 = `explicitPort` を鍵に組み立てた後ろの1つを見る
        let marker = "let key = Self.driverCacheKey(platform: platform"
        let start = try XCTUnwrap(source.range(of: marker), "キャッシュ鍵の組み立てが見つからない")
        let tail = source[start.upperBound...]
        let cachedBranch = try XCTUnwrap(tail.range(of: "if let cached = drivers[key]"),
                                         "platform 経路のキャッシュ命中枝が見つからない")
        let afterBranch = tail[cachedBranch.upperBound...]
        let returnCached = try XCTUnwrap(afterBranch.range(of: "return cached"))
        let body = afterBranch[..<returnCached.lowerBound]
        XCTAssertTrue(body.contains("rememberResolvedTarget"),
                      "キャッシュ命中で早期 return する前にセッション記憶を更新すること"
                      + "(飛ばすと A→B→A の後の省略呼び出しが B へ行く)")
    }

    /// 記録点が1箇所に集約されたままであること(生成側にインライン展開が戻っていない)。
    /// 2箇所に分かれると、片方だけ直した回に同じバグが復活する
    func testMemoryIsWrittenOnlyThroughTheSharedRecorder() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ftester-mcp/MCPServer+Driver.swift"),
            encoding: .utf8)
        let assignments = source.components(separatedBy: "lastExplicitPlatform = ").count - 1
        XCTAssertEqual(assignments, 2,
                       "lastExplicitPlatform の代入は rememberResolvedTarget 内の ios/android 各1回だけ")
    }
}
