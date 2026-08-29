// 一括起動・停止(`api devices-up` / `devices-down` / `devices-restart`)が読む台帳の決め方。
//
// 実害(2026-08-29): マシンプロファイルが2つある案件で**実行プロファイルを選んでいない**
// (「(プロファイルなし)」)まま「デバイスを全て起動」を押すと、`determineMachine` が
// `cannot tell which machine profile to use` で落ち、**画面には何も起きなかった**
// (失敗は OUTPUT にしか出ていなかった)。監視(ApiMonitorCommand)とタイルの単体操作
// (ApiDeviceOperation)は既に「台帳を1つに決めず machines/ を畳む」規律へ移っていたのに、
// 一括だけ取り残されていた —— 同型の掃討漏れ。

import XCTest
import FTCore
@testable import fleetest

final class MachineProfileLoadTests: XCTestCase {

    private func projectWithMachines(_ files: [String: String]) throws -> TestProject {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fleetest-machine-load-\(UUID().uuidString)")
        let machines = root.appendingPathComponent("profiles/machines")
        try FileManager.default.createDirectory(at: machines, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (name, body) in files {
            try body.write(to: machines.appendingPathComponent("\(name).json"),
                           atomically: true, encoding: .utf8)
        }
        return TestProject(name: "p", rootURL: root)
    }

    private func load(_ project: TestProject, profile: String? = nil,
                      registry: [String] = []) throws -> MachineProfile {
        try MachineProfileLoad.load(project: project, profile: profile, deviceMachine: nil,
                                    registry: registry, noteAutoMachine: { _ in }, warn: { _ in })
    }

    /// 台帳が2つあっても、プロファイル未選択なら**落とさずに畳む**(押した操作を断らない)
    func testWithoutARunProfileTwoLedgersAreMergedInsteadOfFailing() throws {
        let project = try projectWithMachines([
            "aaa": #"{"ios":{"devices":[{"name":"A"}]}}"#,
            "zzz": #"{"android":{"devices":[{"name":"B","avd":"AVD_B"}]}}"#,
        ])
        let merged = try load(project)
        XCTAssertEqual(merged.ios?.devices?.map(\.name), ["A"])
        XCTAssertEqual(merged.android?.devices?.map(\.name), ["B"])
    }

    /// 畳んだあとも「この機械が扱える台だけ」に絞る(別の機械の台へ simctl/adb は撃てない)。
    /// 登録簿に居るリモートの台は fan-out がその機械で起こす
    func testRemoteDevicesAreLeftToTheirOwnMachine() throws {
        let project = try projectWithMachines([
            "one": #"{"ios":{"devices":[{"name":"L"},{"name":"R","machine":"M1Max"}]}}"#,
        ])
        let merged = try load(project, registry: ["M1Max"])
        XCTAssertEqual(merged.ios?.devices?.map(\.name), ["L"], "手元の台だけ残す")
    }

    /// 登録簿に無い機械の台は畳んだ時点で落ちる(観測も操作もできない台を並べない)
    func testDevicesOfUnregisteredMachinesAreDropped() throws {
        let project = try projectWithMachines([
            "one": #"{"ios":{"devices":[{"name":"L"},{"name":"R","machine":"Ghost"}]}}"#,
        ])
        let merged = try load(project, registry: [])
        XCTAssertEqual(merged.ios?.devices?.map(\.name), ["L"])
    }

    /// **選んでいるときは従来どおり**(その台帳だけを使い、実行プロファイルの参照で絞る)。
    /// 存在しない実行プロファイル名なら落ちる = 畳む経路へすり替わっていないことの witness
    func testWithARunProfileTheLedgerIsStillResolvedTheOldWay() throws {
        let project = try projectWithMachines([
            "aaa": #"{"ios":{"devices":[{"name":"A"}]}}"#,
            "zzz": #"{"ios":{"devices":[{"name":"Z"}]}}"#,
        ])
        XCTAssertThrowsError(try load(project, profile: "no-such-run-profile"))
    }
}
