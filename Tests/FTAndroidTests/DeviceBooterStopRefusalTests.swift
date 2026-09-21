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

    // MARK: - 複数鍵版(実機 iOS の「宣言値」+「解決後 UDID」)

    // 候補の2番目の鍵だけが保持されていても拒否する(先頭が素通りでも全体が素通りにならない)
    func testMultiKeyRefusesWhenOnlyTheSecondKeyIsHeld() {
        let message = DeviceBooter.stopRefusal(
            deviceName: "d", keys: ["declared", "resolved"], selfPID: 100, force: false,
            holderPID: { key in key == "resolved" ? 4242 : nil })
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("4242"))
    }

    func testMultiKeyDoesNotRefuseWhenNoKeyIsHeld() {
        XCTAssertNil(DeviceBooter.stopRefusal(
            deviceName: "d", keys: ["declared", "resolved"], selfPID: 100, force: false,
            holderPID: { _ in nil }))
    }

    func testMultiKeyForceBypassesEvenIfHeld() {
        XCTAssertNil(DeviceBooter.stopRefusal(
            deviceName: "d", keys: ["declared", "resolved"], selfPID: 100, force: true,
            holderPID: { _ in 4242 }))
    }
}

/// 全掃討(`devices down` のプロファイル無し)の門。台を選べないので、生きた lease が1本でもあれば
/// 掃討ごと断る(戻すと落ちる根拠: 変更前は掃討が run-lease を1度も読まず、手元で回っている run を
/// 確認なしで落としていた)
final class DeviceBooterSweepRefusalTests: XCTestCase {

    func testRefusesWhileAnotherProcessHoldsALease() throws {
        let message = try XCTUnwrap(DeviceBooter.sweepRefusal(
            keys: ["UDID-1", "emulator-5554"], selfPID: 100, force: false,
            holderPID: { $0 == "emulator-5554" ? 4242 : nil },
            describe: { $0 == "UDID-1" ? "iPhone 17 [UDID-1]" : $0 }))
        XCTAssertTrue(message.contains("emulator-5554 (held by pid 4242)"), message)
        XCTAssertFalse(message.contains("UDID-1"), "保持者の居ない台は挙げない: \(message)")
        XCTAssertTrue(message.contains("--force"), "押し切る手段を添える")
    }

    func testNamesEveryHeldDevice() throws {
        let message = try XCTUnwrap(DeviceBooter.sweepRefusal(
            keys: ["UDID-1", "UDID-2"], selfPID: 100, force: false,
            holderPID: { $0 == "UDID-1" ? 4242 : 4343 },
            describe: { "sim-\($0)" }))
        XCTAssertTrue(message.contains("sim-UDID-1 (held by pid 4242)"), message)
        XCTAssertTrue(message.contains("sim-UDID-2 (held by pid 4343)"), message)
    }

    func testDoesNotRefuseWithoutALiveHolder() {
        XCTAssertNil(DeviceBooter.sweepRefusal(
            keys: ["UDID-1"], selfPID: 100, force: false, holderPID: { _ in nil }, describe: { $0 }))
        XCTAssertNil(DeviceBooter.sweepRefusal(
            keys: [], selfPID: 100, force: false, holderPID: { _ in 4242 }, describe: { $0 }))
    }

    func testOwnLeaseDoesNotRefuse() {
        XCTAssertNil(DeviceBooter.sweepRefusal(
            keys: ["UDID-1"], selfPID: 100, force: false, holderPID: { _ in 100 }, describe: { $0 }))
    }

    func testForceOverridesAHeldLease() {
        XCTAssertNil(DeviceBooter.sweepRefusal(
            keys: ["UDID-1"], selfPID: 100, force: true, holderPID: { _ in 4242 }, describe: { $0 }))
    }

