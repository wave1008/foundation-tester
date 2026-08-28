// MachineInventory(実行プロファイル未選択のときの監視対象)の単体テスト。
// 実害の再現: マシンプロファイルが2つある案件で「(プロファイルなし)」を選ぶと1台も出なかった
// (台帳を1つに決められず「今動いている台」だけに縮退していた)。

import XCTest
@testable import FTCore

final class MachineInventoryTests: XCTestCase {

    private func profile(machine: String? = nil,
                         ios: [DeviceSpec] = [], android: [DeviceSpec] = []) -> MachineProfile {
        MachineProfile(machine: machine,
                       ios: MachineDeviceList(devices: ios),
                       android: MachineDeviceList(devices: android))
    }

    private func names(_ entries: [DeviceMachineGrouping.CatalogEntry]) -> [String] {
        entries.map { "\($0.platform):\(DeviceMachineGrouping.display($0.machine))/\($0.name)" }
    }

    func testKeepsLocalDevicesEvenWithAnEmptyRegistry() {
        let entries = MachineInventory.observableEntries(
            profiles: [profile(ios: [DeviceSpec(name: "A")], android: [DeviceSpec(name: "B")])],
            registry: [])
        XCTAssertEqual(names(entries), ["ios:local/A", "android:local/B"])
    }

    func testKeepsOnlyMachinesInTheRegistry() {
        let entries = MachineInventory.observableEntries(
            profiles: [profile(ios: [
                DeviceSpec(name: "here"),
                DeviceSpec(name: "runner", machine: "M1Max"),
                // 登録簿に無い = fan-out が張られない = 状態が永久に unknown。出さない
                DeviceSpec(name: "ghost", machine: "RetiredMac"),
            ])],
            registry: ["M1Max", "M1Ultra"])
        XCTAssertEqual(names(entries), ["ios:local/here", "ios:M1Max/runner"])
    }

    func testMergesEveryMachineProfileAndDropsDuplicates() {
        // 手元の台は両方の台帳に居るのが普通(構成の使い分け)。重複はエラーではなく1件に畳む
        let onlyLocal = profile(ios: [DeviceSpec(name: "A"), DeviceSpec(name: "B")])
        let withRunners = profile(ios: [
            DeviceSpec(name: "A"),
            DeviceSpec(name: "C"),
            DeviceSpec(name: "A", machine: "M1Max"),  // 同名でもマシンが違えば別の台
        ])
        let entries = MachineInventory.observableEntries(
            profiles: [onlyLocal, withRunners], registry: ["M1Max"])
        XCTAssertEqual(names(entries), ["ios:local/A", "ios:local/B", "ios:local/C", "ios:M1Max/A"])
    }

    func testSamePlatformIsRequiredForADuplicate() {
        // プラットフォームが違えば同名でも別の台(iOS の "Pixel 9" という命名は普通ではないが、
        // 鍵から platform を落とすと片方が消えるので固定する)
        let entries = MachineInventory.observableEntries(
            profiles: [profile(ios: [DeviceSpec(name: "X")], android: [DeviceSpec(name: "X")])],
            registry: [])
        XCTAssertEqual(names(entries), ["ios:local/X", "android:local/X"])
    }

    func testProfileDefaultMachineIsAppliedBeforeFiltering() {
        // 台帳ごと "machine" を持つ形(全台がそのマシンに居る)。デバイス側に machine が無くても
        // 実効マシンで判定する
        let entries = MachineInventory.observableEntries(
            profiles: [profile(machine: "M1Ultra", ios: [DeviceSpec(name: "A")])],
            registry: ["M1Ultra"])
        XCTAssertEqual(names(entries), ["ios:M1Ultra/A"])

        let dropped = MachineInventory.observableEntries(
            profiles: [profile(machine: "M1Ultra", ios: [DeviceSpec(name: "A")])],
            registry: [])
        XCTAssertTrue(dropped.isEmpty, "登録簿に無いマシンの台帳は丸ごと落ちる")
    }

    func testExplicitLocalBeatsTheProfileDefault() {
        // デバイス側の "local" は「手元」の明示指定で、台帳既定より強い
        // (DeviceMachineGrouping.effectiveMachine の規律をここでも守る)
        let entries = MachineInventory.observableEntries(
            profiles: [profile(machine: "M1Ultra", ios: [DeviceSpec(name: "A", machine: "local")])],
            registry: [])
        XCTAssertEqual(names(entries), ["ios:local/A"])
    }
}
