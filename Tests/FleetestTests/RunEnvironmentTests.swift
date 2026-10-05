// 実行環境変数(FT_FAST_INPUT 等)の注入を1箇所にした `FTCore.RunEnvironment` の等号固定。
// CLI の4経路(ProfileRunner/ApiRunCommand の profile 有無2経路/Fleetest.swift の profile 無し
// 経路)と MCP の resolveProfileTarget がここを共有するため、書く/書かないの規則がここで壊れると
// 全経路が同時にずれる。

import XCTest
import FTCore

final class RunEnvironmentTests: XCTestCase {

    func testAllDefaultsWriteOnlyAnimationsOff() {
        let vars = RunEnvironment.variables(
            iosFastInput: false, iosPreActionPing: true, enableAnimations: false,
            playProtectBypass: true, current: [:])
        XCTAssertEqual(vars, [RunEnvironmentKeys.animations: "0"])
    }

    func testFastInputTrueWritesOne() {
        let vars = RunEnvironment.variables(
            iosFastInput: true, iosPreActionPing: true, enableAnimations: false,
            playProtectBypass: true, current: [:])
        XCTAssertEqual(vars[RunEnvironmentKeys.fastInput], "1")
    }

    func testFastInputFalseWritesNothing() {
        let vars = RunEnvironment.variables(
            iosFastInput: false, iosPreActionPing: true, enableAnimations: false,
            playProtectBypass: true, current: [:])
        XCTAssertNil(vars[RunEnvironmentKeys.fastInput])
    }

    func testPreActionPingFalseWritesZero() {
        let vars = RunEnvironment.variables(
            iosFastInput: false, iosPreActionPing: false, enableAnimations: false,
            playProtectBypass: true, current: [:])
        XCTAssertEqual(vars[RunEnvironmentKeys.preActionPing], "0")
    }

    func testPreActionPingTrueWritesNothing() {
        let vars = RunEnvironment.variables(
            iosFastInput: false, iosPreActionPing: true, enableAnimations: false,
            playProtectBypass: true, current: [:])
        XCTAssertNil(vars[RunEnvironmentKeys.preActionPing])
    }

    /// **playProtectBypass=true のとき何も書かない** —— 環境側のキルスイッチ(手動 export の
    /// "0")を上書きしてはならない
    func testPlayProtectBypassTrueWritesNothing() {
        let vars = RunEnvironment.variables(
            iosFastInput: false, iosPreActionPing: true, enableAnimations: false,
            playProtectBypass: true, current: [:])
        XCTAssertNil(vars[RunEnvironmentKeys.playProtectBypass])
    }

    func testPlayProtectBypassFalseWritesZero() {
        let vars = RunEnvironment.variables(
            iosFastInput: false, iosPreActionPing: true, enableAnimations: false,
            playProtectBypass: false, current: [:])
        XCTAssertEqual(vars[RunEnvironmentKeys.playProtectBypass], "0")
    }

    /// **animations は常に書く**(他の3欄と違い、既定のままでも明示する)
    func testAnimationsIsAlwaysPresentRegardlessOfOtherFlags() {
        for fastInput in [false, true] {
            for warmup in [false, true] {
                for bypass in [false, true] {
                    let vars = RunEnvironment.variables(
                        iosFastInput: fastInput, iosPreActionPing: warmup,
                        enableAnimations: false, playProtectBypass: bypass, current: [:])
                    XCTAssertNotNil(vars[RunEnvironmentKeys.animations],
                                    "fastInput=\(fastInput) warmup=\(warmup) bypass=\(bypass)")
                }
            }
        }
    }

    func testAnimationsEnabledWritesOne() {
        let vars = RunEnvironment.variables(
            iosFastInput: false, iosPreActionPing: true, enableAnimations: true,
            playProtectBypass: true, current: [:])
        XCTAssertEqual(vars[RunEnvironmentKeys.animations], "1")
    }

    func testAnimationsDisabledWritesZero() {
        let vars = RunEnvironment.variables(
            iosFastInput: false, iosPreActionPing: true, enableAnimations: false,
            playProtectBypass: true, current: [:])
        XCTAssertEqual(vars[RunEnvironmentKeys.animations], "0")
    }

    /// **環境が既に animations on なら設定 false でも "1"** —— `--set enableAnimations=true` と
    /// 手動 export の両方を尊重する(単純な上書きにしない)
    func testAnimationsAlreadyOnInEnvironmentWinsOverFalseSetting() {
        let vars = RunEnvironment.variables(
            iosFastInput: false, iosPreActionPing: true, enableAnimations: false,
            playProtectBypass: true, current: [RunEnvironmentKeys.animations: "1"])
        XCTAssertEqual(vars[RunEnvironmentKeys.animations], "1")
    }

    func testAnimationsEnabledSettingWinsOverOffEnvironment() {
        let vars = RunEnvironment.variables(
            iosFastInput: false, iosPreActionPing: true, enableAnimations: true,
            playProtectBypass: true, current: [RunEnvironmentKeys.animations: "0"])
        XCTAssertEqual(vars[RunEnvironmentKeys.animations], "1")
    }

    func testAllTrueVariant() {
        let vars = RunEnvironment.variables(
            iosFastInput: true, iosPreActionPing: false, enableAnimations: true,
            playProtectBypass: false, current: [:])
        XCTAssertEqual(vars, [
            RunEnvironmentKeys.fastInput: "1",
            RunEnvironmentKeys.preActionPing: "0",
            RunEnvironmentKeys.animations: "1",
            RunEnvironmentKeys.playProtectBypass: "0",
        ])
    }
}
