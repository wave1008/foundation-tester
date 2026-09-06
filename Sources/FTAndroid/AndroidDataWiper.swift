// 実行開始時(ProfileWorkerFactory 経由)に Android AVD の肥大化を検査し、しきい値超過なら
// Wipe Data する。wipe 対象ファイル集合は Android Studio の Wipe Data と同一
// (userdata-qemu.img[.qcow2] / cache.img[.qcow2] / snapshots/。sdcard.img は消さない)。
// 稼働中エミュレータの下では削除しない: kill→serial 消失確認が取れた場合のみ削除する。

import FTEmulatorGrpc
import Foundation
import FTCore

public enum AndroidDataWiperError: Error, LocalizedError, Equatable {
    case avdDirectoryNotFound(avd: String, path: String)
    /// 停止を確認できないまま締切に達した(**1バイトも消していない**)。稼働中のエミュレータの
    /// 下からイメージを抜くと qemu がクラッシュして AVD が壊れるので、確認が取れないなら中止する
    case stopNotConfirmed(device: String, serial: String, seconds: Int)
    /// 走っているかどうかを決められない(**1バイトも消していない**)。qemu のプロセスは居るのに
    /// adb が serial を出さない・ps が読めず offline の台がある等、止める宛先を引けない形
    case runningStateUnknown(device: String, avd: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .avdDirectoryNotFound(let avd, let path):
            return "AVD directory not found for \(avd) (\(path))"
        case .stopNotConfirmed(let device, let serial, let seconds):
            return "\(device): could not confirm the emulator stopped within \(seconds)s (\(serial))"
                + " — nothing was wiped. Stop it and try again"
        case .runningStateUnknown(let device, let avd, let reason):
            return "\(device): cannot tell whether \(avd) is running (\(reason)); not deleting"
                + " — nothing was wiped. Stop it and try again"
        }
    }
}

public enum AndroidDataWiper {

    private enum RunningState: Equatable {
        case wasRunning, wasNotRunning
    }

    private struct Candidate {
        let device: ResolvedDevice
        let avdID: String
        let targets: [URL]
        let sizeBytes: Int64
        var sizeGB: String { String(format: "%.1f", Double(sizeBytes) / 1_073_741_824) }
    }

    /// android デバイスのみ処理。wipe を実行したデバイス名の配列を返す(失敗はログして継続)。
    /// 1台ずつ直列処理(稼働中エミュレータの kill/再起動を並列化すると事故りやすいため)。
    /// 停止待ち〜再ブートは1台数分の無音区間になるため、各フェーズの開始を必ずログする
    /// (GUI は stderr を出力チャネルへ逐次表示する。runHandler.ts 参照)。
    /// status はデバイス単位のフェーズ通知(デバイス名, "stopping"|"rebooting"|"done"|"failed")。
    /// ApiRunCommand が NDJSON の wipeStatus イベントに変換する(同期相手:
    /// vscode-fleetest/src/model.ts の WipeStatusEvent)
    public static func wipeBloatedAVDs(
        devices: [ResolvedDevice], thresholdGB: Double, locale: String,
        status: (@Sendable (String, String) -> Void)? = nil,
        log: @escaping @Sendable (String) -> Void
    ) async -> [String] {
        let thresholdBytes = Int64((thresholdGB * 1_073_741_824).rounded())

        var candidates: [Candidate] = []
        for device in devices where device.platform == "android" {
            // 実機に AVD ディレクトリは無い(警告も出さない。毎 run のノイズにしかならない)
            if device.spec.isPhysical { continue }
            guard let avd = device.spec.avd else {
                log("⚠️ \(device.name): no avd set — skipping the Wipe Data check")
                continue
            }
            let avdID = AndroidDeviceCatalog.canonicalAVDID(avd)
            // <id>.avd 直組みは不可(ini の path が別名ディレクトリを指すことがある。カタログ側コメント参照)
            let avdDir = AndroidDeviceCatalog.avdContentDirectory(id: avdID)
            guard FileManager.default.fileExists(atPath: avdDir.path) else {
                log("⚠️ \(device.name): AVD directory not found — "
                    + "skipping the Wipe Data check (\(avdDir.path))")
                continue
            }
            let targets = wipeTargets(avdDir: avdDir)
            let size = totalSize(paths: targets)
            if size > thresholdBytes {
                candidates.append(Candidate(device: device, avdID: avdID,
                                            targets: targets, sizeBytes: size))
            }
        }
        guard !candidates.isEmpty else { return [] }

        let list = candidates.map { "\($0.device.name)(\($0.sizeGB)GB)" }.joined(separator: ", ")
        log("🧹 Wipe Data targets: \(candidates.count) device(s) (over the "
            + String(format: "%.1f", thresholdGB) + "GB threshold): \(list)")
        log("   Guests will be reset (stop → wipe → reboot, one at a time; rebuilding takes minutes per device. "
            + "Locale \(locale) is re-applied automatically after the reboot)")

        var wiped: [String] = []
        for (index, candidate) in candidates.enumerated() {
            let name = candidate.device.name
            let progress = "\(index + 1)/\(candidates.count)"
            do {
                try await performWipe(
                    name: name, avdID: candidate.avdID, targets: candidate.targets,
                    sizeGB: candidate.sizeGB, progress: progress, locale: locale,
                    status: { phase in status?(name, phase) }, log: log)
                wiped.append(name)
            } catch {
                log("❌ \(name): Wipe Data failed — \(error.localizedDescription)")
                status?(name, "failed")
            }
        }
        return wiped
    }

