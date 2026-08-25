// 記憶した宛先が**失敗で消えた後**の省略呼び出し(`lostTargetFold`。2026-08-13 の監査
// 「セッションの形 = OS 跨ぎ」)。
//
// 実測した事故: ①port 8138 を明示して成功 → ②存在しない port 8999 を明示して失敗 →
// ③宛先を省いた呼び出しが**どちらでもない別のシミュレータ**へ黙って行った(ホーム画面が返った)。
// 記憶は解決時に書かれるので ② が 8138 を上書きし、失敗の後始末が 8999 を消して記憶を空にする。
// 空になると「まだ1台も指していないセッション」と同じ扱いになり、ブリッジ探索へ落ちる。
//
// 規則: **一度でも宛先を名指ししたセッションでは、省略呼び出しを探索へ落とさない**。

import XCTest
@testable import fleetest_mcp

final class LostTargetFoldTests: XCTestCase {

    private func server() -> MCPServer {
        MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
    }

    /// **まだ1台も名指ししていないセッションは今までどおり素通し**(探索で決めてよい)
    func testFreshSessionIsLeftToDiscovery() {
        let s = server()
        guard case .unchanged = s.foldInRememberedDevice([:]) else {
            return XCTFail("名指ししていないセッションで割り込んだ")
        }
    }

    /// **事故の再現形**: 記憶は消えたが、生き残りが1台 → そこへ戻す(探索へ落とさない)
    func testFallsBackToTheSurvivingTargetInsteadOfDiscovery() {
        let s = server()
        s.everNamedIOSTarget = true
        s.lastExplicitPlatform = "ios"
        s.seenExplicitIOSPorts = [8138]   // 8999 は forgetConnection が取り除いた後
        guard case .applied(let args, let note) = s.foldInRememberedDevice([:]) else {
            return XCTFail("生き残り1台へ戻していない(探索へ落ちる)")
        }
        XCTAssertEqual(args["port"] as? Int, 8138)
        XCTAssertEqual(args["platform"] as? String, "ios")
        XCTAssertTrue(note.contains("8138"), note)
    }

    /// 名指しした機が**全部**消えたら断る。探索へ落ちると、名指ししていない機を操作する
    func testRefusesWhenEveryNamedTargetIsGone() {
        let s = server()
        s.everNamedIOSTarget = true
        s.lastExplicitPlatform = "ios"
        s.seenExplicitIOSPorts = []
        guard case .ambiguous(let message) = s.foldInRememberedDevice([:]) else {
            return XCTFail("全滅したのに探索へ落ちた")
        }
        XCTAssertTrue(message.contains("no longer reachable"), message)
        XCTAssertTrue(message.contains("never named"), message)
    }

    /// 生き残りが2台以上なら、記憶があるときと同じく断る
    func testRefusesWhenSeveralNamedTargetsSurvive() {
        let s = server()
        s.everNamedIOSTarget = true
        s.lastExplicitPlatform = "ios"
        s.seenExplicitIOSPorts = [8138, 8140]
        guard case .ambiguous(let message) = s.foldInRememberedDevice([:]) else {
            return XCTFail("候補が2台あるのに1台へ流した")
        }
        XCTAssertTrue(message.contains("8138") && message.contains("8140"), message)
    }

    /// 宛先を明示した呼び出しには触らない
    func testExplicitTargetIsLeftUnchanged() {
        let s = server()
        s.everNamedIOSTarget = true
        s.lastExplicitPlatform = "ios"
        s.seenExplicitIOSPorts = [8138]
        guard case .unchanged = s.foldInRememberedDevice(["platform": "ios", "port": 9001]) else {
            return XCTFail("明示した宛先へ割り込んだ")
        }
    }

    /// Android も同じ規律(掃討)
    func testAndroidFallsBackToTheSurvivingSerial() {
        let s = server()
        s.everNamedAndroidTarget = true
        s.lastExplicitPlatform = "android"
        s.seenExplicitAndroidSerials = ["emulator-5556"]
        guard case .applied(let args, _) = s.foldInRememberedDevice([:]) else {
            return XCTFail("Android で生き残りへ戻していない")
        }
        XCTAssertEqual(args["serial"] as? String, "emulator-5556")
        XCTAssertEqual(args["platform"] as? String, "android")
    }

