// マシンプロファイルの Android デバイス指定(avd)→ adb シリアルの解決。
// avd は AVD の ID("Pixel_9_Android_16")と表示名("Pixel 9(Android 16)"、config.ini の
// avd.ini.displayname)のどちらでも書け、起動中エミュレータの AVD ID と照合して serial に解決する。

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
        // ポーリングループ内から呼ばれる。wedge した adb で締切が無効化しないよう時限化(10s)。
        let devices = try Shell.run([adbPath, "devices"], timeout: 10)
        return devices.output.split(separator: "\n").dropFirst()
            .filter { $0.contains("\tdevice") }
            .compactMap { $0.split(separator: "\t").first.map(String.init) }
    }

    /// adb が把握している全エミュレータの serial(offline/unauthorized 含む)。
    /// シャットダウン時は offline のエミュレータにも kill を送る必要がある
    public static func allEmulatorSerials() throws -> [String] {
        let adbPath = try AndroidDriver.findADB()
        let devices = try Shell.run([adbPath, "devices"], timeout: 10)
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

    /// AVD ホームディレクトリ(ANDROID_AVD_HOME → ~/.android/avd)。
    /// AndroidDataWiper と共用(wipe 対象ディレクトリの解決に使う)
    public static func avdHomeDirectory() -> URL {
        ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".android/avd")
    }

    /// AVD の実体ディレクトリ。**`<id>.avd` の機械組み立てではなく `<id>.ini` の `path=` が正**
    /// (emulator も ini を見る。Android Studio の改名で別名ディレクトリを指すことがある。
    /// 実例 2026-07-17: Pixel_9_Android_15_ の実体は Pixel_9_Android_15__1.avd で、
    /// `.avd` 直組みの wiper が空の残骸を測り 11.5GiB の実体が wipe をすり抜けた)。
    /// ini 欠落・path 不在時は `<home>/<id>.avd` にフォールバック
    public static func avdContentDirectory(id: String) -> URL {
        avdContentDirectory(id: id, home: avdHomeDirectory())
    }

    static func avdContentDirectory(id: String, home: URL) -> URL {
        let fallback = home.appendingPathComponent("\(id).avd")
        let ini = home.appendingPathComponent("\(id).ini")
        guard let text = try? String(contentsOf: ini, encoding: .utf8) else { return fallback }
        for line in text.split(separator: "\n") where line.hasPrefix("path=") {
            let path = String(line.dropFirst("path=".count)).trimmingCharacters(in: .whitespaces)
            var isDir: ObjCBool = false
            if !path.isEmpty,
               FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        return fallback
    }

    public static func installedAVDs() -> [(id: String, displayName: String?)] {
        let home = avdHomeDirectory()
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

    /// 一致しなければ入力をそのまま返す(後段の照合エラーメッセージで内容が分かるようにするため)
    public static func canonicalAVDID(_ name: String) -> String {
        canonicalAVDID(name, installed: installedAVDs())
    }

    /// 照合順序: ①id 完全一致 ②Android Studio の id 生成規則(非英数字→_)で正規化した候補
    /// ③displayName 一致。②を③より先に行うのは、displayName は ini を失った孤児 .avd
    /// ディレクトリにも一致し起動不能な id を返しうるため(実例 2026-07-16: "Pixel 9(Android 15)"
    /// が ini 無しの Pixel_9_Android_15__1 に解決され serial 検出の 60 秒タイムアウトまで待った)
    static func canonicalAVDID(
        _ name: String, installed: [(id: String, displayName: String?)]
    ) -> String {
        if installed.contains(where: { $0.id == name }) { return name }
        let sanitized = String(name.map { ch in
            ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_" ? ch : "_"
        })
        if sanitized != name, installed.contains(where: { $0.id == sanitized }) { return sanitized }
        if let match = installed.first(where: { $0.displayName == name }) { return match.id }
        return name
    }

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

    /// adb 不安定等で取得できない場合は安全側(未完了=false)を返す
    /// (呼び出し元は「ブリッジ APK インストールを試みてよいか」の判定にこれを使う)
    public static func bootCompleted(serial: String) -> Bool {
        guard let adbPath = try? AndroidDriver.findADB() else { return false }
        guard let result = try? Shell.run(
            [adbPath, "-s", serial, "shell", "getprop", "sys.boot_completed"]) else {
            return false
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// `adb emu avd name`(出力 "<AVD名>\nOK")が空/失敗の場合は getprop の
    /// ro.boot.qemu.avd_name / ro.kernel.qemu.avd_name にフォールバック(環境依存で emu が返さない)
    static func avdName(adbPath: String, serial: String) -> String? {
        if let output = try? Shell.run([adbPath, "-s", serial, "emu", "avd", "name"], timeout: 10).output,
           let first = output.split(separator: "\n").first
               .map({ $0.trimmingCharacters(in: .whitespaces) }),
           !first.isEmpty, first != "OK" {
            return first
        }
        for prop in ["ro.boot.qemu.avd_name", "ro.kernel.qemu.avd_name"] {
            if let output = try? Shell.run([adbPath, "-s", serial, "shell", "getprop", prop], timeout: 10).output {
                let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }
}
