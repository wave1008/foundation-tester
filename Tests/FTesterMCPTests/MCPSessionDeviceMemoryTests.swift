// MCPServer が覚える「最後に明示された iOS/Android 宛先」の純粋判定
// (iosExplicitWithMemory/iosMemoryAfterResolve, androidExplicitWithMemory/androidMemoryAfterResolve)
// を、走査/デバイスなしで固定する。driver(_:) 自体はデバイス依存で単体テストしにくいため、
// 記憶の読み書きロジックだけを切り出してある(MCPServer+Driver.swift 参照)。

import XCTest
@testable import ftester_mcp

final class MCPSessionDeviceMemoryTests: XCTestCase {

    // MARK: - iOS: 使用側(iosExplicitWithMemory)

    /// 記憶が無ければ何も差し込まない(1: 初回・無指定は既定挙動のまま)
    func testIOSNoMemoryYetPassesThroughUnchanged() {
        let (explicit, used) = MCPServer.iosExplicitWithMemory(
            fromArgs: nil, argsOmittedTarget: true, remembered: nil)
        XCTAssertNil(explicit)
        XCTAssertNil(used)
    }

    /// 記憶があり、この呼び出しが完全に無指定なら記憶を使う(2)
    func testIOSFallsBackToRememberedTargetWhenFullyOmitted() {
        let (explicit, used) = MCPServer.iosExplicitWithMemory(
            fromArgs: nil, argsOmittedTarget: true, remembered: (port: 8123, udid: "AAA"))
        XCTAssertEqual(explicit, 8123)
        XCTAssertEqual(used?.port, 8123)
        XCTAssertEqual(used?.udid, "AAA")
    }

    /// この呼び出しが udid/port のどちらかを持っていれば記憶を割り込ませない
    /// (fromArgs が非 nil のとき。argsOmittedTarget が偽でも同じく通す)
    func testIOSDoesNotOverrideAnExplicitCall() {
        let (explicit, used) = MCPServer.iosExplicitWithMemory(
            fromArgs: 9999, argsOmittedTarget: false, remembered: (port: 8123, udid: "AAA"))
        XCTAssertEqual(explicit, 9999)
        XCTAssertNil(used)
    }

    // MARK: - iOS: 更新側(iosMemoryAfterResolve)

    /// 明示された呼び出しの後だけ記憶を更新する(解決後の具体値で)
    func testIOSMemoryUpdatesOnlyWhenArgsHadExplicitTarget() {
        let updated = MCPServer.iosMemoryAfterResolve(
            argsHadExplicitTarget: true, resolvedPort: 8126, resolvedUDID: "BBB")
        XCTAssertEqual(updated?.port, 8126)
        XCTAssertEqual(updated?.udid, "BBB")
    }

    /// 自動解決(無指定呼び出し)の結果は記憶を汚さない(4: 安全性の核)
    func testIOSMemoryDoesNotUpdateOnAutoResolvedCall() {
        let updated = MCPServer.iosMemoryAfterResolve(
            argsHadExplicitTarget: false, resolvedPort: 8126, resolvedUDID: "BBB")
        XCTAssertNil(updated)
    }

    // MARK: - iOS: 一連の流れ(3: 2回目の明示が1回目を上書きする)

    func testIOSSecondExplicitCallReplacesFirstInMemory() {
        var memory: (port: UInt16, udid: String?)?

        // 呼び出し1: port 8123 を明示
        memory = MCPServer.iosMemoryAfterResolve(
            argsHadExplicitTarget: true, resolvedPort: 8123, resolvedUDID: "AAA")
        XCTAssertEqual(memory?.port, 8123)

        // 呼び出し2: 別の port 8124 を明示 — 記憶は更新される
        memory = MCPServer.iosMemoryAfterResolve(
            argsHadExplicitTarget: true, resolvedPort: 8124, resolvedUDID: "BBB")
        XCTAssertEqual(memory?.port, 8124)
        XCTAssertEqual(memory?.udid, "BBB")

        // 呼び出し3: 完全に無指定 — 直近(呼び出し2)の記憶にフォールバックする。1回目ではない
        let (explicit, used) = MCPServer.iosExplicitWithMemory(
            fromArgs: nil, argsOmittedTarget: true, remembered: memory)
        XCTAssertEqual(explicit, 8124)
        XCTAssertEqual(used?.udid, "BBB")
    }

    // MARK: - Android: 使用側(androidExplicitWithMemory)

    func testAndroidNoMemoryYetPassesThroughUnchanged() {
        let (explicit, used) = MCPServer.androidExplicitWithMemory(fromArgs: nil, remembered: nil)
        XCTAssertNil(explicit)
        XCTAssertNil(used)
    }

    func testAndroidFallsBackToRememberedSerialWhenOmitted() {
        let (explicit, used) = MCPServer.androidExplicitWithMemory(
            fromArgs: nil, remembered: "emulator-5554")
        XCTAssertEqual(explicit, "emulator-5554")
        XCTAssertEqual(used, "emulator-5554")
    }

    /// 空文字列も「無指定」として扱う(resolveAndroidSerial と揃える)
    func testAndroidTreatsEmptySerialAsOmitted() {
        let (explicit, used) = MCPServer.androidExplicitWithMemory(
            fromArgs: "", remembered: "emulator-5554")
        XCTAssertEqual(explicit, "emulator-5554")
        XCTAssertEqual(used, "emulator-5554")
    }

    func testAndroidDoesNotOverrideAnExplicitSerial() {
        let (explicit, used) = MCPServer.androidExplicitWithMemory(
            fromArgs: "emulator-5556", remembered: "emulator-5554")
        XCTAssertEqual(explicit, "emulator-5556")
        XCTAssertNil(used)
    }

    // MARK: - Android: 更新側(androidMemoryAfterResolve)

    func testAndroidMemoryUpdatesOnlyWhenArgsGaveASerial() {
        XCTAssertEqual(MCPServer.androidMemoryAfterResolve(
            fromArgs: "emulator-5554", resolvedSerial: "emulator-5554"), "emulator-5554")
    }

    /// 自動解決(無指定呼び出し)の結果は記憶を汚さない(4)
    func testAndroidMemoryDoesNotUpdateOnAutoResolvedCall() {
        XCTAssertNil(MCPServer.androidMemoryAfterResolve(
            fromArgs: nil, resolvedSerial: "emulator-5554"))
        XCTAssertNil(MCPServer.androidMemoryAfterResolve(
            fromArgs: "", resolvedSerial: "emulator-5554"))
    }

    // MARK: - Android: 一連の流れ(3)

    func testAndroidSecondExplicitCallReplacesFirstInMemory() {
        var memory: String?

        memory = MCPServer.androidMemoryAfterResolve(
            fromArgs: "emulator-5554", resolvedSerial: "emulator-5554")
        XCTAssertEqual(memory, "emulator-5554")

        memory = MCPServer.androidMemoryAfterResolve(
            fromArgs: "emulator-5556", resolvedSerial: "emulator-5556")
        XCTAssertEqual(memory, "emulator-5556")

        let (explicit, used) = MCPServer.androidExplicitWithMemory(fromArgs: nil, remembered: memory)
        XCTAssertEqual(explicit, "emulator-5556")
        XCTAssertEqual(used, "emulator-5556")
    }
}
