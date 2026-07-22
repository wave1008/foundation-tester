// マシンプロファイルに定義されたデバイスの起動・停止。
// - bootAll: 全デバイスの並行起動(最大2台同時)。1台を「ブート →(iOS)ブリッジ供給」まで
//   完結させてから次のデバイスへ進む(同時進行が2台を超えないこと自体が要件)
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

    /// 起動済みはスキップ。最大 maxConcurrent 台まで同時進行する(既定2はユーザー決定 2026-07-16:
    /// 固定値。この上限がブートストーム防止を兼ねる。旧実装の CPU 負荷ゲートは同決定で廃止)。
    /// ワーカーは1台を「ブート →(repoRoot 指定時の iOS)ブリッジ供給」まで完結させてから次へ進む。
    /// 「同時進行が maxConcurrent 台を超えて見えない」こと自体が要件(ユーザー決定 2026-07-16。
    /// ブート完了分を束ねる供給バッチ化 ProvisionBatcher は速いが同時進行が上限を超えるため撤回。
    /// 再検討時は git 履歴参照)。
    /// deviceFinished は成否問わず必ず呼ばれる(呼び出し側の再スキャン契約)。
    public static func bootAll(
        machine: MachineProfile,
        repoRoot: URL? = nil,
        maxConcurrent: Int = 2,
        restartNames: Set<String> = [],
        log: @escaping @Sendable (String) -> Void,
        deviceStopping: @escaping @Sendable (String, String) -> Void = { _, _ in },
        deviceStarting: @escaping @Sendable (String, String) -> Void = { _, _ in },
        deviceFinished: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) async {
        // iOS(軽い)を先頭に、Android(重い)を後ろに並べた早い者勝ちキュー。各プラットフォーム内は
        // name 昇順に整列してモニタータイルの表示順(左→右)と起動順を一致させる(表示規則の同期相手:
        // vscode-ftester/src/monitorModel.ts sortMonitorDevices「ios→android・各内は name 順」。
        // プロファイル JSON の配列順は name 順とは限らず、放置すると左→右と起動順がずれる)。
        // localizedCompare で JS localeCompare 相当。
        //
        // restartNames: 強制再起動(down→up)するデバイス論理名(CPU 描画フォールバック機の GPU 復帰用)。
        // 同一キューの先頭に置き、通常ブート項目からは除外する(同じデバイスを2ワーカーが同時に
        // 触る競合を防ぐ)。ジョブを分けず1キューに混載することで、種別を問わず常に最大
        // maxConcurrent 台だけが起動処理中になる(再起動の端数で並行枠が遊ばない)。
        let restartItems = ((machine.ios?.devices ?? []).map { ($0, "ios") }
            + (machine.android?.devices ?? []).map { ($0, "android") })
            .filter { restartNames.contains($0.0.name) }
            .sorted { $0.0.name.localizedCompare($1.0.name) == .orderedAscending }
            .map { BootItem(spec: $0.0, platform: $0.1, restart: true) }
        let iosItems = (machine.ios?.devices ?? [])
            .filter { !restartNames.contains($0.name) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            .map { BootItem(spec: $0, platform: "ios", restart: false) }
        let androidItems = (machine.android?.devices ?? [])
            .filter { !restartNames.contains($0.name) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            .map { BootItem(spec: $0, platform: "android", restart: false) }
        let items = restartItems + iosItems + androidItems
        guard !items.isEmpty else { return }

        let queue = BootQueue(items)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<max(1, min(maxConcurrent, items.count)) {
                group.addTask {
                    while let item = await queue.next() {
                        await bootItem(item, repoRoot: repoRoot,
                                       log: log, deviceStopping: deviceStopping,
                                       deviceStarting: deviceStarting,
                                       deviceFinished: deviceFinished)
                    }
                }
            }
        }
    }

    private struct BootItem: Sendable {
        let spec: DeviceSpec
        let platform: String
        let restart: Bool
    }

    private actor BootQueue {
        private var items: [BootItem]
        init(_ items: [BootItem]) { self.items = items }
        func next() -> BootItem? { items.isEmpty ? nil : items.removeFirst() }
    }

    /// 1 デバイス分の起動処理(ブート → iOS はブリッジ供給まで完結)。deviceFinished は
    /// 成否問わず末尾で必ず呼ぶ。restart 項目は起動済みでもスキップせず down→up する
    /// (GPU モードは起動時固定のため、CPU 描画からの復帰は再起動でしか行えない)
    private static func bootItem(
        _ item: BootItem, repoRoot: URL?,
        log: @escaping @Sendable (String) -> Void,
        deviceStopping: @escaping @Sendable (String, String) -> Void,
        deviceStarting: @escaping @Sendable (String, String) -> Void,
        deviceFinished: @escaping @Sendable (String, String) -> Void
    ) async {
        let spec = item.spec
        do {
            if item.restart {
                deviceStopping(spec.name, item.platform)
                try await shutdownOne(spec: spec, platform: item.platform,
                                      repoRoot: item.platform == "ios" ? repoRoot : nil, log: log)
                deviceStarting(spec.name, item.platform)
                try await bootOne(spec: spec, platform: item.platform, log: log)
            } else if let running = runningDescription(spec: spec, platform: item.platform) {
                deviceStarting(spec.name, item.platform)
                log("✔ \(spec.name): 起動済み(\(running))")
            } else {
                deviceStarting(spec.name, item.platform)
                try await bootOne(spec: spec, platform: item.platform, log: log)
            }
            if item.platform == "ios", let repoRoot {
                // 稼働中ブリッジは provision() が再利用するので起動済みデバイスでも安全。
                // 複数ワーカーの provision() 同時実行はその内部の ProvisionLock(flock)が
                // 直列化する(同一プロセス内の別 fd 同士でも排他が効く。ProvisionLockTests 参照)
                _ = try await BridgeProvisioner(repoRoot: repoRoot)
                    .provision(devices: [(spec.name, spec)], log: log)
            }
        } catch {
            log("❌ \(spec.name): \(error.localizedDescription)")
        }
        deviceFinished(spec.name, item.platform)
    }

    /// 1 台起動(起動済みなら何もしない)
    public static func bootOne(spec: DeviceSpec, platform: String, gpuMode: String = "host",
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
            let serial = try await startEmulator(avd: avdID, gpuMode: gpuMode)
            try await waitForAndroidBoot(serial: serial)
            await applyLocale(serial: serial, locale: defaultLocale, deviceName: spec.name, log: log)
            log("✅ \(spec.name): 起動完了(\(serial))")
        }
    }

    /// device-up 経由のブートに適用する既定ロケール(実行プロファイル locale が届くのは
    /// AndroidDataWiper の wipe 後再起動経路のみ。ユーザー既定 = ja_JP)
    public static let defaultLocale = "ja_JP"

    /// ブート完了後のロケール適用(ブリッジ /locale。Play イメージでは root/-change-locale/
    /// settings put が全て無効のため、これが唯一の手段)。ブリッジ未導入なら自動導入される。
    /// 一致時は no-op(changed=false)。失敗は非致命(ブート自体は成功扱い)
    static func applyLocale(serial: String, locale: String, deviceName: String,
                            log: @escaping @Sendable (String) -> Void) async {
        do {
            let result = try await AndroidDriver(serial: serial).setDeviceLocale(locale)
            if result.changed {
                log("→ \(deviceName): ロケールを \(result.locale) に設定しました")
            }
        } catch {
            log("⚠️ \(deviceName): ロケール設定に失敗 — \(error.localizedDescription)")
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
                // simctl が稀に応答不能になるため時限化(30s)。締切ループが無効化するのを防ぐ。
                lastResult = try Shell.run(["xcrun", "simctl", "shutdown", sim.udid], timeout: 30)
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
            _ = try Shell.run([adb, "-s", serial, "emu", "kill"], timeout: 10)
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
    /// 並行起動時に他デバイスの serial を拾わないよう、新規 serial の AVD 名を照合する。
    /// locale の -change-locale は **Play イメージ(フリート全機)では無効**(実測 2026-07-17。
    /// AOSP イメージ向けの保険として残置)。実効的なロケール適用はブート完了後の applyLocale
    /// (ブリッジ /locale)が担う
    static func startEmulator(avd: String, gpuMode: String = "host", locale: String? = "ja_JP") async throws -> String {
        let binary = try findEmulatorBinary()
        let adbPath = try AndroidDriver.findADB()
        let before = Set((try? AndroidDeviceCatalog.connectedSerials()) ?? [])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // -gpu host 必須: headless(-no-window)では hw.gpu.mode=auto が SwiftShader(CPU 描画)に
        // フォールバックし、モーション時 qemu が約3コア/台を消費する(host=Metal なら約1/3。実測 2026-07-14)
        // gpuMode 既定は host。swiftshader_indirect は軽い修復で直らない凍結個体のみ呼び出し側が
        // 指定する(CPU 描画は凍結を回避できるが上記の約3コア/台を払う)
        // -no-snapshot 必須: ロード+セーブ両方の無効化=コールドブート保証。Quickboot スナップショットの
        // ロードはブート時黒画面の代表原因(旧 -no-snapshot-save はセーブのみ無効で、Android Studio 等が
        // 残したスナップショットがあるとロードしてしまう。docs/performance-tuning.md §6 の Wipe Data 行参照)
        var arguments = ["-avd", avd,
                         "-no-snapshot", "-no-window", "-no-boot-anim", "-no-audio",
                         "-gpu", gpuMode]
        if let locale {
            arguments += ["-change-locale", locale.replacingOccurrences(of: "_", with: "-")]
        }
        process.arguments = arguments
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
        // serial を掴めないまま放置すると、起動済みエミュレータが参照されないまま ~3コアを消費し続ける
        // (次回スキャンで自己回復するが当該 run 中は resource を食う)。失敗経路では明示終了する。
        process.terminate()
        throw DeviceBooterError.commandFailed(
            "エミュレータの serial を検出できません(\(avd)。AVD 名が正しいか確認してください)")
    }

    /// sys.boot_completed=1 までポーリング(既定 180 秒)
    static func waitForAndroidBoot(serial: String, timeout: TimeInterval = 180) async throws {
        let adb = try AndroidDriver.findADB()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let output = try? Shell.run(
                [adb, "-s", serial, "shell", "getprop", "sys.boot_completed"], timeout: 10).output,
               output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        throw DeviceBooterError.bootTimedOut(serial: serial)
    }
}