    // I/O 側: 実際の lease ファイルを読んで断る。他プロセスの生きた pid には親(テストランナー)を使う
    func testReadsLeaseFilesFromTheStateDirectory() throws {
        let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        RunLease.write(stateDir: stateDir, key: "UDID-LIVE", pid: getppid())
        RunLease.write(stateDir: stateDir, key: "UDID-DEAD", pid: 999_999)
        RunLease.write(stateDir: stateDir, key: "UDID-SELF",
                       pid: ProcessInfo.processInfo.processIdentifier)
        var namesLookedUp = 0
        let message = try XCTUnwrap(DeviceBooter.sweepRefusal(
            force: false, leaseStateDir: stateDir,
            simulatorNames: { namesLookedUp += 1; return ["UDID-LIVE": "iPhone 17"] }, physicalIOSDeviceNames: { [:] }, androidDeviceModels: { [:] }))
        XCTAssertTrue(message.contains("iPhone 17 [UDID-LIVE] (held by pid \(getppid()))"), message)
        XCTAssertFalse(message.contains("UDID-DEAD"), message)
        XCTAssertFalse(message.contains("UDID-SELF"), message)
        XCTAssertEqual(namesLookedUp, 1)
        XCTAssertNil(DeviceBooter.sweepRefusal(
            force: true, leaseStateDir: stateDir, simulatorNames: { [:] }, physicalIOSDeviceNames: { [:] }, androidDeviceModels: { [:] }))
    }

    // 死んだ pid の残骸しか無ければ、表示名の引き当て(本番は simctl)も撃たずに素通りする
    func testDeadLeasesAloneDoNotLookUpNames() throws {
        let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        RunLease.write(stateDir: stateDir, key: "UDID-DEAD", pid: 999_999)
        var namesLookedUp = 0
        XCTAssertNil(DeviceBooter.sweepRefusal(
            force: false, leaseStateDir: stateDir,
            simulatorNames: { namesLookedUp += 1; return [:] }, physicalIOSDeviceNames: { [:] }, androidDeviceModels: { [:] }))
        XCTAssertEqual(namesLookedUp, 0)
    }

    // M10b: シミュレータの名前で引けなかった鍵(実機)は iOS → Android の実機カタログへ
    // 引き直す。実機は simulatorNames に載らないので、そちらを空にしても名指しできること
    func testFallsBackToThePhysicalIOSCatalogWhenNotASimulator() throws {
        let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        RunLease.write(stateDir: stateDir, key: "00008110-000260242EEB801E", pid: getppid())
        let message = try XCTUnwrap(DeviceBooter.sweepRefusal(
            force: false, leaseStateDir: stateDir, simulatorNames: { [:] },
            physicalIOSDeviceNames: { ["00008110-000260242EEB801E": "iPhone 13"] },
            androidDeviceModels: { [:] }))
        XCTAssertTrue(message.contains("iPhone 13 [00008110-000260242EEB801E]"), message)
    }

    func testFallsBackToTheAndroidModelCatalogWhenNotASimulatorOrPhysicalIOS() throws {
        let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        RunLease.write(stateDir: stateDir, key: "14141JEC204922", pid: getppid())
        let message = try XCTUnwrap(DeviceBooter.sweepRefusal(
            force: false, leaseStateDir: stateDir, simulatorNames: { [:] },
            physicalIOSDeviceNames: { [:] },
            androidDeviceModels: { ["14141JEC204922": "Pixel_7"] }))
        XCTAssertTrue(message.contains("Pixel_7 [14141JEC204922]"), message)
    }

    // 実機の一覧取得が失敗した(空を返す)ときは鍵だけで表示する(素通りしない=断りは続く)
    func testFailedPhysicalLookupsStillNameTheKey() throws {
        let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        RunLease.write(stateDir: stateDir, key: "UNRESOLVABLE-KEY", pid: getppid())
        let message = try XCTUnwrap(DeviceBooter.sweepRefusal(
            force: false, leaseStateDir: stateDir, simulatorNames: { [:] },
            physicalIOSDeviceNames: { [:] }, androidDeviceModels: { [:] }))
        XCTAssertTrue(message.contains("UNRESOLVABLE-KEY (held by pid \(getppid()))"), message)
    }

    // MARK: - MCP(fleetest-mcp)が操作中の台(2026-09-17 負荷テスト M10)
    // MCP の印は「pid + 開始時刻」で生死を見るので、保持者には常に生きている launchd(1)を使う
    // (親の pid は「MCP が起こしたコマンド」として数えない設計なので使えない)

    private let mcpHolder: Int32 = 1

