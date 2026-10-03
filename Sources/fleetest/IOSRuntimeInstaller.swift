// iOS Simulator ランタイムの導入と、自動選定の入力(simctl・SDK の版)の取得。
// `fleetest api create-device`(ApiCreateDeviceCommand)と `fleetest profile setup --auto-device`
// (ProfileSetupCommand)が共有する。判定そのものは FTCore.DevicePicker(ここは I/O だけ)。
// iOS のランタイム導入はライセンス承諾のフラグを要求しない(Xcode の導入済みライセンスで足りる)。
// 進捗は log クロージャで受ける(NDJSON か通常出力かは呼び手の責務)。

import Foundation
import FTCore

enum IOSRuntimeInstaller {

    /// create-device の finished.error / profile setup のエラーにそのまま載る(LocalizedError)
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// `xcodebuild -downloadPlatform iOS` の上限(秒)= 2 時間。ランタイムは数 GB
    /// (実測は取っていない。10 MB/s で 1 GB あたり約 2 分 → 10 GB で 20 分強)で、回線が遅い環境でも
    /// 終わるよう 5 倍強の余裕を取った値。**尽きたとき** = `Shell.run` が子孫ごと止めて
    /// `ShellError.timedOut` を投げ、Failure(「期限内に終わらなかった」)で返る(途中まで落ちた分は
    /// xcodebuild 側が破棄する。再実行で最初からになる)
    static let downloadTimeoutSeconds: Double = 7200

    /// simctl の runtime 一覧の1回の取得の上限(秒)。メタデータの読み出しだけで、実測は1秒未満。
    /// 尽きたとき = simctl が wedge している形なので Failure
    static let simctlTimeoutSeconds: Double = 60

    /// 版を `xcrun --sdk iphonesimulator --show-sdk-version` で読む("27.0")。読めなければ nil
    /// (呼び手は導入済みの最大へ倒す)
    static func sdkVersion() -> String? {
        guard let result = try? Shell.run(
            ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], timeout: simctlTimeoutSeconds),
            let output = result.outputIfSucceeded else { return nil }
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return DevicePicker.osVersionValue(version).isEmpty ? nil : version
    }

    /// platform iOS かつ isAvailable のランタイム(simctl list -j runtimes)
    static func installedRuntimes() throws -> [DevicePicker.IOSRuntimeInfo] {
        let result: Shell.Result
        do {
            result = try Shell.run(["xcrun", "simctl", "list", "-j", "runtimes"], timeout: simctlTimeoutSeconds)
        } catch {
            throw Failure("simctl list runtimes failed: \(ErrorText.user(error))")
        }
        guard let output = result.outputIfSucceeded,
              let data = output.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = json["runtimes"] as? [[String: Any]] else {
            throw Failure("simctl list runtimes failed: \(result.tail)")
        }
        return parseRuntimes(raw)
    }

    static func parseRuntimes(_ raw: [[String: Any]]) -> [DevicePicker.IOSRuntimeInfo] {
        raw.compactMap { dict in
            guard let identifier = dict["identifier"] as? String,
                  let name = dict["name"] as? String,
                  let version = dict["version"] as? String,
                  (dict["platform"] as? String) == "iOS",
                  (dict["isAvailable"] as? Bool) == true else { return nil }
            let supported = (dict["supportedDeviceTypes"] as? [[String: Any]] ?? [])
                .compactMap { $0["identifier"] as? String }
            return DevicePicker.IOSRuntimeInfo(
                identifier: identifier, version: version, name: name, supportedDeviceTypeIdentifiers: supported)
        }
    }

    /// `xcodebuild -downloadPlatform iOS` で選択中の Xcode が対応する版を入れ、
    /// `identifier` のランタイムが導入済みになったことを確かめる。入っていなければ Failure
    static func install(version: String, expectedIdentifier: String, log: (String) -> Void) throws {
        log("Downloading the iOS \(version) simulator runtime (several GB; this can take several"
            + " minutes to tens of minutes)...")
        let result: Shell.Result
        do {
            result = try Shell.run(["xcodebuild", "-downloadPlatform", "iOS"], timeout: downloadTimeoutSeconds)
        } catch let error as ShellError {
            throw Failure("xcodebuild -downloadPlatform iOS did not finish within"
                + " \(Int(downloadTimeoutSeconds))s: \(ErrorText.user(error))")
        }
        guard result.status == 0 else {
            throw Failure("xcodebuild -downloadPlatform iOS failed (exit \(result.status)): \(result.tail)")
        }
        guard try installedRuntimes().contains(where: { $0.identifier == expectedIdentifier }) else {
            throw Failure("xcodebuild -downloadPlatform iOS finished, but the runtime \(expectedIdentifier)"
                + " is not installed (the selected Xcode installed a different iOS version?)")
        }
        log("Installed the iOS \(version) simulator runtime")
    }
}

