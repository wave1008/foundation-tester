// 実行開始時(ProfileWorkerFactory 経由)に Android AVD の肥大化を検査し、しきい値超過なら
// Wipe Data する。wipe 対象ファイル集合は Android Studio の Wipe Data と同一
// (userdata-qemu.img[.qcow2] / cache.img[.qcow2] / snapshots/。sdcard.img は消さない)。
// 稼働中エミュレータの下では削除しない: kill→serial 消失確認が取れた場合のみ削除する。

import Foundation
import FTCore

public enum AndroidDataWiper {

    private enum RunningState: Equatable {
        case wasRunning, wasNotRunning, failedToStop
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
    /// vscode-ftester/src/model.ts の WipeStatusEvent)
    public static func wipeBloatedAVDs(
        devices: [ResolvedDevice], thresholdGB: Double, locale: String,
        status: (@Sendable (String, String) -> Void)? = nil,
        log: @escaping @Sendable (String) -> Void
    ) async -> [String] {
        let thresholdBytes = Int64((thresholdGB * 1_073_741_824).rounded())

        var candidates: [Candidate] = []
        for device in devices where device.platform == "android" {
            guard let avd = device.spec.avd else {
                log("⚠️ \(device.name): avd 未指定のため Wipe Data 判定をスキップします")
                continue
            }
            let avdID = AndroidDeviceCatalog.canonicalAVDID(avd)
            // <id>.avd 直組みは不可(ini の path が別名ディレクトリを指すことがある。カタログ側コメント参照)
            let avdDir = AndroidDeviceCatalog.avdContentDirectory(id: avdID)
            guard FileManager.default.fileExists(atPath: avdDir.path) else {
                log("⚠️ \(device.name): AVD ディレクトリが見つからないため "
                    + "Wipe Data 判定をスキップします(\(avdDir.path))")
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
        log("🧹 Wipe Data 対象 \(candidates.count) 台(しきい値 "
            + String(format: "%.1f", thresholdGB) + "GB 超過): \(list)")
        log("   ゲストは初期化されます(1台ずつ停止→削除→再ブート。再構築のため1台あたり数分。"
            + "ロケール \(locale) は再ブート後に自動適用)")

        var wiped: [String] = []
        for (index, candidate) in candidates.enumerated() {
            let name = candidate.device.name
            let progress = "\(index + 1)/\(candidates.count)"
            do {
                log("🧹 \(name): Wipe Data 実施中(\(progress))— エミュレータ停止中...")
                status?(name, "stopping")
                let running = try await stopIfRunning(avdID: candidate.avdID,
                                                      deviceName: name, log: log)
                guard running != .failedToStop else {
                    status?(name, "failed")
                    continue
                }

                for target in candidate.targets {
                    try? FileManager.default.removeItem(at: target)
                }
                wiped.append(name)

                if running == .wasRunning {
                    log("🧹 \(name): データ削除完了(解放 \(candidate.sizeGB)GB)。"
                        + "再ブート中(初回ブートは再構築のため数分かかります)...")
                    status?(name, "rebooting")
                    let serial = try await DeviceBooter.startEmulator(avd: candidate.avdID,
                                                                      locale: locale)
                    try await DeviceBooter.waitForAndroidBoot(serial: serial)
                    // Play イメージでは -change-locale が無効のため、ブリッジ /locale で適用する
                    await DeviceBooter.applyLocale(serial: serial, locale: locale,
                                                   deviceName: name, log: log)
                    log("✅ \(name): Wipe Data 完了(\(progress))")
                } else {
                    log("✅ \(name): Wipe Data 完了(\(progress)、解放 \(candidate.sizeGB)GB。"
                        + "未起動のため再ブートなし)")
                }
                status?(name, "done")
            } catch {
                log("❌ \(name): Wipe Data 失敗 — \(error.localizedDescription)")
                status?(name, "failed")
            }
        }
        return wiped
    }

    /// 起動中なら emu kill → serial 消失を待つ(上限30秒・0.5秒ポーリング)。
    /// 消えなければ failedToStop(呼び出し側は wipe を中止する)
    private static func stopIfRunning(
        avdID: String, deviceName: String, log: @escaping (String) -> Void
    ) async throws -> RunningState {
        guard let serial = try? AndroidDeviceCatalog.runningAVDs()
            .first(where: { $0.value == avdID })?.key else {
            return .wasNotRunning
        }
        let adb = try AndroidDriver.findADB()
        _ = try? Shell.run([adb, "-s", serial, "emu", "kill"])

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let connected = (try? AndroidDeviceCatalog.connectedSerials()) ?? []
            if !connected.contains(serial) { return .wasRunning }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("❌ \(deviceName): エミュレータ停止を確認できないため Wipe Data を中止します(\(serial))")
        return .failedToStop
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