    private func makeStateDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mcp-refusal-\(UUID().uuidString)")
    }

    func testMCPStopRefusalNamesTheSessionNotARun() throws {
        let message = try XCTUnwrap(DeviceBooter.mcpStopRefusal(
            deviceName: "iPhone 17", keys: ["U1"], force: false, mcpHolderPID: { _ in 4242 }))
        XCTAssertTrue(message.contains("iPhone 17 is being driven by an MCP session (fleetest-mcp pid 4242)"), message)
        XCTAssertFalse(message.contains("fleetest run"), "run が使用中とは言わない: \(message)")
        XCTAssertTrue(message.contains("--force"), message)
        XCTAssertNil(DeviceBooter.mcpStopRefusal(
            deviceName: "iPhone 17", keys: ["U1"], force: true, mcpHolderPID: { _ in 4242 }))
        XCTAssertNil(DeviceBooter.mcpStopRefusal(
            deviceName: "iPhone 17", keys: ["U1"], force: false, mcpHolderPID: { _ in nil }))
    }

    /// 台を止める経路(停止・一括停止)は MCP の印を読んで断る。印の無い台は止める
    func testShutdownAllRefusesADeviceTheMCPIsDriving() async throws {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        MCPDeviceLease.write(stateDir: dir, key: "00008130-MCP", pid: mcpHolder)

        let profile = DeviceRoster(ios: DeviceRosterList(devices: [
            DeviceSpec(name: "iPhone-MCP", kind: .physical, udid: "00008130-MCP"),
            DeviceSpec(name: "iPhone-Free", kind: .physical, udid: "00008130-FREE"),
        ]))
        let stopped = LockedBox([String]())
        let outcomes = await DeviceBooter.shutdownAll(
            machine: profile, repoRoot: nil, leaseStateDir: dir, log: { _ in },
            stopOne: { spec, _ in stopped.mutate { $0.append(spec.name) } })

        XCTAssertEqual(stopped.value, ["iPhone-Free"])
        let failure = outcomes.first { $0.name == "iPhone-MCP" }?.failure ?? ""
        XCTAssertTrue(failure.contains("MCP session (fleetest-mcp pid \(mcpHolder))"), failure)
    }

    /// 全掃討も MCP の印を読む。run-lease と両方あれば両方を名指しする
    func testSweepRefusesWhileAnMCPSessionDrivesADevice() throws {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        MCPDeviceLease.write(stateDir: dir, key: "UDID-MCP", pid: mcpHolder)
        let mcpOnly = try XCTUnwrap(DeviceBooter.sweepRefusal(
            force: false, leaseStateDir: dir, simulatorNames: { ["UDID-MCP": "iPhone 17"] }, physicalIOSDeviceNames: { [:] }, androidDeviceModels: { [:] }))
        XCTAssertTrue(mcpOnly.contains("an MCP session is driving iPhone 17 [UDID-MCP] (fleetest-mcp pid \(mcpHolder))"),
                      mcpOnly)
        XCTAssertNil(DeviceBooter.sweepRefusal(force: true, leaseStateDir: dir, simulatorNames: { [:] }, physicalIOSDeviceNames: { [:] }, androidDeviceModels: { [:] }))

        RunLease.write(stateDir: dir, key: "UDID-RUN", pid: getppid())
        let both = try XCTUnwrap(DeviceBooter.sweepRefusal(
            force: false, leaseStateDir: dir, simulatorNames: { [:] }, physicalIOSDeviceNames: { [:] }, androidDeviceModels: { [:] }))
        XCTAssertTrue(both.contains("UDID-RUN (held by pid \(getppid()))"), both)
        XCTAssertTrue(both.contains("UDID-MCP (fleetest-mcp pid \(mcpHolder))"), both)
        // 2026-09-20 実測: 見出し「refusing to shut everything down」は run/MCP 両方が
        // 使用中でも1回だけ(以前は各半分が見出し込みの完成文を持ち、単純連結で2回出ていた)
        XCTAssertEqual(both.components(separatedBy: "refusing to shut everything down").count - 1, 1, both)
        XCTAssertTrue(both.hasPrefix("refusing to shut everything down: a running fleetest run is using"), both)
        // 2文目は大文字で始める(小文字のまま続けると文の切れ目が読み取れない)
        XCTAssertTrue(both.contains("Wait for that run to finish, or pass --force to stop it anyway."
            + " An MCP session is driving"), "見出しの後に run → MCP の順で本文が並ぶ: \(both)")
    }

    /// 自分(と親)の印は数えない(MCP が起こしたコマンドが自分の台を断らない)
    func testOwnMCPLeaseDoesNotRefuse() {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        MCPDeviceLease.write(stateDir: dir, key: "UDID-OWN", pid: getpid())
        MCPDeviceLease.write(stateDir: dir, key: "UDID-PARENT", pid: getppid())
        XCTAssertNil(DeviceBooter.deviceInUseRefusal(
            deviceName: "d", keys: ["UDID-OWN", "UDID-PARENT"], force: false, leaseStateDir: dir))
        XCTAssertNil(DeviceBooter.sweepRefusal(force: false, leaseStateDir: dir, simulatorNames: { [:] }, physicalIOSDeviceNames: { [:] }, androidDeviceModels: { [:] }))
    }
}