/// iOS の自動選定の結果(判定は DevicePicker.iosAutoTarget。ここは名前を添えるだけ)
struct IOSAutoDevice: Equatable {
    let deviceTypeID: String
    /// 機種名(device type 名。実行プロファイルの model)
    let modelName: String
    let runtimeID: String
    /// 命名の OS ラベル。要ダウンロードは導入前なので "iOS <版>"
    let runtimeName: String
    let runtimeVersion: String
    let needsDownload: Bool

    /// device types は simctl list -j devicetypes の (identifier, name)
    static func make(target: DevicePicker.IOSAutoTarget, runtimes: [DevicePicker.IOSRuntimeInfo],
                     deviceTypes: [(identifier: String, name: String)]) -> IOSAutoDevice? {
        guard let modelName = deviceTypes.first(where: { $0.identifier == target.deviceTypeIdentifier })?.name
        else { return nil }
        switch target.runtime {
        case .installed(let identifier):
            guard let runtime = runtimes.first(where: { $0.identifier == identifier }) else { return nil }
            return IOSAutoDevice(deviceTypeID: target.deviceTypeIdentifier, modelName: modelName,
                                 runtimeID: identifier, runtimeName: runtime.name,
                                 runtimeVersion: runtime.version, needsDownload: false)
        case .needsDownload(let version):
            guard let identifier = DevicePicker.predictedIOSRuntimeIdentifier(version: version) else { return nil }
            return IOSAutoDevice(deviceTypeID: target.deviceTypeIdentifier, modelName: modelName,
                                 runtimeID: identifier, runtimeName: "iOS \(version)",
                                 runtimeVersion: version, needsDownload: true)
        }
    }

    /// simctl・xcrun から入力を集めて決める。作成も導入もしない
    static func resolve() throws -> IOSAutoDevice {
        let runtimes = try IOSRuntimeInstaller.installedRuntimes()
        let types = try IOSRuntimeInstaller.deviceTypes()
        guard let target = DevicePicker.iosAutoTarget(
            runtimes: runtimes, deviceTypeIdentifiers: types.map { $0.identifier },
            sdkVersion: IOSRuntimeInstaller.sdkVersion()),
              let device = make(target: target, runtimes: runtimes, deviceTypes: types) else {
            throw IOSRuntimeInstaller.Failure(
                "no iOS runtime / iPhone model could be chosen automatically (no installed iOS runtime and"
                + " the selected Xcode's SDK version is unreadable, or no iPhone <N> model is available);"
                + " specify one explicitly with --device-name/--os or --udid")
        }
        return device
    }
}

extension IOSRuntimeInstaller {
    /// simctl list -j devicetypes の (identifier, name)
    static func deviceTypes() throws -> [(identifier: String, name: String)] {
        let result: Shell.Result
        do {
            result = try Shell.run(["xcrun", "simctl", "list", "-j", "devicetypes"], timeout: simctlTimeoutSeconds)
        } catch {
            throw Failure("simctl list devicetypes failed: \(ErrorText.user(error))")
        }
        guard let output = result.outputIfSucceeded,
              let data = output.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = json["devicetypes"] as? [[String: Any]] else {
            throw Failure("simctl list devicetypes failed: \(result.tail)")
        }
        return raw.compactMap { dict in
            guard let identifier = dict["identifier"] as? String, let name = dict["name"] as? String else { return nil }
            return (identifier, name)
        }
    }
}
