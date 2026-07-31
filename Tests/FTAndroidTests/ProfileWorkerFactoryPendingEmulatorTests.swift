// ensureAndroidEmulators が起動対象を選ぶ純ロジック(pendingEmulatorProfile)のみを検証する
// (本体はエミュレータ起動プロセスを伴うため単体テスト不可)。

import XCTest
@testable import FTAndroid
@testable import FTCore

final class ProfileWorkerFactoryPendingEmulatorTests: XCTestCase {
    private func emulatorSpec(_ name: String) -> DeviceSpec {
        DeviceSpec(name: name, avd: name)
    }

    private func physicalSpec(_ name: String) -> DeviceSpec {
        DeviceSpec(name: name, kind: .physical, serial: "serial-\(name)")
    }

    func testAllRunningReturnsNil() {
        let devices = [(name: "a", spec: emulatorSpec("a")), (name: "b", spec: emulatorSpec("b"))]
        let result = ProfileWorkerFactory.pendingEmulatorProfile(
            androidDevices: devices, isRunning: { _ in true })
        XCTAssertNil(result)
    }

    func testSomePendingIncludesOnlyThoseDevices() {
        let a = emulatorSpec("a")
        let b = emulatorSpec("b")
        let devices = [(name: "a", spec: a), (name: "b", spec: b)]
        let result = ProfileWorkerFactory.pendingEmulatorProfile(
            androidDevices: devices, isRunning: { $0.name == "a" })
        XCTAssertEqual(result?.android?.devices?.map(\.name), ["b"])
        XCTAssertNil(result?.ios)
    }

    func testPhysicalDevicesAreExcludedEvenWhenNotRunning() {
        let virtual = emulatorSpec("a")
        let physical = physicalSpec("p")
        let devices = [(name: "a", spec: virtual), (name: "p", spec: physical)]
        let result = ProfileWorkerFactory.pendingEmulatorProfile(
            androidDevices: devices, isRunning: { _ in false })
        XCTAssertEqual(result?.android?.devices?.map(\.name), ["a"])
    }

    func testNoAndroidDevicesReturnsNil() {
        let result = ProfileWorkerFactory.pendingEmulatorProfile(
            androidDevices: [], isRunning: { _ in false })
        XCTAssertNil(result)
    }
}
