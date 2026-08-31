// モニターが「どの機械のデバイスを観測し、何を devices として出すか」の規則。
//
// 守っているのは3つ:
//  1. **他の機械のデバイスを走査しない** —— simctl/adb は手元にしか効かないので、走査すると
//     同名の手元のシミュレータに解決して**別の機械の台の状態と画面**を出す((host, name) が
//     一意なら同名は正常な構成なので普通に起きる)
//  2. **観測していない台を offline と言わない** —— 向こうで動いていても止まって見える
//     (2026-08-17 の実害。これが「起動しようとしたのか分からない」の正体)
//  3. **子(--device-machine 付き)は自分のぶんだけを出す** —— 親も同じ台を並べるので、
//     両方が出すと拡張側の Map(id が鍵)で潰し合う

import FTCore
import XCTest

@testable import fleetest

final class MonitorMachineScopeTests: XCTestCase {

    private func target(_ name: String, host: String?, platform: String = "ios") -> MonitorTarget {
        var spec = DeviceSpec(name: name, os: "27.0")
        spec.machine = host
        return MonitorTarget(platform: platform, spec: spec)
    }

    // MARK: - scope

    func testParentScansOnlyItsOwnDevicesButListsThemAll() {
        let targets = [target("A", host: nil), target("B", host: "M1Max"), target("C", host: "M1Ultra")]
        let scope = ApiMonitorCommand.scope(targets: targets, deviceMachine: nil)

        XCTAssertEqual(scope.owned.map(\.name), ["A"],
                       "他の機械の台を simctl/adb で見ると同名の手元の台に解決してしまう")
        XCTAssertEqual(scope.listed.map(\.name), ["A", "B", "C"],
                       "並べるのは全部(タイルが消えると、ホストが落ちた瞬間に台が画面から消える)")
        XCTAssertEqual(scope.foreignMachines, ["M1Max", "M1Ultra"])
    }

    func testChildOwnsTheHostItWasToldAndListsNothingElse() {
        let targets = [target("A", host: nil), target("B", host: "M1Max"), target("C", host: "M1Ultra")]
        let scope = ApiMonitorCommand.scope(targets: targets, deviceMachine: "M1Max")

        XCTAssertEqual(scope.owned.map(\.name), ["B"])
        XCTAssertEqual(scope.listed.map(\.name), ["B"], "親も同じ台を出すので、子が他を出すと潰し合う")
        XCTAssertTrue(scope.foreignMachines.isEmpty, "入れ子のディスパッチは作らない")
    }

    func testExplicitLocalCountsAsThisMachine() {
        let scope = ApiMonitorCommand.scope(targets: [target("A", host: "local")], deviceMachine: nil)
        XCTAssertEqual(scope.owned.map(\.name), ["A"])
        XCTAssertTrue(scope.foreignMachines.isEmpty)
    }

    func testForeignHostsAreListedOnceInOrderOfAppearance() {
        let targets = [
            target("A", host: "M1Ultra"), target("B", host: "M1Max"), target("C", host: "M1Ultra"),
        ]
        let scope = ApiMonitorCommand.scope(targets: targets, deviceMachine: nil)
        XCTAssertEqual(scope.foreignMachines, ["M1Ultra", "M1Max"], "1ホストにつき子は1本")
    }

    // MARK: - requiresMachineProfile
    //
    // 実害(2026-08-17): 実行プロファイルの選択を外した瞬間にモニターが起動できなくなった
    // (「machines/ が複数あるので決められない」で exit 1)。未選択は拡張の
    // 「(起動中のデバイス)」= 動いている台を見る、の意味なので、確定できなくても続けるべき。
    // **配線(その判断を実際に使っているか)は実走で確認する** —— この pure な述語だけでは、
    // 呼び出しが消えても落ちない

    func testMachineProfileIsRequiredOnlyWhenARunProfileIsSelected() {
        XCTAssertTrue(ApiMonitorCommand.requiresMachineProfile(profile: "local+remote"),
                      "選んだ以上、その machine が要る(誤設定を黙って通さない)")
        XCTAssertFalse(ApiMonitorCommand.requiresMachineProfile(profile: nil),
                       "未選択は「起動中の台を見る」の意味。確定できなくても続ける")
    }

    // MARK: - mergedDevices

    private func info(id: String, state: String, udid: String? = nil,
                      kind: String = "virtual", wired: Bool? = nil) -> ApiMonitorDeviceInfo {
        ApiMonitorDeviceInfo(
            id: id, name: id, platform: "ios", state: state, detail: "", udid: udid, serial: nil,
            health: nil, renderMode: nil, inRun: false, kind: kind, host: nil, port: nil,
            recording: false, registered: true, machine: nil, frozen: false, wired: wired,
            streamedByOther: nil)
    }

