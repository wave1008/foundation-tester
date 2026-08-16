// VSCode拡張の「デバイスを選択」ダイアログ(右クリック→削除)向け: シミュレータ/AVD の実体を
// 削除する(ftester api delete-device)。対になる ApiCreateDeviceCommand と NDJSON の出し方
// (log* → finished・診断は stderr のみ・ok:false のとき exit 1)を揃える。
//
// 安全側の規律(破壊的操作のため入口で止める。判定・文言は FTCore.DeviceDeletion に集約):
// 起動中は削除しない/存在しない識別子を「削除できた」と言わない/識別子はシェルへ渡す前に検証する。
// マシンプロファイルからの参照は削除を止めないが finished.referencedBy に載せ、宙ぶらりんの
// エントリが残ることを呼び出し側が言えるようにする(プロファイル解決は best-effort — 見つからない/
// 壊れていても削除自体は続行し、referencedBy が空になるだけ)。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct ApiDeleteDeviceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-device",
        abstract: "Delete a simulator/AVD instance (irreversible; refuses while the device is running)"
            + " (NDJSON: log* -> finished on stdout; diagnostics on stderr only;"
            + " exit code 1 when ok:false)")

    @Option(help: "Platform (ios / android)")
    var platform: String

    @Option(help: "iOS simulator UDID (required for --platform ios)")
    var udid: String?

    @Option(help: ArgumentHelp(
        "Android AVD id as passed to avdmanager -n (required for --platform android)"))
    var avd: String?

    @Option(help: ArgumentHelp("Test project name, used only to look up machine profiles for the referencedBy"
        + " check (defaults to the only one in TestProjects/, or the default project; if it cannot"
        + " be resolved the deletion still proceeds and referencedBy is empty)"))
    var project: String?

    func run() async throws {
        // finished 到達を読み手が確実に検知できるよう、log イベントもすぐ流す
        setvbuf(stdout, nil, _IOLBF, 0)

        do {
            let result = try await execute()
            emitFinished(ok: true, error: nil, identifier: result.identifier,
                        name: result.name, referencedBy: result.referencedBy)
        } catch {
            emitFinished(ok: false, error: error.localizedDescription,
                        identifier: nil, name: nil, referencedBy: [])
            throw ExitCode(1)
        }
    }

    private func execute() async throws -> DeletionResult {
        switch platform {
        case "ios":
            guard let udid, !udid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeleteDeviceError("--udid is required for --platform ios")
            }
            return try await deleteIOS(udid: udid)
        case "android":
            guard let avd, !avd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeleteDeviceError("--avd is required for --platform android")
            }
            return try deleteAndroid(avd: avd)
        default:
            throw DeleteDeviceError("platform must be ios or android: \(platform)")
        }
    }

    // MARK: - iOS

    private func deleteIOS(udid: String) async throws -> DeletionResult {
        try DeviceDeletion.validateIOSUDID(udid)

        emitLog("Checking the simulator's state...")
        let catalog = try SimulatorCatalog.devices()
        let match = catalog.first(where: { $0.udid == udid })
        if let reason = DeviceDeletion.refusalReason(isRunning: match?.booted ?? false, exists: match != nil) {
            throw DeleteDeviceError(reason)
        }
        let name = match!.name

        emitLog("Deleting the simulator: \(name) (\(udid))...")
        let result = try Shell.run(DeviceDeletion.iosCommand(udid: udid))
        guard result.status == 0 else {
            throw DeleteDeviceError("simctl delete failed: \(result.tail)")
        }
        emitLog("Deleted the simulator: \(name)")

        return DeletionResult(identifier: udid, name: name, referencedBy: referencedByMachines(identifier: udid))
    }

    // MARK: - Android

    private func deleteAndroid(avd: String) throws -> DeletionResult {
        try DeviceDeletion.validateAndroidAVDName(avd)

        emitLog("Checking the AVD's state...")
        let match = AndroidDeviceCatalog.installedAVDs().first(where: { $0.id == avd })
        let running = (try? AndroidDeviceCatalog.runningAVDs()) ?? [:]
        let isRunning = running.values.contains(avd)
        if let reason = DeviceDeletion.refusalReason(isRunning: isRunning, exists: match != nil) {
            throw DeleteDeviceError(reason)
        }
        let name = match?.displayName ?? avd

        guard let avdmanagerURL = AndroidSDKLocator.findAVDManager() else {
            throw DeleteDeviceError(AndroidSDKLocator.avdManagerMissingMessage + ". "
                + AndroidSDKLocator.avdManagerInstallHint)
        }

        emitLog("Deleting the AVD: \(avd)...")
        var command = DeviceDeletion.androidCommand(avd: avd)
        command[0] = avdmanagerURL.path
        let result = try Shell.run(command)
        guard result.status == 0 else {
            throw DeleteDeviceError("avdmanager delete avd failed: \(result.tail)")
        }
        emitLog("Deleted the AVD: \(avd)")

        return DeletionResult(identifier: avd, name: name, referencedBy: referencedByMachines(identifier: avd))
    }

    // MARK: - referencedBy

    /// best-effort。プロジェクトが解決できない/一部のマシンプロファイルが読めなくても削除は
    /// 既に完了しているため、ここでは例外を投げず空扱いにする(該当分だけ stderr に警告)
    private func referencedByMachines(identifier: String) -> [String] {
        guard let testProject = try? ScenarioHost.project(named: project) else {
            return []
        }
        var profiles: [(name: String, profile: MachineProfile)] = []
        for machineName in ProfileResolver.machineNames(project: testProject) {
            let url = testProject.machinesDir.appendingPathComponent("\(machineName).json")
            guard let data = try? Data(contentsOf: url),
                  let profile = try? JSONDecoder().decode(MachineProfile.self, from: data) else {
                logStderr("⚠️ Cannot read/parse machine profile \(machineName).json (skipping the referencedBy check for it)")
                continue
            }
            profiles.append((machineName, profile))
        }
        return DeviceDeletion.referencedBy(machineProfiles: profiles, identifier: identifier)
    }

    // MARK: - NDJSON 出力

    private func emitLog(_ message: String) {
        emitLine(ApiDeleteDeviceLogEvent(message: message))
    }

    private func emitFinished(ok: Bool, error: String?, identifier: String?, name: String?, referencedBy: [String]) {
        emitLine(ApiDeleteDeviceFinishedEvent(
            ok: ok, error: error, identifier: identifier, name: name, referencedBy: referencedBy))
    }

    private func emitLine<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }

    private func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private struct DeletionResult {
    let identifier: String
    let name: String
    let referencedBy: [String]
}

/// delete-device の実行時エラー。NDJSON の finished.error にそのまま載せるため LocalizedError に
/// 準拠する(ArgumentParser.ValidationError は localizedDescription が汎用文言になり message が
/// 失われるため使わない。CreateDeviceError と同じ理由)
private struct DeleteDeviceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 進捗ログ 1 行分
private struct ApiDeleteDeviceLogEvent: Encodable {
    let kind = "log"
    let message: String
}

/// 末尾イベント。error/identifier/name は省略可能フィールドとして明示的に null を encode する
/// (ApiCreateDeviceFinishedEvent と同方針)。referencedBy は削除成功時のみ意味を持つが、
/// 失敗時も空配列で一貫させる(呼び出し側が undefined チェックを増やさずに済むように)
private struct ApiDeleteDeviceFinishedEvent: Encodable {
    let kind = "finished"
    let ok: Bool
    let error: String?
    let identifier: String?
    let name: String?
    let referencedBy: [String]

    private enum CodingKeys: String, CodingKey {
        case kind, ok, error, identifier, name, referencedBy
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(name, forKey: .name)
        try container.encode(referencedBy, forKey: .referencedBy)
    }
}
