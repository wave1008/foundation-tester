// MCPServer が覚える「最後に明示された iOS/Android 宛先」の純粋判定
// (iosExplicitWithMemory/iosMemoryAfterResolve, androidExplicitWithMemory/androidMemoryAfterResolve)
// を、走査/デバイスなしで固定する。driver(_:) 自体はデバイス依存で単体テストしにくいため、
// 記憶の読み書きロジックだけを切り出してある(MCPServer+Driver.swift 参照)。

import XCTest
@testable import fleetest_mcp

final class MCPSessionDeviceMemoryTests: XCTestCase {

    // MARK: - iOS: 明示ターゲット述語(argsGaveIOSTarget/argsGaveAndroidTarget)

    /// **udid:"" は「無指定」**: キー存在(`args["udid"] != nil`)で判定すると
    /// 空文字列を「指定あり」と誤読する非対称が生まれる。Android の serial は元から
    /// isEmpty で見ているので、iOS もこれで揃える
    func testArgsGaveIOSTargetTreatsEmptyUDIDAsOmitted() {
        XCTAssertFalse(MCPServer.argsGaveIOSTarget(["udid": ""]))
        XCTAssertFalse(MCPServer.argsGaveIOSTarget([:]))
        XCTAssertTrue(MCPServer.argsGaveIOSTarget(["udid": "ABC-123"]))
        XCTAssertTrue(MCPServer.argsGaveIOSTarget(["port": 8123]))
    }

    /// port が Int 以外(型崩れ)なら明示扱いしない
    func testArgsGaveIOSTargetIgnoresNonIntPort() {
        XCTAssertFalse(MCPServer.argsGaveIOSTarget(["port": "8123"]))
    }

    func testArgsGaveAndroidTargetTreatsEmptySerialAsOmitted() {
        XCTAssertFalse(MCPServer.argsGaveAndroidTarget(["serial": ""]))
        XCTAssertFalse(MCPServer.argsGaveAndroidTarget([:]))
        XCTAssertTrue(MCPServer.argsGaveAndroidTarget(["serial": "emulator-5554"]))
    }

    // MARK: - iOS: 使用側(iosExplicitWithMemory)

    /// 記憶が無ければ何も返さない(1: 初回・無指定は既定挙動のまま)
    func testIOSNoMemoryYetPassesThroughUnchanged() {
        XCTAssertNil(MCPServer.iosExplicitWithMemory(argsGaveTarget: true, remembered: nil))
        XCTAssertNil(MCPServer.iosExplicitWithMemory(argsGaveTarget: false, remembered: nil))
    }

    /// 記憶があり、この呼び出しが完全に無指定なら記憶を使う(2)
    func testIOSFallsBackToRememberedTargetWhenFullyOmitted() {
        let used = MCPServer.iosExplicitWithMemory(
            argsGaveTarget: false, remembered: (port: 8123, udid: "AAA"))
        XCTAssertEqual(used?.port, 8123)
        XCTAssertEqual(used?.udid, "AAA")
    }

    /// この呼び出しが udid/port のどちらかを持っていれば記憶を割り込ませない
    /// (argsGaveTarget: true — 明示 Int port の流れは不変。旧シグネチャの
    /// `fromArgs: 9999, argsOmittedTarget: false` に相当)
    func testIOSDoesNotOverrideAnExplicitCall() {
        let used = MCPServer.iosExplicitWithMemory(
            argsGaveTarget: true, remembered: (port: 8123, udid: "AAA"))
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
        let used = MCPServer.iosExplicitWithMemory(argsGaveTarget: false, remembered: memory)
        XCTAssertEqual(used?.port, 8124)
        XCTAssertEqual(used?.udid, "BBB")
    }

    // MARK: - Android: 使用側(androidExplicitWithMemory)

    /// **iosExplicitWithMemory と同形**: argsGaveTarget: を取り、使わない tuple 要素
    /// (explicit)は持たない。明示判定(空文字列は無指定)は argsGaveAndroidTarget に一本化してある
    /// (testArgsGaveAndroidTargetTreatsEmptySerialAsOmitted が別途固定する)
    func testAndroidNoMemoryYetPassesThroughUnchanged() {
        XCTAssertNil(MCPServer.androidExplicitWithMemory(argsGaveTarget: true, remembered: nil))
        XCTAssertNil(MCPServer.androidExplicitWithMemory(argsGaveTarget: false, remembered: nil))
    }

    func testAndroidFallsBackToRememberedSerialWhenOmitted() {
        let used = MCPServer.androidExplicitWithMemory(
            argsGaveTarget: false, remembered: "emulator-5554")
        XCTAssertEqual(used, "emulator-5554")
    }

    func testAndroidDoesNotOverrideAnExplicitSerial() {
        let used = MCPServer.androidExplicitWithMemory(
            argsGaveTarget: true, remembered: "emulator-5554")
        XCTAssertNil(used)
    }

    // MARK: - Android: 更新側(androidMemoryAfterResolve)

    func testAndroidMemoryUpdatesOnlyWhenArgsGaveASerial() {
        XCTAssertEqual(MCPServer.androidMemoryAfterResolve(
            argsHadExplicitTarget: true, resolvedSerial: "emulator-5554"), "emulator-5554")
    }

    /// 自動解決(無指定呼び出し)の結果は記憶を汚さない(4)
    func testAndroidMemoryDoesNotUpdateOnAutoResolvedCall() {
        XCTAssertNil(MCPServer.androidMemoryAfterResolve(
            argsHadExplicitTarget: false, resolvedSerial: "emulator-5554"))
    }

    // MARK: - Android: 一連の流れ(3)

    func testAndroidSecondExplicitCallReplacesFirstInMemory() {
        var memory: String?

        memory = MCPServer.androidMemoryAfterResolve(
            argsHadExplicitTarget: true, resolvedSerial: "emulator-5554")
        XCTAssertEqual(memory, "emulator-5554")

        memory = MCPServer.androidMemoryAfterResolve(
            argsHadExplicitTarget: true, resolvedSerial: "emulator-5556")
        XCTAssertEqual(memory, "emulator-5556")

        let used = MCPServer.androidExplicitWithMemory(argsGaveTarget: false, remembered: memory)
        XCTAssertEqual(used, "emulator-5556")
    }
}