/// 実機 iOS の解決後 UDID(devicectl の一覧との照合。到達性は問わない・純粋関数)
final class DeviceBooterResolvedPhysicalIOSUDIDTests: XCTestCase {

    func testMatchesByDeclaredIdentifier() {
        let device = IOSPhysicalDeviceInfo(
            udid: "HW-UDID-1", name: "iPhone 15 Pro", os: "iOS 18.5", connected: true,
            transport: "wired", deviceCtlIdentifier: "DEVICECTL-IDENTIFIER-1")
        let spec = DeviceSpec(name: "iPhone", kind: .physical, udid: "DEVICECTL-IDENTIFIER-1")
        XCTAssertEqual(DeviceBooter.resolvedPhysicalIOSUDID(spec: spec, in: [device]), "HW-UDID-1")
    }

    func testMatchesByDeclaredHardwareUDIDToo() {
        let device = IOSPhysicalDeviceInfo(
            udid: "HW-UDID-1", name: "iPhone 15 Pro", os: "iOS 18.5", connected: true,
            transport: "wired", deviceCtlIdentifier: "DEVICECTL-IDENTIFIER-1")
        let spec = DeviceSpec(name: "iPhone", kind: .physical, udid: "HW-UDID-1")
        XCTAssertEqual(DeviceBooter.resolvedPhysicalIOSUDID(spec: spec, in: [device]), "HW-UDID-1")
    }

    func testNoMatchReturnsNil() {
        let spec = DeviceSpec(name: "iPhone", kind: .physical, udid: "UNKNOWN")
        XCTAssertNil(DeviceBooter.resolvedPhysicalIOSUDID(spec: spec, in: []))
    }

    func testNilDeclaredUDIDReturnsNil() {
        let spec = DeviceSpec(name: "iPhone", kind: .physical)
        XCTAssertNil(DeviceBooter.resolvedPhysicalIOSUDID(spec: spec, in: []))
    }
}

/// shutdownOne 単体: 実機 iOS で「宣言値では引けないが解決後 UDID なら引ける」lease を見落とさない
/// ことを固定する。devicectl は叩かない(`physicalIOSDevices` へ注入した一覧をそのまま使う)。
final class DeviceBooterShutdownOnePhysicalIOSDualKeyTests: XCTestCase {

