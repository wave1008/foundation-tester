// マシンプロファイルに定義されたデバイスの起動・停止。
// - bootAll: 全デバイスの段階的起動。一斉起動はマシンが固まるため、
//   1 台ずつ「負荷ゲート(loadavg)→ 起動 → ブート完了待ち」を繰り返す
// - bootOne / shutdownOne: 1 台単位の起動・停止(モニターのプレースホルダー右クリック等)
// iOS = simctl bootstatus -b / shutdown(ヘッドレス)、Android = emulator -avd(-no-window)/ emu kill。

import Foundation
import FTBridgeClient
import FTCore

public enum DeviceBooterError: Error, LocalizedError {
    case emulatorBinaryNotFound
    case bootTimedOut(serial: String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emulatorBinaryNotFound:
            return "emulator コマンドが見つかりません(ANDROID_HOME を設定するか SDK に emulator/ を導入)"
        case .bootTimedOut(let serial):
            return "ブート完了を確認できませんでした(\(serial))"
        case .commandFailed(let detail):
            return detail
        }
    }
}

public enum DeviceBooter {

    /// 起動済みはスキップ。完全逐次だと負荷低下後も無駄に待つため、最大 maxConcurrent(既定2)台まで
    /// 同時起動する(各自が負荷ゲートを通ってから起動するのでブートストームにはならない)。
    /// repoRoot 指定時は iOS シミュレータ起動直後にブリッジも供給し、「起動済みだがブリッジ未接続」の
    /// 中間状態を見せない。deviceFinished は成否問わず必ず呼ばれる(呼び出し側の再スキャン契約)。
    public static func bootAll(
        machine: MachineProfile,
        repoRoot: URL? = nil,
        maxConcurrent: Int = 2,
        log: @escaping @Sendable (String) -> Void,
        deviceStarting: @escaping @Sendable (String, String) -> Void = { _, _ in },
        deviceFinished: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) async {
        // iOS(軽い)を先頭に、Android(重い)を後ろに並べた早い者勝ちキュー
        var items = (machine.ios?.devices ?? []).map { BootItem(spec: $0, platform: "ios") }
        items += (machine.android?.devices ?? []).map { BootItem(spec: $0, platform: "android") }
        guard !items.isEmpty else { return }

        let queue = BootQueue(items)
        // ブリッジ供給は空きポート採番が競合するため直列化する(起動自体は並行)
        let provisionLock = AsyncSemaphore(1)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<max(1, min(maxConcurrent, items.count)) {
                group.addTask {
                    while let item = await queue.next() {
                        await bootItem(item, repoRoot: repoRoot, provisionLock: provisionLock,
                                       log: log, deviceStarting: deviceStarting,
                                       deviceFinished: deviceFinished)
                    }
                }
            }
        }
    }

    private struct BootItem: Sendable {
        let spec: DeviceSpec
        let platform: String
    }

    private actor BootQueue {
        private var items: [BootItem]
        init(_ items: [BootItem]) { self.items = items }
        func next() -> BootItem? { items.isEmpty ? nil : items.removeFirst() }
    }

    /// 並行実行の直列化用セマフォ(actor はサスペンションをまたいで排他しないため明示的に持つ)
    private actor AsyncSemaphore {
        private var available: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(_ count: Int) { available = count }
        func wait() async {
            if available > 0 {
                available -= 1
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }
        func signal() {
            if waiters.isEmpty {
                available += 1
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    /// 1 デバイス分の起動処理(負荷ゲート → 起動 → iOS はブリッジ供給)
    private static func bootItem(
        _ item: BootItem, repoRoot: URL?, provisionLock: AsyncSemaphore,
        log: @escaping @Sendable (String) -> Void,
        deviceStarting: @escaping @Sendable (String, String) -> Void,
        deviceFinished: @escaping @Sendable (String, String) -> Void
    ) async {
        let spec = item.spec
        deviceStarting(spec.name, item.platform)
        do {
            if let running = runningDescription(spec: spec, platform: item.platform) {
                log("✔ \(spec.name): 起動済み(\(running))")
            } else {
                await waitForLoadSettle(name: spec.name, log: log)
                try await bootOne(spec: spec, platform: item.platform, log: log)
            }
            if item.platform == "ios", let repoRoot {
                // 稼働中ブリッジは再利用されるので起動済みデバイスでも安全
                await provisionLock.wait()
                do {
                    _ = try await BridgeProvisioner(repoRoot: repoRoot)
                        .provision(devices: [(spec.name, spec)], log: log)
                    await provisionLock.signal()
                } catch {
                    await provisionLock.signal()
                    throw error
                }
            }
        } catch {
            log("❌ \(spec.name): \(error.localizedDescription)")
        }
        deviceFinished(spec.name, item.platform)
    }

    /// 1 台起動(起動済みなら何もしない)
    public static func bootOne(spec: DeviceSpec, platform: String,
                               log: @escaping @Sendable (String) -> Void) async throws {
        if platform == "ios" {
            let sim = try SimulatorCatalog.resolve(spec: spec, in: SimulatorCatalog.devices())
            guard !sim.booted else {
                log("✔ \(spec.name): 起動済み(\(sim.name))")
                return
            }
            log("→ \(spec.name): シミュレータ起動(\(sim.name) \(sim.os))...")
            // bootstatus -b は起動してブート完了までブロックする
            let result = try Shell.run(["xcrun", "simctl", "bootstatus", sim.udid, "-b"])
            guard result.status == 0 else {
                throw DeviceBooterError.commandFailed("simctl bootstatus: \(result.tail)")
            }
            log("✅ \(spec.name): 起動完了(\(sim.name))")
        } else {
            guard let avd = spec.avd else {
                throw DeviceBooterError.commandFailed(
                    "avd 指定がありません(マシンプロファイルに \"avd\" を追加してください)")
            }
            let avdID = AndroidDeviceCatalog.canonicalAVDID(avd)
            if let serial = try? AndroidDeviceCatalog.runningAVDs()
                .first(where: { $0.value == avdID })?.key {
                log("✔ \(spec.name): 起動済み(\(serial))")
                return
            }
            log("→ \(spec.name): エミュレータ起動(\(avdID))...")
            let serial = try await startEmulator(avd: avdID)
            try await waitForAndroidBoot(serial: serial)
            log("✅ \(spec.name): 起動完了(\(serial))")
        }
    }

    /// 未起動なら何もしない。repoRoot 指定時(iOSのみ)は simctl shutdown 前に稼働ブリッジを探して
    /// 停止する(放置するとブリッジプロセス/pidファイルがゾンビ化しポート採番がずれていく)。
    /// iOS の exit code 不信任リトライの理由は下記コメント参照。
    public static func shutdownOne(spec: DeviceSpec, platform: String,
                                   repoRoot: URL? = nil,
                                   log: @escaping @Sendable (String) -> Void) async throws {
        if platform == "ios" {
            let catalog = try SimulatorCatalog.devices()
            let sim = try SimulatorCatalog.resolve(spec: spec, in: catalog)
            // ブリッジ停止は booted ガードより先に、pid ファイル+プロセス引数の UDID 照合で行う
            // (stopMatching 参照)。①hybrid は同一シミュに複数ブリッジ ②/status 無応答のゾンビ
            // xcodebuild は HTTP スキャン不可視 ③シミュ停止済みでもゾンビが残っていると生きた
            // XCUITest セッションがシミュレータを再ブートさせ「停止したのに起動中に戻る」症状になる
            if let repoRoot {
                for port in BridgeLauncher.stopMatching(udid: sim.udid, repoRoot: repoRoot) {
                    log("→ \(spec.name): ブリッジ停止(port \(port))")
                }
            }
            guard sim.booted else {
                log("✔ \(spec.name): 既に停止しています")
                return
            }
            // macOS 27 beta 3: simctl shutdown は「Unable to shutdown...」(405)を返しつつ実際には
            // Booted のまま残るレースがあるため、exit code でなくカタログの実状態で成否判定する
            var lastResult: Shell.Result?
            for attempt in 1...3 {
                lastResult = try Shell.run(["xcrun", "simctl", "shutdown", sim.udid])
                let stillBooted = (try? SimulatorCatalog.devices())?
                    .first(where: { $0.udid == sim.udid })?.booted ?? false
                if !stillBooted {
                    log("✅ \(spec.name): シミュレータを停止しました(\(sim.name))")
                    return
                }
                if attempt < 3 {
                    log("→ \(spec.name): 停止が反映されないため再試行(\(attempt)/3)...")
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            throw DeviceBooterError.commandFailed(
                "simctl shutdown: 3回試行してもシミュレータが停止しません(最後の出力: \(lastResult?.tail ?? ""))")
        } else {
            let serial = try AndroidDeviceCatalog.resolveSerial(spec: spec)
            let adb = try AndroidDriver.findADB()
            _ = try Shell.run([adb, "-s", serial, "emu", "kill"])
            log("✅ \(spec.name): エミュレータを停止しました(\(serial))")
        }
    }

    /// 起動中ならその説明("iPhone 17 Pro" / "emulator-5554")、未起動なら nil
    static func runningDescription(spec: DeviceSpec, platform: String) -> String? {
        if platform == "ios" {
            guard let sim = try? SimulatorCatalog.resolve(
                spec: spec, in: SimulatorCatalog.devices()), sim.booted else { return nil }
            return sim.name
        }
        guard let avd = spec.avd else { return nil }
        let avdID = AndroidDeviceCatalog.canonicalAVDID(avd)
        return (try? AndroidDeviceCatalog.runningAVDs())?
            .first(where: { $0.value == avdID })?.key
    }

    // MARK: - 負荷ゲート

    /// CPU使用率が90%を下回るまで待つ(上限90秒、超えたら続行)。1分間ロードアベレージは
    /// 反応が遅く直前ブートの余波を引きずるため、5秒窓の実測値(host_statisticsのtick差分)で判定する
    static func waitForLoadSettle(name: String = "", timeout: TimeInterval = 90,
                                  log: @escaping @Sendable (String) -> Void) async {
        let limit = 0.9
        let prefix = name.isEmpty ? "" : "\(name): "
        let deadline = Date().addingTimeInterval(timeout)
        var announced = false
        while Date() < deadline {
            let usage = await cpuUsage(over: 5)
            if usage < limit { return }
            if !announced {
                log(String(format: "⏳ \(prefix)負荷が落ち着くのを待ってから起動します(CPU %.0f%% / しきい値 %.0f%%)",
                           usage * 100, limit * 100))
                announced = true
            }
        }
        log("⚠️ \(prefix)負荷が高いままですが起動を続行します")
    }

    static func cpuUsage(over seconds: TimeInterval) async -> Double {
        guard let start = cpuTicks() else { return 0 }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard let end = cpuTicks() else { return 0 }
        let busy = Double((end.user &- start.user) &+ (end.system &- start.system)
                          &+ (end.nice &- start.nice))
        let total = busy + Double(end.idle &- start.idle)
        return total > 0 ? busy / total : 0
    }

    /// host_statistics(HOST_CPU_LOAD_INFO)の累積 tick(user/system/idle/nice)
    private static func cpuTicks() -> (user: UInt64, system: UInt64,
                                       idle: UInt64, nice: UInt64)? {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1),
                UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3))
    }

    // MARK: - Android

    /// emulator バイナリの場所: ANDROID_HOME/ANDROID_SDK_ROOT → adb からの相対
    static func findEmulatorBinary() throws -> String {
        let fm = FileManager.default
        for env in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = ProcessInfo.processInfo.environment[env] {
                let path = root + "/emulator/emulator"
                if fm.isExecutableFile(atPath: path) { return path }
            }
        }
        if let adb = try? AndroidDriver.findADB() {
            // <sdk>/platform-tools/adb → <sdk>/emulator/emulator
            let sdk = URL(fileURLWithPath: adb)
                .deletingLastPathComponent().deletingLastPathComponent()
            let path = sdk.appendingPathComponent("emulator/emulator").path
            if fm.isExecutableFile(atPath: path) { return path }
        }
        throw DeviceBooterError.emulatorBinaryNotFound
    }

    /// エミュレータをヘッドレスでデタッチ起動し、serial(自動採番)を検出して返す(検出待ち上限60秒)。
    /// 並行起動時に他デバイスの serial を拾わないよう、新規 serial の AVD 名を照合する
    static func startEmulator(avd: String) async throws -> String {
        let binary = try findEmulatorBinary()
        let adbPath = try AndroidDriver.findADB()
        let before = Set((try? AndroidDeviceCatalog.connectedSerials()) ?? [])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-avd", avd,
                             "-no-snapshot-save", "-no-window", "-no-boot-anim", "-no-audio"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let now = Set((try? AndroidDeviceCatalog.connectedSerials()) ?? [])
            for serial in now.subtracting(before) where serial.hasPrefix("emulator-") {
                if AndroidDeviceCatalog.avdName(adbPath: adbPath, serial: serial) == avd {
                    return serial
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw DeviceBooterError.commandFailed(
            "エミュレータの serial を検出できません(\(avd)。AVD 名が正しいか確認してください)")
    }

    /// sys.boot_completed=1 までポーリング(既定 180 秒)
    static func waitForAndroidBoot(serial: String, timeout: TimeInterval = 180) async throws {
        let adb = try AndroidDriver.findADB()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let output = try? Shell.run(
                [adb, "-s", serial, "shell", "getprop", "sys.boot_completed"]).output,
               output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        throw DeviceBooterError.bootTimedOut(serial: serial)
    }
}