    /// 1台ぶんの Wipe Data(しきい値を見ない。手元/リモートの手動実行 =
    /// `fleetest api device-wipe` から DeviceWiper 経由で呼ぶ)。**肥大化チェックの経路と
    /// 同じ本体**(performWipe)を通す —— 停止できたときだけ消す・稼働中だった台だけ起こし直す、
    /// という規律を2箇所に持たない。AVD ディレクトリが見つからないのは失敗
    /// (自動チェックは毎 run のノイズになるので警告して飛ばすが、人が選んで撃った1台は黙って
    /// 成功にしてはいけない)。
    /// status のフェーズ("stopping"/"rebooting"/"done"/"failed")は wipeBloatedAVDs と同じ集合。
    public static func wipeOne(
        deviceName: String, avd: String, locale: String,
        status: (@Sendable (String) -> Void)? = nil,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        let avdID = AndroidDeviceCatalog.canonicalAVDID(avd)
        let avdDir = AndroidDeviceCatalog.avdContentDirectory(id: avdID)
        guard FileManager.default.fileExists(atPath: avdDir.path) else {
            throw AndroidDataWiperError.avdDirectoryNotFound(avd: avdID, path: avdDir.path)
        }
        let targets = wipeTargets(avdDir: avdDir)
        let sizeGB = String(format: "%.1f", Double(totalSize(paths: targets)) / 1_073_741_824)
        do {
            try await performWipe(
                name: deviceName, avdID: avdID, targets: targets, sizeGB: sizeGB,
                progress: "1/1", locale: locale, status: status, log: log)
        } catch {
            status?("failed")
            throw error
        }
    }

    /// 1台ぶんの本体: 停止 → 削除 → (稼働中だった台だけ)再起動+ロケール適用。
    /// **停止を確認できなければ1バイトも消さない**(稼働中エミュレータの下からイメージを
    /// 抜くと qemu がクラッシュし、AVD が壊れて作り直しになる)。戻り値は消したかどうか。
    private static func performWipe(
        name: String, avdID: String, targets: [URL], sizeGB: String, progress: String,
        locale: String, status: (@Sendable (String) -> Void)?,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        log("🧹 \(name): wiping data (\(progress)) — stopping the emulator...")
        status?("stopping")
        // 停止を確認できなければ **throw**(呼び手が失敗として扱う)。**false を返して成功扱いに
        // しない** —— 「消えていないのに成功」は、この案件で最も避けたい誤った緑そのもの
        // (2026-08-29 に実際に起きた: 台が止まっただけで中身は残り、利用者には ok:true が返った)
        let running = try await stopIfRunning(avdID: avdID, deviceName: name, log: log)

        for target in targets {
            try? FileManager.default.removeItem(at: target)
        }

        if running == .wasRunning {
            log("🧹 \(name): data wiped (freed \(sizeGB)GB). "
                + "Rebooting (the first boot rebuilds and takes minutes)...")
            status?("rebooting")
            let serial = try await DeviceBooter.startEmulator(avd: avdID, locale: locale)
            try await DeviceBooter.waitForAndroidBoot(serial: serial)
            // Play イメージでは -change-locale が無効のため、ブリッジ /locale で適用する
            await DeviceBooter.applyLocale(serial: serial, locale: locale,
                                           deviceName: name, log: log)
            log("✅ \(name): Wipe Data finished (\(progress))")
        } else {
            log("✅ \(name): Wipe Data finished (\(progress), freed \(sizeGB)GB; "
                + "not running, so no reboot)")
        }
        status?("done")
    }

