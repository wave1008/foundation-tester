// VSCode拡張の新規デバイス作成UI向け: シミュレータ/AVDを新規作成しマシンプロファイルへ
// デバイスを追記する(ftester api create-device)。カタログは ftester api device-catalog、
// 追記ロジックは FTCore.MachineProfileEditor を使う。stdout には NDJSON(log* → finished)
// だけを出す(診断は stderr のみ。ok:false のときは exit code 1)。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct ApiCreateDeviceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-device",
        abstract: "シミュレータ/AVDを新規作成しマシンプロファイルへデバイスを追記する"
            + "(NDJSON: log* → finished を stdout に出力。診断は stderr のみ。"
            + "ok:false のときは exit code 1)")

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "マシン名(省略時: FT_MACHINE / 登録名 / machines/ が 1 つならそれ)")
    var machine: String?

    @Option(help: "プラットフォーム(ios / android)")
    var platform: String

    @Option(help: "デバイスの論理名(マシンプロファイルの ios/android 横断で一意な name になる)")
    var name: String

    @Option(help: ArgumentHelp(
        "iOS: シミュレータ機種の identifier / Android: avdmanager のデバイス定義 id"
        + "(device-catalog の models[].id / deviceTypes[].identifier)"))
    var model: String

    @Option(help: ArgumentHelp(
        "iOS: ランタイムの identifier / Android: システムイメージのパッケージ"
        + "(device-catalog の runtimes[].identifier / systemImages[].package)"))
    var os: String

    @Flag(name: .customLong("no-register"), help: ArgumentHelp(
        "シミュレータ/AVD の作成のみ行い、マシンプロファイルへは追記しない"
        + "(VSCode拡張の「既存のデバイスから選択」画面用 — 登録は選択画面の OK で行う)"))
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
            throw CreateDeviceError("デバイス名が空です")
        }
        guard platform == "ios" || platform == "android" else {
            throw CreateDeviceError("platform は ios または android を指定してください: \(platform)")
        }

        // --no-register: 物理作成のみ行い、プロファイルの解決・重複チェック・追記・書き戻しは
        // 一切行わない(--machine/--project も無視可。登録は拡張の選択画面 OK で別途行われる想定)
        if noRegister {
            let resultEntry: ApiCreateDeviceEntry
            switch platform {
            case "ios":
                (_, resultEntry) = try await createSimulator(name: trimmedName)
            default:
                (_, resultEntry) = try createAVD(name: trimmedName)
            }
            emitLog("マシンプロファイルへは登録しません(--no-register)")
            return resultEntry
        }

        let testProject = try ScenarioHost.project(named: project)
        let machineName = try resolveMachineName(project: testProject)

        let machineURL = testProject.machinesDir.appendingPathComponent("\(machineName).json")
        guard FileManager.default.fileExists(atPath: machineURL.path) else {
            throw CreateDeviceError("マシンプロファイル \(machineName).json がありません")
        }
        let data = try Data(contentsOf: machineURL)
        guard let profileObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw CreateDeviceError("マシンプロファイル \(machineName).json を JSON として解析できません")
        }

        // 名前重複は物理作成前に検証する(作成後に addingDevice で発覚すると孤児シミュレータ/AVDが
        // 残るため)。addingDevice 内の重複チェックは防御として残している
        guard !MachineProfileEditor.deviceNames(inProfileObject: profileObject)
            .contains(trimmedName) else {
            throw CreateDeviceError("デバイス名が重複しています: \(trimmedName)"
                + "(name は ios/android 横断で一意にしてください)")
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
        let lock = try ProvisionLock(stateDir: testProject.machinesDir,
                                     lockName: "machine-\(machineName).lock")
        await lock.acquire()
        defer { lock.release() }

        // ロック下で最新のプロファイルを読み直す(初回読みは line 88。別プロセスの追記を取りこぼさない)。
        let currentObject: [String: Any]
        do {
            let freshData = try Data(contentsOf: machineURL)
            guard let obj = (try? JSONSerialization.jsonObject(with: freshData)) as? [String: Any] else {
                throw CreateDeviceError("マシンプロファイル \(machineName).json を JSON として解析できません")
            }
            currentObject = obj
        } catch let error as CreateDeviceError {
            throw error
        } catch {
            throw CreateDeviceError(
                "シミュレータ/AVD の作成には成功しましたが、プロファイルの読み直しに失敗しました: "
                + error.localizedDescription)
        }

        let updated: [String: Any]
        do {
            updated = try MachineProfileEditor.addingDevice(
                toProfileObject: currentObject, platform: platform, device: deviceEntry)
        } catch {
            throw CreateDeviceError(
                "シミュレータ/AVD の作成には成功しましたが、プロファイルへの追記に失敗しました: "
                + error.localizedDescription)
        }
        do {
            let output = try JSONSerialization.data(
                withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: machineURL, options: .atomic)
        } catch {
            throw CreateDeviceError(
                "シミュレータ/AVD の作成には成功しましたが、プロファイルファイルへの書き込みに失敗しました: "
                + error.localizedDescription)
        }
        return resultEntry
    }

    /// マシン名の決定: --machine が明示指定されていればそれを最優先(env/自動採用より優先)。
    /// 省略時は ProfileResolver.determineMachine(FT_MACHINE > 登録名 > machines/ が1つ)に委ねる
    private func resolveMachineName(project: TestProject) throws -> String {
        if let machine, !machine.isEmpty { return machine }
        let determined = try ProfileResolver.determineMachine(
            project: project, registered: LocalConfig.currentMachineName())
        if determined.auto {
            logStderr("→ マシンプロファイル自動採用: \(determined.name)(machines/ が 1 つのため)")
        }
        return determined.name
    }

    // MARK: - iOS

    private func createSimulator(
        name: String
    ) async throws -> (deviceEntry: [String: Any], resultEntry: ApiCreateDeviceEntry) {
        emitLog("シミュレータ機種/ランタイムを解決中...")
        let deviceTypesResult = try Shell.run(["xcrun", "simctl", "list", "-j", "devicetypes"])
        guard deviceTypesResult.status == 0,
              let deviceTypesData = deviceTypesResult.output.data(using: .utf8),
              let deviceTypesJSON = (try? JSONSerialization.jsonObject(with: deviceTypesData))
                as? [String: Any],
              let rawDeviceTypes = deviceTypesJSON["devicetypes"] as? [[String: Any]] else {
            throw CreateDeviceError(
                "simctl list devicetypes の実行に失敗しました: \(deviceTypesResult.tail)")
        }
        guard let deviceTypeEntry = rawDeviceTypes.first(where: {
            ($0["identifier"] as? String) == model
        }), let deviceTypeName = deviceTypeEntry["name"] as? String else {
            throw CreateDeviceError("シミュレータ機種が見つかりません: \(model)")
        }

        let runtimesResult = try Shell.run(["xcrun", "simctl", "list", "-j", "runtimes"])
        guard runtimesResult.status == 0,
              let runtimesData = runtimesResult.output.data(using: .utf8),
              let runtimesJSON = (try? JSONSerialization.jsonObject(with: runtimesData))
                as? [String: Any],
              let rawRuntimes = runtimesJSON["runtimes"] as? [[String: Any]] else {
            throw CreateDeviceError("simctl list runtimes の実行に失敗しました: \(runtimesResult.tail)")
        }
        guard let runtimeEntry = rawRuntimes.first(where: { ($0["identifier"] as? String) == os }),
              let runtimeVersion = runtimeEntry["version"] as? String else {
            throw CreateDeviceError("ランタイムが見つかりません: \(os)")
        }

        emitLog("シミュレータを作成中: \(name)(\(deviceTypeName) / iOS \(runtimeVersion))...")
        let createResult = try Shell.run(["xcrun", "simctl", "create", name, model, os])
        guard createResult.status == 0 else {
            throw CreateDeviceError("simctl create に失敗しました: \(createResult.tail)")
        }
        let udid = createResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else {
            throw CreateDeviceError("simctl create の出力(UDID)が空です")
        }
        emitLog("シミュレータを作成しました(UDID: \(udid))")

        let deviceEntry: [String: Any] = [
            "name": name, "simulator": deviceTypeName, "os": runtimeVersion, "udid": udid,
        ]
        let resultEntry = ApiCreateDeviceEntry(avd: nil, name: name, udid: udid)
        return (deviceEntry, resultEntry)
    }

    // MARK: - Android

    private func createAVD(
        name: String
    ) throws -> (deviceEntry: [String: Any], resultEntry: ApiCreateDeviceEntry) {
        guard let avdmanagerURL = AndroidSDKLocator.findAVDManager() else {
            throw CreateDeviceError("avdmanager が見つかりません(cmdline-tools をインストールしてください)")
        }

        // AVD ID はデバイス名から機械的に生成する(avdmanager -n の制約に合わせて英数字・._- のみ)。
        // 既存 AVD と衝突する場合は _2, _3... を付けて回避する
        let installedIDs = Set(AndroidDeviceCatalog.installedAVDs().map(\.id))
        let baseID = MachineProfileEditor.sanitizedAVDID(from: name)
        var avdID = baseID
        var suffix = 2
        while installedIDs.contains(avdID) {
            avdID = "\(baseID)_\(suffix)"
            suffix += 1
        }

        emitLog("AVD を作成中: \(avdID)(\(model) / \(os))...")
        try Self.runAVDManagerCreate(
            avdmanagerPath: avdmanagerURL.path, avdID: avdID, package: os, deviceID: model)
        emitLog("AVD を作成しました: \(avdID)")

        updateDisplayName(avdID: avdID, displayName: name)

        let deviceEntry: [String: Any] = ["name": name, "avd": avdID]
        let resultEntry = ApiCreateDeviceEntry(avd: avdID, name: name, udid: nil)
        return (deviceEntry, resultEntry)
    }

    /// avdmanager create avd を実行する。「カスタムハードウェアプロファイルを作成しますか? [no]」
    /// という stdin 待ちの対話プロンプトが出るため、Shell.run(stdin 制御が無い)は使わず
    /// Process を直接使って stdin に "no\n" を書き込む
    private static func runAVDManagerCreate(
        avdmanagerPath: String, avdID: String, package: String, deviceID: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: avdmanagerPath)
        process.arguments = ["create", "avd", "-n", avdID, "-k", package, "-d", deviceID]
        let stdinPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let waitForExit = ProcessExitWait.prepareBlocking(process)
        try process.run()
        // プロンプトへの回答は数バイトなのでパイプバッファに収まり、書き込みはブロックしない。
        // 書き込み後すぐ閉じてから出力を読み切る(avdmanager 側は追加の入力を待たないため安全)
        stdinPipe.fileHandleForWriting.write(Data("no\n".utf8))
        try? stdinPipe.fileHandleForWriting.close()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        waitForExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: outputData, encoding: .utf8) ?? ""
            throw CreateDeviceError("avdmanager create avd に失敗しました: \(output)")
        }
    }

    /// AVD ホーム($ANDROID_AVD_HOME || ~/.android/avd)の <avdID>.avd/config.ini へ
    /// avd.ini.displayname を追記/置換する(表示名を機種名では無くデバイス論理名に揃えるため)。
    /// config.ini が見つからない場合は致命的ではないので stderr に警告するだけで続行する
    private func updateDisplayName(avdID: String, displayName: String) {
        let avdHome = ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".android/avd")
        let configURL = avdHome.appendingPathComponent("\(avdID).avd/config.ini")
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            logStderr("⚠️ config.ini が見つかりません(表示名の設定をスキップ): \(configURL.path)")
            return
        }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLine = "avd.ini.displayname=\(displayName)"
        if let index = lines.firstIndex(where: { $0.hasPrefix("avd.ini.displayname") }) {
            lines[index] = newLine
        } else {
            lines.append(newLine)
        }
        guard let updated = lines.joined(separator: "\n").data(using: .utf8) else { return }
        do {
            try updated.write(to: configURL, options: .atomic)
        } catch {
            logStderr("⚠️ config.ini への表示名書き込みに失敗しました: \(error.localizedDescription)")
        }
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
        print(line)
    }

    private func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
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

/// マシンプロファイルへ追記したデバイス。iOS は udid が非 null/avd が null、
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
