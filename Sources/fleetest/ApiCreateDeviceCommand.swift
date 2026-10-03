// VSCode拡張の新規デバイス作成UI向け: シミュレータ/AVDを新規作成し実行プロファイルの devices へ
// 追記する(fleetest api create-device)。カタログは fleetest api device-catalog、
// 追記ロジックは FTCore.RunProfileDeviceEditor を使う。stdout には NDJSON(log* → finished)
// だけを出す(診断は stderr のみ。ok:false のときは exit code 1)。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct ApiCreateDeviceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-device",
        abstract: "Create a new simulator/AVD and append the device to a run profile"
            + " (NDJSON: log* -> finished on stdout; diagnostics on stderr only;"
            + " exit code 1 when ok:false)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile to append the device to (profiles/runs/<name>.json; required unless --no-register)")
    var profile: String?

    @Option(help: "Platform (ios / android)")
    var platform: String

    @Option(help: "Device name (must be unique on this machine across ios and android in the run profile)")
    var name: String

    @Option(help: ArgumentHelp(
        "iOS: simulator model identifier / Android: avdmanager device-definition id"
        + " (models[].id / deviceTypes[].identifier from device-catalog)"))
    var model: String

    @Option(help: ArgumentHelp(
        "iOS: runtime identifier / Android: system-image package"
        + " (runtimes[].identifier / systemImages[].package from device-catalog)"))
    var os: String

    @Flag(help: ArgumentHelp(
        "Replace an existing simulator/AVD of the same name instead of creating a variant"
        + " (deletes it first; refuses while it is running). Without this flag the new AVD gets a"
        + " _2 / _3 ... suffix so both survive"))
    var overwrite = false

    @Flag(name: .customLong("no-register"), help: ArgumentHelp(
        "Only create the simulator/AVD without appending it to a run profile"
        + " (for the VSCode extension's pick-from-existing screen — registration happens on its OK)"))
    var noRegister = false

    func run() async throws {
        // finished 到達を読み手が確実に検知できるよう、log イベントもすぐ流す
        setvbuf(stdout, nil, _IOLBF, 0)

        do {
            let device = try await execute()
            emitFinished(ok: true, error: nil, device: device)
        } catch {
            emitFinished(ok: false, error: error.localizedDescription, device: nil)
            throw ExitCode(1)
        }
    }

    private func execute() async throws -> ApiCreateDeviceEntry {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CreateDeviceError("the device name is empty")
        }
        guard platform == "ios" || platform == "android" else {
            throw CreateDeviceError("platform must be ios or android: \(platform)")
        }

        // --no-register: 物理作成のみ行い、プロファイルの解決・重複チェック・追記・書き戻しは
        // 一切行わない(--profile/--project も無視可。登録は拡張の選択画面 OK で別途行われる想定)
        if noRegister {
            let resultEntry: ApiCreateDeviceEntry
            switch platform {
            case "ios":
                (_, resultEntry) = try await createSimulator(name: trimmedName)
            default:
                (_, resultEntry) = try createAVD(name: trimmedName)
            }
            emitLog("Not registering into a run profile (--no-register)")
            return resultEntry
        }

        let testProject = try ScenarioHost.project(named: project)
        guard let runName = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !runName.isEmpty else {
            throw CreateDeviceError("--profile is required (the run profile to append the device to),"
                + " or pass --no-register")
        }
        let runURL = testProject.runsDir.appendingPathComponent("\(runName).json")
        guard FileManager.default.fileExists(atPath: runURL.path) else {
            throw CreateDeviceError("run profile \(runName).json does not exist")
        }
        let data = try Data(contentsOf: runURL)
        guard let profileObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw CreateDeviceError("cannot parse run profile \(runName).json as JSON")
        }

        // 名前重複は物理作成前に検証する(作成後に addingDevice で発覚すると孤児シミュレータ/AVDが
        // 残るため)。addingDevice 内の重複チェックは防御として残している。
        // **このコマンドは手元にしか作らない**(リモートは --no-register)ので、比べる相手は
        // 手元のデバイスだけ。別ホストの同名は重複ではない(FTCore.DeviceMachineGrouping)
        let localNames = RunProfileDeviceEditor.localDeviceNames(inRunProfileObject: profileObject)
        guard !localNames.contains(trimmedName) else {
            throw CreateDeviceError("duplicate device name: \(trimmedName)"
                + " on this machine (names must be unique per host, across ios and android)")
        }

        let deviceEntry: [String: Any]
        let resultEntry: ApiCreateDeviceEntry
        switch platform {
        case "ios":
            (deviceEntry, resultEntry) = try await createSimulator(name: trimmedName)
        default:
            (deviceEntry, resultEntry) = try createAVD(name: trimmedName)
        }

        // ここまでで実体の作成は完了。以降(追記・書き戻し)が失敗しても実体は残るため
        // エラーメッセージにその旨を含める(呼び出し側が後始末できるように)。
        // 追記〜書き戻しはプロファイル単位の flock で直列化し、並行 create-device が互いの追記を
        // 上書きする lost-update を防ぐ。物理作成は上で完了済み=ロック外(並行のまま)。
        let lock = try ProvisionLock(stateDir: testProject.stateDir,
                                     lockName: "run-profile-\(runName).lock")
        await lock.acquire()
        defer { lock.release() }

        // ロック下で最新のプロファイルを読み直す(初回読みは line 88。別プロセスの追記を取りこぼさない)。
        let currentObject: [String: Any]
        do {
            let freshData = try Data(contentsOf: runURL)
            guard let obj = (try? JSONSerialization.jsonObject(with: freshData)) as? [String: Any] else {
                throw CreateDeviceError("cannot parse run profile \(runName).json as JSON")
            }
            currentObject = obj
        } catch let error as CreateDeviceError {
            throw error
        } catch {
            throw CreateDeviceError(
                "the simulator/AVD was created, but re-reading the profile failed: "
                + error.localizedDescription)
        }

        let updated: [String: Any]
        do {
            updated = try RunProfileDeviceEditor.addingDevice(
                toRunProfileObject: currentObject, device: deviceEntry)
        } catch {
            throw CreateDeviceError(
                "the simulator/AVD was created, but appending it to the profile failed: "
                + error.localizedDescription)
        }
        do {
            // キー順は OrderedProfileJSON(platform → machine → name を先頭)。ProfileWriter.json と同じ口を通す
            try ProfileWriter.json(updated).write(to: runURL, options: .atomic)
        } catch {
            throw CreateDeviceError(
                "the simulator/AVD was created, but writing the profile file failed: "
                + error.localizedDescription)
        }
        return resultEntry
    }

    // MARK: - iOS

    private func createSimulator(
        name: String
    ) async throws -> (deviceEntry: [String: Any], resultEntry: ApiCreateDeviceEntry) {
        let made = try VirtualDeviceFactory.createSimulator(
            name: name, deviceTypeID: model, runtimeID: os, overwrite: overwrite,
            log: { emitLog($0) })

        // host は**必ず書く**(手元なら "local")。省略は「プロファイル直下の既定を継ぐ」の意味で、
        // 既定がリモートのプロファイルだと手元で作った実体が別の機械のものとして扱われる
        let deviceEntry: [String: Any] = [
            "platform": "ios", "machine": DeviceMachineGrouping.localDisplayName,
            "name": name, "model": made.deviceTypeName, "osVersion": "iOS \(made.runtimeVersion)",
            "udid": made.udid,
        ]
        let resultEntry = ApiCreateDeviceEntry(avd: nil, name: name, udid: made.udid)
        return (deviceEntry, resultEntry)
    }

    // MARK: - Android

    private func createAVD(
        name: String
    ) throws -> (deviceEntry: [String: Any], resultEntry: ApiCreateDeviceEntry) {
        let avdID = try VirtualDeviceFactory.createAVD(
            name: name, deviceID: model, package: os, overwrite: overwrite, log: { emitLog($0) })

        // host は必ず書く(理由は createSimulator 側のコメント)
        let deviceEntry: [String: Any] = [
            "platform": "android", "machine": DeviceMachineGrouping.localDisplayName, "name": name, "avd": avdID,
        ]
        let resultEntry = ApiCreateDeviceEntry(avd: avdID, name: name, udid: nil)
        return (deviceEntry, resultEntry)
    }

    // MARK: - NDJSON 出力

    private func emitLog(_ message: String) {
        emitLine(ApiCreateDeviceLogEvent(message: message))
    }

    private func emitFinished(ok: Bool, error: String?, device: ApiCreateDeviceEntry?) {
        emitLine(ApiCreateDeviceFinishedEvent(ok: ok, error: error, device: device))
    }

    private func emitLine<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return }
        ConsoleOut.out(line)
    }

}