    private func makeStateDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    // 戻すと落ちる根拠: shutdownOne が leaseKey(=宣言値のみ)しか見ていなければ、この lease
    // (解決後 UDID にしか無い)を見落として素通りし、拒否せず成功で返ってしまう
    func testRefusesWhenOnlyTheResolvedUDIDHoldsALease() async {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let holder = getppid()
        let resolvedUDID = "HW-UDID-1"
        RunLease.write(stateDir: dir, key: resolvedUDID, pid: holder)
        let spec = DeviceSpec(name: "iPhone-DeclaredIdentifier", kind: .physical,
                              udid: "DEVICECTL-IDENTIFIER-1")
        let fakeDevice = IOSPhysicalDeviceInfo(
            udid: resolvedUDID, name: "iPhone 15 Pro", os: "iOS 18.5", connected: true,
            transport: "wired", deviceCtlIdentifier: "DEVICECTL-IDENTIFIER-1")

        do {
            try await DeviceBooter.shutdownOne(
                spec: spec, platform: "ios", repoRoot: nil, leaseStateDir: dir,
                physicalIOSDevices: [fakeDevice], log: { _ in })
            XCTFail("解決後 UDID にある lease を見落として素通りしてはいけない")
        } catch let error as DeviceBooterError {
            guard case .commandFailed(let message) = error else {
                XCTFail("expected .commandFailed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("iPhone-DeclaredIdentifier"), "台名を名指しする")
            XCTAssertTrue(message.contains("\(holder)"), "保持者 pid を名指しする")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // 宣言値と解決後 UDID が一致する(通常の)構成では、これまでどおり1つの鍵として扱われる
    func testRefusesWhenTheDeclaredUDIDHoldsALeaseAndNoResolutionIsNeeded() async {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let holder = getppid()
        RunLease.write(stateDir: dir, key: "HW-UDID-2", pid: holder)
        let spec = DeviceSpec(name: "iPhone-Direct", kind: .physical, udid: "HW-UDID-2")

        do {
            try await DeviceBooter.shutdownOne(
                spec: spec, platform: "ios", repoRoot: nil, leaseStateDir: dir,
                physicalIOSDevices: [], log: { _ in })
            XCTFail("宣言値の lease は従来どおり拒否されるはず")
        } catch let error as DeviceBooterError {
            guard case .commandFailed = error else {
                XCTFail("expected .commandFailed, got \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testForceBypassesEvenTheResolvedUDIDLease() async throws {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolvedUDID = "HW-UDID-3"
        RunLease.write(stateDir: dir, key: resolvedUDID, pid: getppid())
        let spec = DeviceSpec(name: "iPhone-DeclaredIdentifier", kind: .physical,
                              udid: "DEVICECTL-IDENTIFIER-3")
        let fakeDevice = IOSPhysicalDeviceInfo(
            udid: resolvedUDID, name: "iPhone 15 Pro", os: "iOS 18.5", connected: true,
            transport: "wired", deviceCtlIdentifier: "DEVICECTL-IDENTIFIER-3")

        // repoRoot が無いのでブリッジ停止は行わず、実機は「ブリッジだけ停止」で成功して返る
        // (拒否さえ起きなければここまで到達することの確認)
        try await DeviceBooter.shutdownOne(
            spec: spec, platform: "ios", repoRoot: nil, force: true, leaseStateDir: dir,
            physicalIOSDevices: [fakeDevice], log: { _ in })
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

        let profile = DeviceRoster(
            ios: DeviceRosterList(devices: [
                DeviceSpec(name: "iPhone-Held", kind: .physical, udid: heldUDID),
                DeviceSpec(name: "iPhone-Free", kind: .physical, udid: "00008130-BBBB"),
            ]),
            android: DeviceRosterList(devices: [
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

        let profile = DeviceRoster(ios: DeviceRosterList(devices: [
            DeviceSpec(name: "iPhone-Held", kind: .physical, udid: heldUDID),
        ]))
        let stopped = LockedBox([String]())
        let outcomes = await DeviceBooter.shutdownAll(
            machine: profile, repoRoot: nil, force: true, leaseStateDir: dir, log: { _ in },
            stopOne: { spec, _ in stopped.mutate { $0.append(spec.name) } })

        XCTAssertEqual(stopped.value, ["iPhone-Held"])
        XCTAssertEqual(outcomes.first?.succeeded, true)
    }

    // 実機 iOS の宣言値(devicectl の Identifier)では lease が引けず、解決後のハードウェア UDID
    // でしか引けない構成。`physicalIOSDevices` を注入するので devicectl は叩かない
    // (nil のままだと `repoRoot: nil` でも呼ばれない設計だが、注入して呼ばれ得ないことを明示する)。
    // 戻すと落ちる根拠: shutdownAll が宣言値の鍵しか見ていなければ、この lease を見落として
    // stopOne を呼んでしまう
    func testResolvedUDIDOnlyLeaseIsRefusedEvenWhenDeclaredUDIDDiffers() async throws {
        let dir = makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let holder = getppid()
        let resolvedUDID = "HW-UDID-9"
        RunLease.write(stateDir: dir, key: resolvedUDID, pid: holder)

        let profile = DeviceRoster(ios: DeviceRosterList(devices: [
            DeviceSpec(name: "iPhone-Declared", kind: .physical, udid: "DEVICECTL-IDENTIFIER-9"),
        ]))
        let fakeDevice = IOSPhysicalDeviceInfo(
            udid: resolvedUDID, name: "iPhone 15 Pro", os: "iOS 18.5", connected: true,
            transport: "wired", deviceCtlIdentifier: "DEVICECTL-IDENTIFIER-9")
        let stopped = LockedBox([String]())
        let outcomes = await DeviceBooter.shutdownAll(
            machine: profile, repoRoot: nil, leaseStateDir: dir,
            physicalIOSDevices: [fakeDevice], log: { _ in },
            stopOne: { spec, _ in stopped.mutate { $0.append(spec.name) } })

        XCTAssertTrue(stopped.value.isEmpty, "解決後 UDID の lease を見落として stopOne を呼んではいけない")
        XCTAssertEqual(outcomes.first?.succeeded, false)
        XCTAssertTrue(outcomes.first?.failure?.contains("iPhone-Declared") ?? false)
        XCTAssertTrue(outcomes.first?.failure?.contains("\(holder)") ?? false)
    }
}