    func testRemoteEntriesFillInForTheDevicesThisMachineCannotSee() {
        let targets = [target("A", host: nil), target("B", host: "M1Max")]
        let merged = ApiMonitorCommand.mergedDevices(
            listedTargets: targets,
            observed: [info(id: "ios:A", state: "connected")],
            remote: ["ios:M1Max/B": info(id: "ios:M1Max/B", state: "connected")])

        XCTAssertEqual(merged.map(\.id), ["ios:A", "ios:M1Max/B"], "並びはマシンプロファイルの順のまま")
        XCTAssertEqual(merged.map(\.state), ["connected", "connected"])
    }

    func testDevicesNobodyObservedAreUnknownNotOffline() {
        let targets = [target("A", host: nil), target("B", host: "M1Max")]
        let merged = ApiMonitorCommand.mergedDevices(
            listedTargets: targets, observed: [info(id: "ios:A", state: "offline")], remote: [:])

        XCTAssertEqual(merged.map(\.state), ["offline", "unknown"],
                       "届いていない台を offline と言うと、向こうで動いていても止まって見える")
        XCTAssertEqual(merged[1].machine, "M1Max", "どの機械に届いていないのかを言えること")
    }

    func testObservationWinsOverAStaleRemoteEntryForTheSameID() {
        let targets = [target("A", host: nil)]
        let merged = ApiMonitorCommand.mergedDevices(
            listedTargets: targets,
            observed: [info(id: "ios:A", state: "booted")],
            remote: ["ios:A": info(id: "ios:A", state: "connected")])
        XCTAssertEqual(merged.map(\.state), ["booted"], "手元で見えているものが正")
    }

    func testUnregisteredRunningDevicesAreAppendedAfterTheProfileOrder() {
        let targets = [target("A", host: nil)]
        let merged = ApiMonitorCommand.mergedDevices(
            listedTargets: targets,
            observed: [info(id: "ios:A", state: "connected"), info(id: "ios:stray", state: "connected")],
            remote: [:])
        XCTAssertEqual(merged.map(\.id), ["ios:A", "ios:stray"],
                       "マシンプロファイルに無い起動中デバイスも落とさない")
    }
}

// MARK: - fan-out 先の決定(プロファイル未選択 = 拡張の「起動中のデバイス」)

extension MonitorMachineScopeTests {
    /// プロファイルを選んでいるときは従来どおり「そのプロファイルに居る他機」だけ。
    func testFanoutFollowsTheProfileWhenOneIsSelected() {
        XCTAssertEqual(
            ApiMonitorCommand.fanoutMachines(
                foreignMachines: ["M1Max"], profileSelected: true,
                registry: ["M1Max", "M1Ultra"], deviceMachine: nil),
            ["M1Max"],
            "選んだプロファイルの範囲を超えて ssh を張らない")
    }

    /// **未選択(起動中のデバイス)は登録簿の全マシン** —— マシンプロファイルを引かないので、
    /// ここで張らないと「向こうで起動中の台」を知る手掛かりが無く一覧に出ない(2026-08-26 の報告)。
    func testFanoutUsesTheRegistryWhenNoProfileIsSelected() {
        XCTAssertEqual(
            ApiMonitorCommand.fanoutMachines(
                foreignMachines: [], profileSelected: false,
                registry: ["M1Max", "M1Ultra"], deviceMachine: nil),
            ["M1Max", "M1Ultra"])
    }

    /// 登録簿は人が編集するので、空白・空文字・"local"・重複が混ざる。登場順は保つ
    func testFanoutCleansTheRegistryButKeepsOrder() {
        XCTAssertEqual(
            ApiMonitorCommand.fanoutMachines(
                foreignMachines: [], profileSelected: false,
                registry: ["  M1Ultra  ", "", "local", "M1Ultra", "M1Max"], deviceMachine: nil),
            ["M1Ultra", "M1Max"],
            "重複と local と空を落とし、最初に現れた順で返す")
    }

    /// **子は絶対に fan-out しない**(入れ子のディスパッチを作らない)。登録簿があっても空
    func testChildNeverFansOut() {
        XCTAssertEqual(
            ApiMonitorCommand.fanoutMachines(
                foreignMachines: ["M1Max"], profileSelected: false,
                registry: ["M1Max", "M1Ultra"], deviceMachine: "local"),
            [])
    }
}

