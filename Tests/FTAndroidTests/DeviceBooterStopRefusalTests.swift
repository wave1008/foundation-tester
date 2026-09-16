// docs/remote-runner.md §18.7 規律④「他人の run を殺す操作はロックを読む」を停止系にも適用した分。
// DeviceBooter.stopRefusal は判定の唯一の定義元(holderPID を注入する純粋関数。RunLeaseGuardTests と
// 同じ形で I/O を持たない)。shutdownAll の統合テストは実機 spec(udid/serial を直値で宣言)だけを
// 使う —— DeviceBooter.leaseKey は実機なら simctl/adb を叩かずに解決できるため、実デバイスにも
// simctl/adb にも触れずに「1台拒否・残りは続行」を確かめられる。

import XCTest
@testable import FTAndroid
import FTBridgeClient
import FTCore
import FTTestSupport

final class DeviceBooterStopRefusalTests: XCTestCase {

    func testHeldByOtherLivePIDRefuses() {
        let message = DeviceBooter.stopRefusal(
            deviceName: "iPhone 17 Pro(iOS 27.0)-01", key: "UDID-1",
            selfPID: 100, force: false, holderPID: { _ in 4242 })
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("iPhone 17 Pro(iOS 27.0)-01"), "台名を名指しする")
        XCTAssertTrue(message!.contains("4242"), "保持者 pid を名指しする")
        XCTAssertTrue(message!.contains("--force"), "押し切る手段を添える")
    }

    // 自分自身の pid が握っている lease(同一プロセスが直前に書いた分等)は衝突と見なさない
    func testSelfPIDDoesNotRefuse() {
        XCTAssertNil(DeviceBooter.stopRefusal(
            deviceName: "d", key: "k", selfPID: 100, force: false, holderPID: { _ in 100 }))
    }

    func testNoHolderDoesNotRefuse() {
        XCTAssertNil(DeviceBooter.stopRefusal(
            deviceName: "d", key: "k", selfPID: 100, force: false, holderPID: { _ in nil }))
    }

    // 戻すと落ちる根拠: --force が生きた他プロセスの lease を押し切れなくなる
    func testForceOverridesAHeldLease() {
        XCTAssertNil(DeviceBooter.stopRefusal(
            deviceName: "d", key: "k", selfPID: 100, force: true, holderPID: { _ in 4242 }))
    }

    // 台の実体(serial/UDID)が引けない = その台に居るはずの lease も引けない。安全側(素通り)
    func testUnresolvableKeyDoesNotRefuse() {
        XCTAssertNil(DeviceBooter.stopRefusal(
            deviceName: "d", key: nil, selfPID: 100, force: false, holderPID: { _ in 4242 }))
    }
}

final class DeviceBooterShutdownAllLeaseRefusalTests: XCTestCase {

    private func makeStateDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    // getppid() は自分の pid とは別で、テストプロセスが生きている間ずっと生存している
    // (ProcessLiveness.isAlive を満たす)ので、「生きた別プロセスが台を握っている」を
    // 実プロセスを新たに起こさずに再現できる
    func testOneHeldDeviceIsRefusedWhileOthersProceed() async throws {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let heldUDID = "00008130-AAAA"
        let holder = getppid()
        RunLease.write(stateDir: dir, key: heldUDID, pid: holder)

        let profile = MachineProfile(
            ios: MachineDeviceList(devices: [
                DeviceSpec(name: "iPhone-Held", kind: .physical, udid: heldUDID),
                DeviceSpec(name: "iPhone-Free", kind: .physical, udid: "00008130-BBBB"),
            ]),
            android: MachineDeviceList(devices: [
                DeviceSpec(name: "Pixel-Free", kind: .physical, serial: "R3CN123"),
            ]))
        let stopped = LockedBox([String]())
        let outcomes = await DeviceBooter.shutdownAll(
            machine: profile, repoRoot: nil, leaseStateDir: dir, log: { _ in },
            stopOne: { spec, _ in stopped.mutate { $0.append(spec.name) } })

        XCTAssertEqual(Set(stopped.value), Set(["iPhone-Free", "Pixel-Free"]),
                       "保持中の台は stopOne を呼ばない")
        let held = outcomes.first { $0.name == "iPhone-Held" }
        XCTAssertEqual(held?.succeeded, false)
        XCTAssertTrue(held?.failure?.contains("iPhone-Held") ?? false)
        XCTAssertTrue(held?.failure?.contains("\(holder)") ?? false)
        XCTAssertEqual(outcomes.first { $0.name == "iPhone-Free" }?.succeeded, true)
        XCTAssertEqual(outcomes.first { $0.name == "Pixel-Free" }?.succeeded, true)
    }

    func testForceBypassesTheRefusalAndStopsTheHeldDevice() async throws {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let heldUDID = "00008130-AAAA"
        RunLease.write(stateDir: dir, key: heldUDID, pid: getppid())

        let profile = MachineProfile(ios: MachineDeviceList(devices: [
            DeviceSpec(name: "iPhone-Held", kind: .physical, udid: heldUDID),
        ]))
        let stopped = LockedBox([String]())
        let outcomes = await DeviceBooter.shutdownAll(
            machine: profile, repoRoot: nil, force: true, leaseStateDir: dir, log: { _ in },
            stopOne: { spec, _ in stopped.mutate { $0.append(spec.name) } })

        XCTAssertEqual(stopped.value, ["iPhone-Held"])
        XCTAssertEqual(outcomes.first?.succeeded, true)
    }
}
