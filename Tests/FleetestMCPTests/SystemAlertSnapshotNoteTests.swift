// SpringBoard の許可アラートを ft_snapshot / ft_tap で名指しできることの検証(欠陥⑨)。
// ft_launch 後に SpringBoard のアラートがアプリを覆っても、既存の ft_snapshot はアプリ自身の
// 木(エラー画面等)を注記なしで返し、エージェントは ft_screenshot を撮って初めて気付いていた。
// systemAlertProbePending(MCPServer.swift)が launch 系ツールの直後にだけ1回、次の
// ft_snapshot で GET /systemalert を確かめるようにした(DSL の noteAppLaunched と同じ設計)。

import XCTest
import FTCore
@testable import fleetest_mcp

private func combinedText(_ content: [[String: Any]]) -> String {
    content.compactMap { $0["text"] as? String }.joined()
}

final class SystemAlertSnapshotNoteTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    /// 手で書いた期待文言(production の文字列を呼んで作らない)。
    /// タイトル・ボタンは受け手報告の実例(実機 iPhone 13・ローカルネットワークアラート)
    private static let expectedNote =
        "note: a system alert (「“SUT Store”がローカルネットワーク上のデバイスを見つけることを"
        + "許可しますか?」, buttons: 「許可しない」 / 「許可」) is in front of the app — the tree"
        + " below is the app behind it; nothing in it is reachable and the alert is drawn by"
        + " SpringBoard so it never appears here. Read it with"
        + " `ft_launch bundleId: com.apple.springboard`, tap its button by ref,"
        + " then `ft_launch` your app again."

    /// ft_launch の直後、最初の ft_snapshot はアラートを名指しする
    func testFirstSnapshotAfterLaunchCarriesTheAlertNote() async throws {
        driver.scriptedSystemAlert = SystemAlertProbeResponse(
            present: true,
            title: "“SUT Store”がローカルネットワーク上のデバイスを見つけることを許可しますか?",
            buttons: ["許可しない", "許可"])
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        let first = try await server.call(tool: "ft_snapshot", args: [:])
        XCTAssertTrue(combinedText(first).contains(Self.expectedNote), combinedText(first))
    }

    /// 一度読んだら消費され、2回目の ft_snapshot には出ない。probe 自体も1回しか撃たれない
    /// (登録があるからといって毎回 /systemalert を往復させない)
    func testSecondSnapshotDoesNotRepeatTheNoteAndProbesOnlyOnce() async throws {
        driver.scriptedSystemAlert = SystemAlertProbeResponse(
            present: true, title: "位置情報の利用を許可しますか?", buttons: ["許可", "許可しない"])
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        let first = try await server.call(tool: "ft_snapshot", args: [:])
        XCTAssertTrue(combinedText(first).contains("note: a system alert"), combinedText(first))

        let second = try await server.call(tool: "ft_snapshot", args: [:])
        XCTAssertFalse(combinedText(second).contains("note: a system alert"), combinedText(second))

        XCTAssertEqual(driver.calls.filter { $0 == "systemAlert" }.count, 1,
                       "\(driver.calls)")
    }

    /// present: false は沈黙する(黙って消費だけはする)
    func testAbsentAlertStaysSilent() async throws {
        driver.scriptedSystemAlert = SystemAlertProbeResponse(present: false)
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        let first = try await server.call(tool: "ft_snapshot", args: [:])
        XCTAssertFalse(combinedText(first).contains("system alert"), combinedText(first))
    }

    /// 答えられない(nil。旧ブリッジ・in-app・Android)ときも沈黙する
    func testNilProbeStaysSilent() async throws {
        driver.scriptedSystemAlert = nil
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        let first = try await server.call(tool: "ft_snapshot", args: [:])
        XCTAssertFalse(combinedText(first).contains("system alert"), combinedText(first))
    }

    /// springboard 自身への ft_launch はアラートを読みに行く正規の経路なので立てない
    func testLaunchingSpringboardDoesNotArmTheProbe() async throws {
        driver.scriptedSystemAlert = SystemAlertProbeResponse(
            present: true, title: "何かのアラート", buttons: ["OK"])
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.apple.springboard"])
        let first = try await server.call(tool: "ft_snapshot", args: [:])
        XCTAssertFalse(combinedText(first).contains("system alert"), combinedText(first))
        XCTAssertFalse(driver.calls.contains("systemAlert"), "\(driver.calls)")
    }
}

// MARK: - HybridFallbackDriver の配線ゲート

/// **hybrid の systemAlert/systemUICovering は常に XCUITest 側(fallback)へ聞くこと**。
/// `active` に乗せると、通常時(delegating == false)は in-app(primary)側に落ち、
/// InAppDriver は常に nil を返すので既定プロファイル(hybrid)では SpringBoard のアラートが
/// 一生見えなくなる(2026-08-31 実機 iPhone 13 で報告された欠陥そのもの)。
/// コンパイラは「nil を返す型に委譲した」ことを止められないので、ソース走査で縛る。
final class HybridFallbackDriverSystemAlertWiringTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/FleetestMCPTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // リポジトリ直下

    private func source() throws -> String {
        try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Sources/FTBridgeClient/HybridFallbackDriver.swift"),
            encoding: .utf8)
    }

    /// 1行だけ抜き出す(次の `public func` 直前まで)。複数行に折り返されていても拾えるように、
    /// 空白・改行を落として比較する
    private func body(of signature: String, in text: String) throws -> String {
        guard let start = text.range(of: signature) else {
            throw XCTSkip("\(signature) が見つからない — 改名したらこのテストも直す")
        }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n    public func") ?? rest.range(of: "\n    public var")
        let slice = end.map { rest[rest.startIndex..<$0.lowerBound] } ?? rest
        return slice.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    func testSystemAlertDoesNotDelegateThroughActive() throws {
        let text = try source()
        let line = try body(of: "public func systemAlert() async throws -> SystemAlertProbeResponse? {",
                            in: text)
        XCTAssertFalse(line.contains("active."), "systemAlert() が active 経由に戻っている: \(line)")
        XCTAssertTrue(line.contains("fallback.systemAlert()"), line)
    }

    func testSystemUICoveringDoesNotDelegateThroughActive() throws {
        let text = try source()
        let line = try body(
            of: "public func systemUICovering() async throws -> SystemUICoveringResponse? {",
            in: text)
        XCTAssertFalse(line.contains("active."), "systemUICovering() が active 経由に戻っている: \(line)")
        XCTAssertTrue(line.contains("fallback.systemUICovering()"), line)
    }
}