    func testAndroidRefusesWhenEveryNamedSerialIsGone() {
        let s = server()
        s.everNamedAndroidTarget = true
        s.lastExplicitPlatform = "android"
        s.seenExplicitAndroidSerials = []
        guard case .ambiguous = s.foldInRememberedDevice([:]) else {
            return XCTFail("Android で全滅したのに探索へ落ちた")
        }
    }

    /// **もう一方の OS を触っていたら、生き残りが1台でも断る**(platform も省略されている形)
    func testRefusesWhenTheOtherPlatformWasAlsoDriven() {
        let s = server()
        s.everNamedIOSTarget = true
        s.lastExplicitPlatform = "ios"
        s.seenExplicitIOSPorts = [8138]
        s.seenExplicitAndroidSerials = ["emulator-5556"]
        guard case .ambiguous(let message) = s.foldInRememberedDevice([:]) else {
            return XCTFail("OS を跨いでいるのに1台へ流した")
        }
        XCTAssertTrue(message.contains("Android"), message)
    }

    /// **記録側のテストを別に持つ**: 上のテストはフラグを手で立てているので、記録する行を
    /// 外す変異が生き残る(実際に生き残った)。`call()` 越しには確かめられない ——
    /// 差し替えドライバ(makeDriver)の経路は `rememberResolvedTarget` の手前で返るため。
    /// **フラグは `seenExplicit*` と同じ場所で同時に立つこと**を固定する(片方だけ動かせない)
    func testRecordingAnExplicitIOSTargetRaisesTheFlagWithTheSeenSet() {
        let s = server()
        XCTAssertFalse(s.everNamedIOSTarget)
        s.rememberResolvedTarget(platform: "ios", args: ["port": 8138],
                                 iosPort: 8138, iosUDID: nil, androidSerial: nil)
        XCTAssertTrue(s.everNamedIOSTarget, "明示した宛先でフラグが立っていない")
        XCTAssertEqual(s.seenExplicitIOSPorts, [8138])
    }

    func testRecordingAnExplicitAndroidTargetRaisesTheFlagWithTheSeenSet() {
        let s = server()
        XCTAssertFalse(s.everNamedAndroidTarget)
        s.rememberResolvedTarget(platform: "android", args: ["serial": "emulator-5556"],
                                 iosPort: nil, iosUDID: nil, androidSerial: "emulator-5556")
        XCTAssertTrue(s.everNamedAndroidTarget, "明示した serial でフラグが立っていない")
        XCTAssertEqual(s.seenExplicitAndroidSerials, ["emulator-5556"])
    }

    /// **記録は明示指定だけ**(自動注入では立たない)。ここが崩れると、探索で拾った機を
    /// 「名指しした」と数えて、以後の省略呼び出しがそこへ固定される
    func testAnInjectedTargetDoesNotRaiseTheFlag() {
        let s = server()
        s.rememberResolvedTarget(platform: "ios",
                                 args: ["port": 8138, MCPServer.deviceFromMemoryKey: true],
                                 iosPort: 8138, iosUDID: nil, androidSerial: nil)
        XCTAssertFalse(s.everNamedIOSTarget, "自動注入をユーザーの名指しとして数えている")
    }

    /// 断ったときはドライバに触れない(拒否が「撃った後で謝る」形になっていないこと)
    func testARefusedCallNeverReachesADevice() async throws {
        var made = 0
        let s = MCPServer(write: { _ in }, makeDriver: { _ in made += 1; return FakeDriver() },
                          recordSnapshot: { _, _, _ in })
        s.everNamedIOSTarget = true
        s.lastExplicitPlatform = "ios"
        s.seenExplicitIOSPorts = []
        do {
            _ = try await s.call(tool: "ft_snapshot", args: [:])
            XCTFail("拒否されるはずの呼び出しが通った")
        } catch {
            XCTAssertEqual(made, 0, "拒否したのにドライバを作った(= 機に触りに行った)")
        }
    }
}