// MARK: - mergedDevices(リモートの未登録の台)

extension MonitorMachineScopeTests {
    private func remoteInfo(id: String, name: String, machine: String) -> ApiMonitorDeviceInfo {
        var info = ApiMonitorDeviceInfo(
            id: id, name: name, platform: "ios", state: "connected", detail: "",
            udid: nil, serial: nil, health: nil, renderMode: nil, inRun: false, kind: "virtual",
            host: nil, port: nil, recording: false, registered: true, machine: nil, frozen: false,
            wired: nil, streamedByOther: nil)
        info.machine = machine
        return info
    }

    /// **マシンプロファイルに無いリモートの台も出す** —— プロファイル未選択(「起動中のデバイス」)は
    /// listedTargets が手元のぶんしか無いので、ここで落とすと向こうで動いている台が一覧から消える。
    func testMergedDevicesKeepsRemoteDevicesThatAreNotInTheMachineProfile() {
        let merged = ApiMonitorCommand.mergedDevices(
            listedTargets: [], observed: [],
            remote: [
                "ios:M1Ultra/シミュ2": remoteInfo(id: "ios:M1Ultra/シミュ2", name: "シミュ2", machine: "M1Ultra"),
                "ios:M1Max/シミュ1": remoteInfo(id: "ios:M1Max/シミュ1", name: "シミュ1", machine: "M1Max"),
            ])

        XCTAssertEqual(merged.map(\.id), ["ios:M1Max/シミュ1", "ios:M1Ultra/シミュ2"],
                       "id 順で並べる(辞書の順序に依存すると毎サイクル並べ替わる)")
        XCTAssertEqual(merged.map(\.machine), ["M1Max", "M1Ultra"], "マシンのタグが乗っていること")
    }

    /// **WiFi 越しの分身は隠す**: 同じ実機(udid)が、USB で繋がった機械(wired=true)と
    /// WiFi ペアリング済みの機械(wired=false)の両方から connected と報告される
    /// (devicectl は localNetwork でも state=connected。実測 2026-08-31: iPhone 13 が
    /// 手元に wired・M1Ultra から localNetwork で同時に見えた)。wired を優先表示し WiFi は非表示
    func testWifiTwinOfAWiredPhysicalDeviceIsHidden() {
        let udid = "00008110-001460910E0A201E"
        var wifiTwin = info(id: "ios:M1Ultra/iPhone 13", state: "booted",
                            udid: udid, kind: "physical", wired: false)
        wifiTwin.machine = "M1Ultra"
        let merged = ApiMonitorCommand.mergedDevices(
            listedTargets: [],
            observed: [info(id: "ios:iPhone 13", state: "connected",
                            udid: udid, kind: "physical", wired: true)],
            remote: [wifiTwin.id: wifiTwin])

        XCTAssertEqual(merged.map(\.id), ["ios:iPhone 13"],
                       "wired の1枚だけを出す(WiFi 側の分身は隠す)")
    }

    /// wired の分身が居ないときは WiFi の観測も残す —— どれが本物か決められないものを隠すと、
    /// その実機が一覧から丸ごと消える。udid が違えば別個体なので互いに干渉しない
    func testWifiOnlyPhysicalDevicesStayVisible() {
        var wifiOnly = info(id: "ios:M1Ultra/iPhone 13", state: "booted",
                            udid: "00008110-AAAA", kind: "physical", wired: false)
        wifiOnly.machine = "M1Ultra"
        let merged = ApiMonitorCommand.mergedDevices(
            listedTargets: [],
            observed: [info(id: "ios:iPhone SE3", state: "connected",
                            udid: "00008110-BBBB", kind: "physical", wired: true)],
            remote: [wifiOnly.id: wifiOnly])

        XCTAssertEqual(merged.map(\.id).sorted(), ["ios:M1Ultra/iPhone 13", "ios:iPhone SE3"].sorted(),
                       "wired の分身が居ない WiFi の実機・別個体の wired は両方残る")
    }

    /// listedTargets で既に使ったリモートの台を二重に足さない
    func testMergedDevicesDoesNotDuplicateRemoteDevicesAlreadyListed() {
        let spec = DeviceSpec(name: "シミュ1", machine: "M1Max")
        let target = MonitorTarget(platform: "ios", spec: spec)
        let merged = ApiMonitorCommand.mergedDevices(
            listedTargets: [target], observed: [],
            remote: [target.id: remoteInfo(id: target.id, name: "シミュ1", machine: "M1Max")])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].state, "connected", "リモートの観測結果が unobserved を上書きする")
    }
}
