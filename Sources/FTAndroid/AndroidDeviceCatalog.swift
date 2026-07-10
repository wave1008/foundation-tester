// AndroidDeviceCatalog.swift
// マシンプロファイルの Android デバイス指定(avd)→ adb シリアルの解決。
// avd は AVD の ID("Pixel_9_Android_16")と表示名("Pixel 9(Android 16)"、
// config.ini の avd.ini.displayname)のどちらでも書ける。
// 起動中エミュレータの AVD ID(adb emu avd name / getprop)と照合して serial に解決する。

import Foundation
import FTCore

public enum AndroidDeviceCatalogError: Error, LocalizedError {
    case avdNotRunning(String, running: [String: String])
    case noIdentifier(name: String)

    public var errorDescription: String? {
        switch self {
        case .avdNotRunning(let avd, let running):
            let list = running.isEmpty ? "なし"
                : running.map { "\($0.value)(\($0.key))" }.sorted().joined(separator: ", ")
            return "AVD \"\(avd)\" のエミュレータが起動していません(起動中: \(list))。"
                + "起動: ftester devices up または emulator -avd <ID>"
        case .noIdentifier(let name):
            return "デバイス \"\(name)\" に avd がありません(マシンプロファイルに記述してください)"
        }
    }
}

public enum AndroidDeviceCatalog {

    /// 接続中のデバイスシリアル一覧(state = device のみ)
    public static func connectedSerials() throws -> [String] {
        let adbPath = try AndroidDriver.findADB()
        let devices = try Shell.run([adbPath, "devices"])
        return devices.output.split(separator: "\n").dropFirst()
            .filter { $0.contains("\tdevice") }
            .compactMap { $0.split(separator: "\t").first.map(String.init) }
    }

    /// adb が把握している全エミュレータの serial(offline/unauthorized 含む)。
    /// シャットダウン時は offline のエミュレータにも kill を送る必要がある
    public static func allEmulatorSerials() throws -> [String] {
        let adbPath = try AndroidDriver.findADB()
        let devices = try Shell.run([adbPath, "devices"])
        return devices.output.split(separator: "\n").dropFirst()
            .compactMap { $0.split(separator: "\t").first.map(String.init) }
            .filter { $0.hasPrefix("emulator-") }
    }

    /// 起動中エミュレータの serial → AVD ID
    public static func runningAVDs() throws -> [String: String] {
        let adbPath = try AndroidDriver.findADB()
        var result: [String: String] = [:]
        for serial in try connectedSerials() where serial.hasPrefix("emulator-") {
            if let name = avdName(adbPath: adbPath, serial: serial) {
                result[serial] = name
            }
        }
        return result
    }

    /// インストール済み AVD の (ID, 表示名) 一覧
    /// ($ANDROID_AVD_HOME または ~/.android/avd の *.avd/config.ini を走査)
    public static func installedAVDs() -> [(id: String, displayName: String?)] {
        let home = ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".android/avd")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.filter { $0.pathExtension == "avd" }
            .map { dir -> (String, String?) in
                let id = dir.deletingPathExtension().lastPathComponent
                let config = dir.appendingPathComponent("config.ini")
                let display = (try? String(contentsOf: config, encoding: .utf8))?
                    .split(separator: "\n")
                    .first { $0.hasPrefix("avd.ini.displayname") }
                    .flatMap { line -> String? in
                        guard let eq = line.firstIndex(of: "=") else { return nil }
                        let value = line[line.index(after: eq)...]
                            .trimmingCharacters(in: .whitespaces)
                        return value.isEmpty ? nil : value
                    }
                return (id, display)
            }
            .sorted { $0.0 < $1.0 }
    }

    /// プロファイルの avd 指定(ID または表示名)→ AVD ID。
    /// どちらにも一致しなければ入力をそのまま返す(後段の照合エラーで内容が分かる)
    public static func canonicalAVDID(_ name: String) -> String {
        let installed = installedAVDs()
        if installed.contains(where: { $0.id == name }) { return name }
        if let match = installed.first(where: { $0.displayName == name }) { return match.id }
        return name
    }

    /// DeviceSpec(Android)→ adb シリアル。avd(ID/表示名)を起動中エミュレータと照合
    public static func resolveSerial(spec: DeviceSpec) throws -> String {
        guard let avd = spec.avd else {
            throw AndroidDeviceCatalogError.noIdentifier(name: spec.name)
        }
        let canonical = canonicalAVDID(avd)
        let running = try runningAVDs()
        guard let serial = running.first(where: { $0.value == canonical })?.key else {
            let label = canonical == avd ? avd : "\(avd)(ID: \(canonical))"
            throw AndroidDeviceCatalogError.avdNotRunning(label, running: running)
        }
        return serial
    }

    /// serial のブート完了確認(`adb shell getprop sys.boot_completed` が "1" か)。
    /// adb 自体が不安定/未応答等で取得できない場合は安全側(未完了 = false)を返す
    /// (呼び出し元はこれを「ブリッジ APK インストールを試みてよいか」の判定に使うため)
    public static func bootCompleted(serial: String) -> Bool {
        guard let adbPath = try? AndroidDriver.findADB() else { return false }
        guard let result = try? Shell.run(
            [adbPath, "-s", serial, "shell", "getprop", "sys.boot_completed"]) else {
            return false
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// AVD ID の取得: `adb emu avd name`(出力 "<AVD名>\nOK")→ 空なら
    /// getprop ro.boot.qemu.avd_name / ro.kernel.qemu.avd_name にフォールバック
    /// (環境によって emu コンソールが名前を返さないことがある)
    static func avdName(adbPath: String, serial: String) -> String? {
        if let output = try? Shell.run([adbPath, "-s", serial, "emu", "avd", "name"]).output,
           let first = output.split(separator: "\n").first
               .map({ $0.trimmingCharacters(in: .whitespaces) }),
           !first.isEmpty, first != "OK" {
            return first
        }
        for prop in ["ro.boot.qemu.avd_name", "ro.kernel.qemu.avd_name"] {
            if let output = try? Shell.run([adbPath, "-s", serial, "shell", "getprop", prop]).output {
                let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }
}
