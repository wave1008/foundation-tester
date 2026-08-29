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
                      registry: [String] = [],
                      foreign: MachineProfileLoad.ForeignDevices = .notHandled,
                      warn: @escaping (String) -> Void = { _ in }) throws -> MachineProfile {
        try MachineProfileLoad.load(project: project, profile: profile, deviceMachine: nil,
                                    registry: registry, foreign: foreign,
                                    noteAutoMachine: { _ in }, warn: warn)
    }

    /// **分散する経路では「その機械で起動してください」と案内しない**。
    /// 実害 2026-08-30: 一括起動のログで、この案内の 2 秒後に fan-out が同じ台を起動していた
    /// (利用者には「分散していない」ように読める)
    func testDispatchingCallersDoNotTellTheUserToStartThemManually() throws {
        let project = try projectWithMachines([
            "local": #"{"ios":{"devices":[{"name":"A"}]}}"#,
            "M1Max": #"{"machine":"M1Max","ios":{"devices":[{"name":"R"}]}}"#,
        ])
        var lines: [String] = []
        _ = try load(project, registry: ["M1Max"], foreign: .dispatchedByCaller) { lines.append($0) }

        let about = lines.filter { $0.contains("M1Max") }
        XCTAssertFalse(about.contains { $0.contains("start them there") },
                       "分散するのに手動起動を案内している: \(about)")
        XCTAssertTrue(about.contains { $0.contains("Dispatching") },
                      "その機械へ回すことは言う(黙って減らさない): \(about)")
    }

    /// **`foreign` の申告と実際の分散が一致していること**(型では止まらない)。
    /// RemoteDeviceFanout.dispatch を呼ぶ経路だけが .dispatchedByCaller を名乗る ——
    /// 取り違えると、分散するのに手動起動を案内する(元の実害)か、
    /// 誰も起動しないのに「その機械へ回します」と嘘をつく
    func testOnlyTheFanningOutCommandsDeclareThemselvesAsDispatching() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiDeviceCommands.swift")
        let code = try String(contentsOf: url, encoding: .utf8)

        // api devices-up / api devices-down = 分散する2つ。devices-restart は分散しない
        XCTAssertEqual(code.components(separatedBy: "foreign: .dispatchedByCaller").count - 1, 2,
                       "分散を宣言してよいのは api devices-up と api devices-down の2つだけ")
        XCTAssertEqual(code.components(separatedBy: "RemoteDeviceFanout.dispatch(").count - 1, 2,
                       "実際に分散している箇所の数と一致すること(片方だけ増減したら気付く)")
    }

    /// 分散しない経路(`devices up` など)では従来どおり手動の案内を出す ——
    /// 上のテストが「常に案内を消す」実装を通してしまわないための対照
    func testNonDispatchingCallersStillTellTheUserHowToStartThem() throws {
        let project = try projectWithMachines([
            "local": #"{"ios":{"devices":[{"name":"A"}]}}"#,
            "M1Max": #"{"machine":"M1Max","ios":{"devices":[{"name":"R"}]}}"#,
        ])
        var lines: [String] = []
        _ = try load(project, registry: ["M1Max"], foreign: .notHandled) { lines.append($0) }

        XCTAssertTrue(lines.contains { $0.contains("M1Max") && $0.contains("start them there") },
                      "誰も起動しない経路では起動方法を案内する: \(lines)")
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
