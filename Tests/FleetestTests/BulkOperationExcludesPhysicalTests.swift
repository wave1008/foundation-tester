import XCTest

@testable import FTAndroid
@testable import FTBridgeClient
import FTCore

/// ユーザー決定: 実機は一括デバイス操作(devices up/down・api devices-up/down/restart・
/// モニターの「全て起動/終了」)の対象外にする —— 実機は端末そのものを起動・停止できないため、
/// 一括起動に混じると `BridgeProvisioner.provision` の数分のビルド(xcodebuild
/// build-for-testing)を始めてしまい、固定2台の同時起動枠の半分をそれが専有して他機の起動を遅らせる。
///
/// ここで固定する2つの純関数が壊れると黙って退化する:
/// - `DeviceBooter.buildBootQueue` が実機を弾き損ねると、実機が再びキューへ紛れ込む
///   (bootAll が数分のブリッジ供給を始め、maxConcurrent の枠を専有する退行)
/// - `BridgeLauncher.isPhysicalRunnerCommand` の判定が壊れると、`stopAll(skipPhysical: true)` が
///   生きている実機ランナーの pid ファイルを消してしまい、次のポート採番(assignPort)がずれる
final class BulkOperationExcludesPhysicalTests: XCTestCase {

    // MARK: - DeviceBooter.buildBootQueue

    private func mixedMachine() -> MachineProfile {
        MachineProfile(
            ios: MachineDeviceList(devices: [
                DeviceSpec(name: "iPhone-B", kind: .virtual),
                DeviceSpec(name: "iPhone-A", kind: .virtual),
                DeviceSpec(name: "iPhone-Real", kind: .physical, udid: "00008130-AAAA"),
            ]),
            android: MachineDeviceList(devices: [
                DeviceSpec(name: "Pixel-B", kind: .virtual, avd: "pixel_b"),
                DeviceSpec(name: "Pixel-A", kind: .virtual, avd: "pixel_a"),
                DeviceSpec(name: "Pixel-Real", kind: .physical, serial: "R3CN123"),
            ]))
    }

    /// 実機は items に一切現れず、items の並びは従来どおり ios→android・各内 name 昇順
    /// (vscode-fleetest/src/monitorModel.ts sortMonitorDevices と対のタイル表示順契約)。
    /// skippedPhysical には除外した実機がちょうど載る
    func testBuildBootQueueExcludesPhysicalDevices() {
        let result = DeviceBooter.buildBootQueue(
            machine: mixedMachine(), restartNames: [], cpuRenderNames: [])

        XCTAssertEqual(result.items.map(\.spec.name), ["iPhone-A", "iPhone-B", "Pixel-A", "Pixel-B"])
        XCTAssertEqual(Set(result.skippedPhysical.map(\.name)), ["iPhone-Real", "Pixel-Real"])
        XCTAssertFalse(result.items.contains { $0.spec.isPhysical },
                       "実機は同時起動枠を専有するのでキューに絶対に入れてはいけない")
    }

    /// restartNames(凍結復帰の強制再起動リスト)に実機の名前が混じっても、実機は再起動先頭
    /// 位置にも通常ブート項目にも入らない(watchdog の名簿は仮想デバイスしか知らないはずだが、
    /// 万一混入しても実機側で down→up を撃たないことを固定する)
    func testBuildBootQueueExcludesPhysicalDevicesEvenWhenNamedForRestart() {
        let result = DeviceBooter.buildBootQueue(
            machine: mixedMachine(), restartNames: ["iPhone-Real"], cpuRenderNames: [])

        XCTAssertTrue(result.skippedPhysical.contains { $0.name == "iPhone-Real" })
        XCTAssertFalse(result.items.contains { $0.spec.isPhysical })
    }

    // MARK: - BridgeLauncher.isPhysicalRunnerCommand

    /// 実機とシミュレータは DerivedData を分けてある(BridgeLauncher.derivedDataPath)ので、
    /// -xctestrun のパスにそれがそのまま写る。stopAll(skipPhysical: true) はこれ1本で
    /// 「殺してよいか」を決めるので、判定がここで崩れると生きた実機ランナーの pid ファイルを
    /// 消してしまう(assignPort の採番ずれに直結)
    func testIsPhysicalRunnerCommandDetectsDerivedDataDeviceRoot() {
        let physical = "/usr/bin/xcodebuild test-without-building -xctestrun"
            + " /Users/x/repo/.fleetest/DerivedData-device/Build/Products/FleetestRunner-8123.xctestrun"
            + " -destination platform=iOS,id=00008130-AAAA"
        XCTAssertTrue(BridgeLauncher.isPhysicalRunnerCommand(physical))
    }

    func testIsPhysicalRunnerCommandRejectsSimulatorDerivedDataRoot() {
        let simulator = "/usr/bin/xcodebuild test-without-building -xctestrun"
            + " /Users/x/repo/.fleetest/DerivedData/Build/Products/FleetestRunner-8123.xctestrun"
            + " -destination platform=iOS Simulator,id=ABCDEF"
        XCTAssertFalse(BridgeLauncher.isPhysicalRunnerCommand(simulator))
    }

    func testIsPhysicalRunnerCommandRejectsUnrelatedCommand() {
        XCTAssertFalse(BridgeLauncher.isPhysicalRunnerCommand("/usr/bin/ps -ax"))
    }

    // MARK: - 配線(純関数では届かない呼び出し側)

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 一括停止の3経路が実機を弾いていること。**判定は各ループに1つずつ書いてある**ので、
    /// 消えても純関数のテストは緑のまま通る(実機のブリッジが黙って落ちる退行)
    func testEveryBulkStopPathSkipsPhysicalDevices() throws {
        // **本数で数える** —— 「存在するか」だけだと ios/android の片方のループから消えても
        // もう片方が残るので緑のまま通る(実際にこの変異が生き残った)
        let api = try source("Sources/fleetest/ApiDeviceCommands.swift")
        XCTAssertEqual(api.components(separatedBy: "Self.logPhysicalSkip(spec: spec)").count - 1, 2,
                       "api devices-down の ios/android 両ループが実機を弾く")
        XCTAssertTrue(api.contains("if spec.isPhysical {"),
                      "api devices-restart も実機を items に積まない")

        let devices = try source("Sources/fleetest/DevicesCommand.swift")
        XCTAssertEqual(devices.components(separatedBy: "if spec.isPhysical {").count - 1, 2,
                       "devices down --profile の ios/android 両ループが実機を弾く")
    }

    /// 掃討(profile 無しの devices down)は実機のブリッジを残し、
    /// **明示コマンドの `bridge down --all` だけが実機のブリッジも止める**。
    /// この2つは同じ関数を別の引数で呼ぶので、取り違えるとどちらかが黙って壊れる
    func testSweepSkipsPhysicalBridgesButBridgeDownAllDoesNot() throws {
        XCTAssertTrue(try source("Sources/fleetest/DevicesCommand.swift")
            .contains("BridgeLauncher.stopAll(repoRoot: root, skipPhysical: true)"))
        XCTAssertTrue(try source("Sources/fleetest/Fleetest.swift")
            .contains("BridgeLauncher.stopAll(repoRoot: root, skipPhysical: false)"))
    }
}
