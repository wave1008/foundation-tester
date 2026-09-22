// `fleetest bridge down`(--port / --all)は run-lease/MCP の印を読まずにブリッジを止めていた
// (台帳 T4)。`api stop-device` 等は `DeviceBooter.deviceInUseRefusal` を通すのに、この経路だけ
// 通していなかったのが欠陥。`BridgeDownRefusal.decide` は --all をまとめて断るための純粋関数
// (--port は `DeviceBooter.deviceInUseRefusal` をそのまま使うので、ここでは単体扱いも
// decide に1要素の targets を渡して確かめる)。

import XCTest
@testable import fleetest
import FTAndroid

final class BridgeDownLeaseGateTests: XCTestCase {

    func testRefusesWhenARunHoldsTheDevice() throws {
        let message = try XCTUnwrap(BridgeDownRefusal.decide(
            targets: [(name: "iPhone 17 Pro", keys: ["UDID-1"])], force: false,
            runHolderPID: { _ in 4242 }, mcpHolderPID: { _ in nil }, selfPID: 100))
        XCTAssertTrue(message.contains("iPhone 17 Pro"), message)
        XCTAssertTrue(message.contains("4242"), message)
    }

    func testForceBypassesARunHeldDevice() {
        XCTAssertNil(BridgeDownRefusal.decide(
            targets: [(name: "iPhone 17 Pro", keys: ["UDID-1"])], force: true,
            runHolderPID: { _ in 4242 }, mcpHolderPID: { _ in nil }, selfPID: 100))
    }

    func testRefusesWithMCPWordingWhenAnMCPSessionHoldsTheDevice() throws {
        let message = try XCTUnwrap(BridgeDownRefusal.decide(
            targets: [(name: "iPhone 17 Pro", keys: ["UDID-1"])], force: false,
            runHolderPID: { _ in nil }, mcpHolderPID: { _ in 4242 }, selfPID: 100))
        XCTAssertTrue(message.contains("an MCP session"), message)
        XCTAssertFalse(message.contains("fleetest run"), "run が使用中とは言わない: \(message)")
    }

    func testUnresolvableKeysDoNotRefuse() {
        XCTAssertNil(BridgeDownRefusal.decide(
            targets: [(name: "iPhone 17 Pro", keys: [])], force: false,
            runHolderPID: { _ in 4242 }, mcpHolderPID: { _ in 4242 }, selfPID: 100))
    }

    func testSelfHeldLeaseDoesNotRefuse() {
        XCTAssertNil(BridgeDownRefusal.decide(
            targets: [(name: "iPhone 17 Pro", keys: ["UDID-1"])], force: false,
            runHolderPID: { _ in 100 }, mcpHolderPID: { _ in nil }, selfPID: 100))
    }

    // MARK: - --all 相当(複数台)

    func testAllRefusesTheWholeSweepWhenOnlyOneDeviceIsHeld() throws {
        let message = try XCTUnwrap(BridgeDownRefusal.decide(
            targets: [(name: "iPhone 17 Pro", keys: ["UDID-1"]), (name: "Pixel 9", keys: ["emulator-5554"])],
            force: false, runHolderPID: { $0 == "emulator-5554" ? 4242 : nil },
            mcpHolderPID: { _ in nil }, selfPID: 100))
        XCTAssertTrue(message.contains("Pixel 9"), message)
        XCTAssertTrue(message.contains("4242"), message)
        XCTAssertEqual(message.components(separatedBy: DeviceBooter.sweepRefusalHeading).count - 1, 1,
                       "見出しはちょうど1回: \(message)")
    }

    func testAllCombinesRunAndMCPHoldersUnderOneHeading() throws {
        let message = try XCTUnwrap(BridgeDownRefusal.decide(
            targets: [(name: "iPhone 17 Pro", keys: ["UDID-1"]), (name: "Pixel 9", keys: ["emulator-5554"])],
            force: false,
            runHolderPID: { $0 == "UDID-1" ? 4242 : nil },
            mcpHolderPID: { $0 == "emulator-5554" ? 4343 : nil }, selfPID: 100))
        XCTAssertTrue(message.contains("iPhone 17 Pro"), message)
        XCTAssertTrue(message.contains("Pixel 9"), message)
        // run の文に続くので2文目は大文字始まり(DeviceBooter.sentenceJoined)
        XCTAssertTrue(message.contains("An MCP session"), message)
        XCTAssertEqual(message.components(separatedBy: DeviceBooter.sweepRefusalHeading).count - 1, 1,
                       "run/MCP 両方が居ても見出しは1回だけ: \(message)")
    }

