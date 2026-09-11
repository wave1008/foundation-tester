// ft_rotate の整定ループを固定本数(changeSettleRereads)から締め切り(RotationSettle.deadlineSeconds)
// へ変えた分の回帰(2026-08-31 G節)。旧予算は変化待ちの changeSettleRereads(3)×
// settleWaitSeconds(0.4s)=1.2秒を流用しており、実機 iPhone ではレイアウトが収まる前に尽きていた。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPRotateSettleTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
    }

    private static func text(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined()
    }

    private let screen = FTRect(x: 0, y: 0, width: 390, height: 844)

    /// 回転直後: レイアウトはまだ旧向きのまま(画面の外へはみ出す frame)
    private func midRelayout() -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: "com.example.app", screen: screen,
            elements: [ElementInfo(ref: 1, type: "other", identifier: "screen_root", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 844, height: 390), depth: 1)],
            truncatedCount: 0)
    }

    /// 新しい向きに収まっている
    private func settled() -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: "com.example.app", screen: screen,
            elements: [ElementInfo(ref: 1, type: "other", identifier: "screen_root", label: nil,
                                   value: nil, placeholder: nil, enabled: true,
                                   frame: FTRect(x: 0, y: 0, width: 390, height: 844), depth: 1)],
            truncatedCount: 0)
    }

    /// **旧固定3回の予算では届かない整定が、締め切り予算(既定 `RotationSettle.deadlineSeconds`)
    /// なら収まる**。5枚(初回読み+4回の再読み)で「未整定×3 → 変化中 → 2回連続で settled」に
    /// 到達する —— 旧 `changeSettleRereads`(3)は3回しか読まないので、ここへ届く前に諦めていた
    func testSettlesWithinTheDeadlineWhereTheOldFixedBudgetWouldHaveGivenUp() async throws {
        driver.scriptedSnapshots = [midRelayout(), midRelayout(), midRelayout(), settled(), settled()]

        let result = try await server.call(tool: "ft_rotate", args: ["orientation": "landscape"])

        XCTAssertFalse(Self.text(result).contains("did not settle within the check budget"),
                       Self.text(result))
        XCTAssertEqual(driver.calls.filter { $0 == "snapshot" }.count, 5, "\(driver.calls)")
    }

    /// **cap(締め切り ÷ 間隔)が無いと、一度も整定しないドライバでループが止まらない**。
    /// `rotationSettleDeadlineSeconds = 0` で cap を0本にし、実際に眠らせずに
    /// 「未整定」の注記へ即座に落とせることを確かめる
    func testNeverSettlingStaysWithinTheCapAndCaveats() async throws {
        server.rotationSettleDeadlineSeconds = 0
        driver.scriptedSnapshots = [midRelayout(), midRelayout(), midRelayout()]

        let result = try await server.call(tool: "ft_rotate", args: ["orientation": "landscape"])

        XCTAssertTrue(Self.text(result).contains("did not settle within the check budget"),
                      Self.text(result))
        // cap 0本 = 初回の1回しか読まない(眠らない・回らない)
        XCTAssertEqual(driver.calls.filter { $0 == "snapshot" }.count, 1, "\(driver.calls)")
    }

    /// **iOS(Android でないドライバ)は portrait へ戻しても復元しない**:
    /// `restoreOrientationIfNeeded` は Android では「auto-rotate 設定を戻すだけ」で無害だが、
    /// iOS の `FTBridgeClient.BridgeClient` では「rotate 前の向きへ実際に回転し直す」実装なので、
    /// 明示的に `ft_rotate portrait` した直後にこれを呼ぶと、その場で(元の向きが landscape なら)
    /// 横へ戻ってしまう。この経路は Android のときだけ呼ぶ(`FakeDriver` は AndroidDriver では
    /// ないので、portrait へ戻ってもここでは一度も呼ばれないことを確かめる)
    func testDoesNotRestoreOrientationForNonAndroidDriversEvenAtPortrait() async throws {
        server.rotationSettleDeadlineSeconds = 0

        let landscapeResult = try await server.call(tool: "ft_rotate", args: ["orientation": "landscape"])
        XCTAssertFalse(driver.calls.contains("restoreOrientationIfNeeded"),
                       "横向きのままなのに戻してしまった: \(driver.calls)")
        XCTAssertFalse(Self.text(landscapeResult).contains("Auto-rotate was restored"),
                       Self.text(landscapeResult))

        let portraitResult = try await server.call(tool: "ft_rotate", args: ["orientation": "portrait"])
        XCTAssertFalse(driver.calls.contains("restoreOrientationIfNeeded"),
                       "iOS 相当のドライバなのに portrait で戻してしまった(再発): \(driver.calls)")
        XCTAssertFalse(Self.text(portraitResult).contains("Auto-rotate was restored"),
                       Self.text(portraitResult))
    }

    /// **配線の確認**(`AndroidDriver` は FTAndroid 依存で FakeDriver からは模せないので、
    /// MCPProfilePlatformTests と同じソース走査で守る): portrait への復元呼び出しが
    /// `rotateDriver is AndroidDriver` を条件に持っていること。これを外す変異(常時呼ぶ形へ戻す)は
    /// 上のテストが落とすが、「Android だけ」という条件そのものが消えていないかはここで固定する
    func testRestoreCallIsGatedToAndroidInSource() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp/MCPServer+Dispatch.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("if settled == .portrait, rotateDriver is AndroidDriver {"),
                      "ft_rotate の復元呼び出しが Android 限定のままであること")
    }
}