    /// 停止確認の締切(秒)。**この時間内に消えなければ削除へ進まない**(消したい相手より
    /// 「稼働中のイメージを抜かない」ほうが重い)。フリート実行中の kill は adb の応答が詰まって
    /// 数十秒かかることがあるため 60 秒(2026-08-29 に 30 秒では取り切れず中止した実例あり)
    private static let stopConfirmSeconds = 60

    /// 起動中なら emu kill → **停止したことの確認**を待つ。確認は2つのどちらかで取れればよい:
    ///   ① adb の serial が消えた ② **その AVD の qemu プロセスが消えた**
    /// ②を併せて見るのは、adb 側が詰まっている(まさに kill が遅い状況)ときに①だけだと
    /// 「本当は止まっているのに確認が取れない」で中止してしまうため。**どちらも取れなければ throw**
    /// (削除には進まない。呼び手は失敗として扱う)
    private static func stopIfRunning(
        avdID: String, deviceName: String, log: @escaping (String) -> Void
    ) async throws -> RunningState {
        // adb が失敗したら「空」として扱い、判定は発見ファイル・ps に委ねる(adb 死 = 走っていない、
        // ではない)。発見ファイルは pid 生存確認済み(EmulatorEndpoints.all)= adb を通さない
        // serial→AVD の写像で、offline の台や adb が見失った台もここで引ける
        let running = (try? AndroidDeviceCatalog.runningAVDs()) ?? [:]
        let all = (try? AndroidDeviceCatalog.allEmulatorSerials()) ?? []
        var discovered: [String: String] = [:]
        for endpoint in EmulatorEndpoints.all() { discovered[endpoint.serial] = endpoint.avdID }
        let ps = (try? Shell.run(["/bin/ps", "-eo", "command"], timeout: 10))?.output
        let serial: String
        switch runningVerdict(avdID: avdID, runningAVDs: running, allEmulatorSerials: all,
                              discoveredAVDs: discovered, psOutput: ps) {
        case .notRunning:
            return .wasNotRunning
        case .running(let found):
            serial = found
        case .unknown(let reason):
            throw AndroidDataWiperError.runningStateUnknown(
                device: deviceName, avd: avdID, reason: reason)
        }
        // gRPC SHUTDOWN 優先(adb 経路死亡でも届く)・不可なら従来の emu kill
        if await !EmulatorControl.shutdown(serial: serial) {
            let adb = try AndroidDriver.findADB()
            _ = try? Shell.run([adb, "-s", serial, "emu", "kill"])
        }

        let deadline = Date().addingTimeInterval(TimeInterval(stopConfirmSeconds))
        while Date() < deadline {
            // ①は **offline を含む一覧**で見る(state=device だけだと、offline の台は最初から
            // 「消えている」= 生きた qemu の下で削除へ進む。停止中の台も device→offline→消失と
            // 遷移するので、offline の段で消えたと見ない)。adb が読めなければ「まだ居る」に倒す
            let present = (try? AndroidDeviceCatalog.allEmulatorSerials()) ?? [serial]
            if !present.contains(serial) { return .wasRunning }
            if !emulatorProcessRunning(avdID: avdID) {
                log("→ \(deviceName): the emulator process is gone (adb still lists \(serial))")
                return .wasRunning
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw AndroidDataWiperError.stopNotConfirmed(
            device: deviceName, serial: serial, seconds: stopConfirmSeconds)
    }

    enum RunningVerdict: Equatable {
        case notRunning
        /// この serial へ停止を撃つ(state=device でも offline でもよい)
        case running(serial: String)
        /// 走っているかもしれないが止める宛先が引けない。**消してはいけない**
        case unknown(reason: String)
    }

    /// 「その AVD は今走っているか」。I/O を持たない pure 関数(テスト用に internal)。
    /// **offline も走っている** —— ブート中・adbd が詰まったゲストは `adb devices` に offline で
    /// 載る(runningAVDs は state=device だけなので、それだけ見ると生きた qemu の下から
    /// イメージを抜く)。優先順: state=device の照合 → 発見ファイル(serial→AVD。offline や
    /// adb が見失った台もここで引ける)→ qemu プロセスの有無(居るのに serial が無い = unknown)
    /// → ps が読めず未解決の offline がある = unknown → notRunning
    static func runningVerdict(
        avdID: String, runningAVDs: [String: String], allEmulatorSerials: [String],
        discoveredAVDs: [String: String], psOutput: String?
    ) -> RunningVerdict {
        if let serial = runningAVDs.first(where: { $0.value == avdID })?.key {
            return .running(serial: serial)
        }
        if let serial = discoveredAVDs.first(where: { $0.value == avdID })?.key {
            return .running(serial: serial)
        }
        let unresolvedOffline = allEmulatorSerials
            .filter { runningAVDs[$0] == nil && discoveredAVDs[$0] == nil }
        guard let psOutput else {
            return unresolvedOffline.isEmpty
                ? .notRunning
                : .unknown(reason: "ps is unreadable and adb lists offline emulators it cannot name: "
                           + unresolvedOffline.joined(separator: ", "))
        }
        if avdProcessPresent(psOutput: psOutput, avdID: avdID) {
            return .unknown(reason: "its emulator process is running but neither adb nor the"
                            + " emulator discovery file gives a serial for it")
        }
        return .notRunning
    }

    /// その AVD の qemu プロセスが生きているか(`ps` の1回分を走査)。読み取りだけ
    private static func emulatorProcessRunning(avdID: String) -> Bool {
        guard let result = try? Shell.run(["/bin/ps", "-eo", "command"], timeout: 10) else {
            return true  // 見られないなら「居るかもしれない」に倒す(消す側へ倒さない)
        }
        return avdProcessPresent(psOutput: result.output, avdID: avdID)
    }

    /// `ps` の出力に `-avd <id>` または `@<id>`(emulator の短縮形)が**そのままの語**で現れるか。
    /// I/O を持たない pure 関数(テスト用に internal)。**前方一致では判定しない** ——
    /// `Pixel_9_-01` と `Pixel_9_-010` のように、片方がもう片方の接頭辞になる AVD 名は普通にある
    static func avdProcessPresent(psOutput: String, avdID: String) -> Bool {
        let shortForm = Substring("@" + avdID)
        for line in psOutput.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            for (index, token) in tokens.enumerated() {
                if token == shortForm { return true }
                if token == "-avd", index + 1 < tokens.count, tokens[index + 1] == Substring(avdID) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - 純粋ロジック(テスト用に internal で公開)

    static let wipeFileNames = [
        "userdata-qemu.img", "userdata-qemu.img.qcow2", "cache.img", "cache.img.qcow2",
    ]

    /// avdDir 直下に実在する wipe 対象(ファイル+snapshots ディレクトリ)を列挙
    static func wipeTargets(avdDir: URL) -> [URL] {
        let fm = FileManager.default
        var targets = wipeFileNames
            .map { avdDir.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }

        let snapshots = avdDir.appendingPathComponent("snapshots")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: snapshots.path, isDirectory: &isDir), isDir.boolValue {
            targets.append(snapshots)
        }
        return targets
    }

    /// 対象の合計バイト数(ディレクトリは再帰合計)
    static func totalSize(paths: [URL]) -> Int64 {
        paths.reduce(Int64(0)) { $0 + sizeOf($1) }
    }

    private static func sizeOf(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values?.fileSize ?? 0)
        }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