    func testAllForceBypassesEveryHolder() {
        XCTAssertNil(BridgeDownRefusal.decide(
            targets: [(name: "iPhone 17 Pro", keys: ["UDID-1"])], force: true,
            runHolderPID: { _ in 4242 }, mcpHolderPID: { _ in 4242 }, selfPID: 100))
    }

    func testAllDoesNotRefuseWithoutAnyHolder() {
        XCTAssertNil(BridgeDownRefusal.decide(
            targets: [(name: "iPhone 17 Pro", keys: ["UDID-1"]), (name: "Pixel 9", keys: ["emulator-5554"])],
            force: false, runHolderPID: { _ in nil }, mcpHolderPID: { _ in nil }, selfPID: 100))
    }

    // MARK: - 応答しないが待受しているポート(忙しいブリッジ)

    /// **鍵が引けないときに黙って止めない** —— /status が返らないのは「死んでいる」だけでなく
    /// 「駆動中で忙しい」でも起きる。後者を素通しすると走っている MCP / run を無言で壊す
    func testRefusesPortsThatListenButDidNotAnswer() {
        guard let refusal = BridgeDownRefusal.unresponsiveButBoundRefusal(
            ports: [8153], force: false, isBound: { $0 == 8153 }) else {
            return XCTFail("待受しているポートは断るべき")
        }
        XCTAssertTrue(refusal.contains("8153"), refusal)
        XCTAssertTrue(refusal.contains("--force"), refusal)
    }

    /// 待受もしていない = 止めるものが無い。ここで断ると**回復手段を奪う**ので通す
    func testDoesNotRefusePortsThatAreNotEvenListening() {
        XCTAssertNil(BridgeDownRefusal.unresponsiveButBoundRefusal(
            ports: [8153], force: false, isBound: { _ in false }))
    }

    /// `--force` は押し切れる(固まったブリッジを止める唯一の口を残す)
    func testForcePassesThrough() {
        XCTAssertNil(BridgeDownRefusal.unresponsiveButBoundRefusal(
            ports: [8153], force: true, isBound: { _ in true }))
    }

    /// 複数ポート(--all)は待受しているものだけを名指しする
    func testNamesOnlyTheListeningPorts() {
        guard let refusal = BridgeDownRefusal.unresponsiveButBoundRefusal(
            ports: [8123, 8153, 8154], force: false, isBound: { $0 != 8123 }) else {
            return XCTFail("待受しているポートは断るべき")
        }
        XCTAssertFalse(refusal.contains("8123"), refusal)
        XCTAssertTrue(refusal.contains("8153, 8154"), refusal)
    }

    // MARK: - 配線(CLI 側が判定を素通りさせていないか)

    func testDownImplementationCallsTheLeaseGate() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/Fleetest.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let downRange = code.range(of: "struct Down: AsyncParsableCommand"),
              let nextStruct = code.range(of: "\n    struct ", range: downRange.upperBound..<code.endIndex)
        else { return XCTFail("struct Down が見つからない") }
        let body = code[downRange.upperBound..<nextStruct.lowerBound]
        // **本数で固定する** —— 「1回でも呼んでいれば合格」にすると、3経路のうち1つから
        // 門が消えても別の経路の呼び出しが残って素通りする(android と --port が同じ関数を呼ぶ)
        XCTAssertEqual(body.components(separatedBy: "DeviceBooter.deviceInUseRefusal(").count - 1, 2,
                       "android と --port の2経路が DeviceBooter.deviceInUseRefusal を通す")
        XCTAssertEqual(body.components(separatedBy: "BridgeDownRefusal.decide(").count - 1, 1,
                       "--all の経路は BridgeDownRefusal.decide を通す")
        XCTAssertEqual(body.components(separatedBy: "throw ExitCode(1)").count - 1, 5,
                       "3経路の保持者チェック + iOS の2経路の「応答しないが待受している」チェック")
        // **応答しないポートを素通しさせない門も本数で固定する** —— `--port` と `--all` の
        // どちらから消えても、もう片方の呼び出しが残って素通りする
        XCTAssertEqual(
            body.components(separatedBy: "BridgeDownRefusal.unresponsiveButBoundRefusal(").count - 1, 2,
            "--port と --all の2経路が「応答しないが待受している」チェックを通す")
    }
}