/// create-device の実行時エラー。NDJSON の finished.error に日本語メッセージをそのまま載せる
/// ため LocalizedError に準拠する(ArgumentParser.ValidationError は localizedDescription が
/// 「The operation couldn't be completed...」の汎用文言になり message が失われるため使わない)
private struct CreateDeviceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 進捗ログ 1 行分
private struct ApiCreateDeviceLogEvent: Encodable {
    let kind = "log"
    let message: String
}

/// 実行プロファイルへ追記したデバイス。iOS は udid が非 null/avd が null、
/// Android は逆(avd が非 null/udid が null)
private struct ApiCreateDeviceEntry: Encodable {
    let avd: String?
    let name: String
    let udid: String?

    private enum CodingKeys: String, CodingKey {
        case avd, name, udid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(avd, forKey: .avd)
        try container.encode(name, forKey: .name)
        try container.encode(udid, forKey: .udid)
    }
}

/// 末尾イベント。error/device は省略可能フィールドとして明示的に null を encode する
/// (ApiDeviceFinishedEvent と同方針)
private struct ApiCreateDeviceFinishedEvent: Encodable {
    let kind = "finished"
    let ok: Bool
    let error: String?
    let device: ApiCreateDeviceEntry?

    private enum CodingKeys: String, CodingKey {
        case kind, ok, error, device
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
        try container.encode(device, forKey: .device)
    }
}
