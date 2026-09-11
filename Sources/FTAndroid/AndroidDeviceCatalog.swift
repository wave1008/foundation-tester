// マシンプロファイルの Android デバイス指定(avd)→ adb シリアルの解決。
// avd は AVD の ID("Pixel_9_Android_16")と表示名("Pixel 9(Android 16)"、config.ini の
// avd.ini.displayname)のどちらでも書け、起動中エミュレータの AVD ID と照合して serial に解決する。

import Foundation
import FTCore

public enum AndroidDeviceCatalogError: Error, LocalizedError {
    /// `revivalFailure` は復活失敗の理由の受け渡し(`RevivalOutcomeLedger`): この run が開始時に
    /// この AVD を復活させようとして失敗していれば、その理由をここへ載せる。
    /// nil のときは復活を試みていない(=そもそも触っていない)ので従来どおり `devices up` を案内する
    case avdNotRunning(String, running: [String: String], revivalFailure: String?)
    case noIdentifier(name: String)
    /// kind=physical の serial が adb に見えない
    case deviceNotConnected(name: String, serial: String, connected: [String])

    public var errorDescription: String? {
        switch self {
        case .avdNotRunning(let avd, let running, let revivalFailure):
            let list = running.isEmpty ? "none"
                : running.map { "\($0.value)(\($0.key))" }.sorted().joined(separator: ", ")
            // この run が起動前に自分でこの AVD を復活させようとして失敗していたなら、
            // その実際の理由を言う ——「devices up で起動しろ」は復活済み・そもそも触っていない
            // 場合の案内で、復活を試みて失敗した場合には的外れ(投げられるのは最初の解決失敗であって
            // 復活失敗の理由ではなかった。実害)
            if let revivalFailure {
                return "no running emulator for AVD \"\(avd)\" (running: \(list)). "
                    + "This run tried to revive it before starting and that failed: \(revivalFailure)"
            }
            return "no running emulator for AVD \"\(avd)\" (running: \(list)). "
                + "Start one with: fleetest devices up, or emulator -avd <ID>"
        case .noIdentifier(let name):
            return "device \"\(name)\" has no avd (add it to the machine profile)"
        case .deviceNotConnected(let name, let serial, let connected):
            let list = connected.isEmpty ? "none" : connected.joined(separator: ", ")
            return "physical device \"\(name)\" (serial: \(serial)) is not visible to adb (connected: \(list)). "
                + "Check the USB connection, the USB-debugging approval on the device, and state=device in `adb devices`"
        }
    }
}

public enum AndroidDeviceCatalog {

    /// この列挙の adb 呼び出しの締切(秒)。`api monitor` の既定周期 2 秒のループから呼ばれるので、
    /// wedge した adbd に無期限に握らせない(数 tick ぶんで諦める)。尽きると Shell が子を kill して
    /// `ShellError.timedOut` を投げる = 各呼び出し側は「取得できない」と同じ扱い
    /// (bootCompleted は false、avdName は次の経路へ)
    public static let adbTimeoutSeconds: Double = 10

    /// 接続中のデバイスシリアル一覧(state = device のみ)
    public static func connectedSerials() throws -> [String] {
        let adbPath = try AndroidDriver.findADB()
        let devices = try Shell.run([adbPath, "devices"], timeout: adbTimeoutSeconds)
        return devices.output.split(separator: "\n").dropFirst()
            .filter { $0.contains("\tdevice") }
            .compactMap { $0.split(separator: "\t").first.map(String.init) }
    }

    /// adb が把握している全エミュレータの serial(offline/unauthorized 含む)。
    /// シャットダウン時は offline のエミュレータにも kill を送る必要がある
    public static func allEmulatorSerials() throws -> [String] {
        let adbPath = try AndroidDriver.findADB()
        let devices = try Shell.run([adbPath, "devices"], timeout: adbTimeoutSeconds)
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

    /// AVD の config.ini から任意キーを引く(値が無ければ nil)
    static func avdConfigValue(id: String, key: String) -> String? {
        let config = avdContentDirectory(id: id).appendingPathComponent("config.ini")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix(key + "=") {
            let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// AVD の機種名(config.ini の hw.device.name。例 "pixel_9")と OS 表記
    /// ("Android 15"。image.sysdir.1 の android-<API> から導出)。表示専用
    public static func avdModelAndOS(id: String) -> (model: String?, os: String?) {
        let model = avdConfigValue(id: id, key: "hw.device.name")
        // image.sysdir.1 = "system-images/android-35/google_apis/arm64-v8a/"
        let api = avdConfigValue(id: id, key: "image.sysdir.1")
            .flatMap { sysdir -> Int? in
                sysdir.split(separator: "/")
                    .first { $0.hasPrefix("android-") }
                    .flatMap { Int($0.dropFirst("android-".count)) }
            }
        return (model, api.map { MachineProfileEditor.androidVersionName(apiLevel: $0) })
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

    /// 実機は serial 直指定(AVD 照合は使えない)。接続確認だけして返す。
    /// エミュレータは従来どおり avd → 起動中エミュレータの AVD ID 照合
    public static func resolveSerial(spec: DeviceSpec) throws -> String {
        if spec.isPhysical {
            let serial = spec.serial ?? ""
            let connected = (try? connectedSerials()) ?? []
            guard connected.contains(serial) else {
                throw AndroidDeviceCatalogError.deviceNotConnected(
                    name: spec.name, serial: serial, connected: connected)
            }
            return serial
        }
        guard let avd = spec.avd else {
            throw AndroidDeviceCatalogError.noIdentifier(name: spec.name)
        }
        let canonical = canonicalAVDID(avd)
        let running = try runningAVDs()
        guard let serial = running.first(where: { $0.value == canonical })?.key else {
            throw avdNotRunningError(
                avd: avd, canonical: canonical, running: running,
                revivalFailure: RevivalOutcomeLedger.shared.failureReason(avdID: canonical))
        }
        return serial
    }

    /// `.avdNotRunning` の組み立て(純粋関数。adb を叩かないので `RevivalOutcomeLedger` の
    /// 読み出し結果込みでテストできる)
    static func avdNotRunningError(
        avd: String, canonical: String, running: [String: String], revivalFailure: String?
    ) -> AndroidDeviceCatalogError {
        let label = canonical == avd ? avd : "\(avd)(ID: \(canonical))"
        return .avdNotRunning(label, running: running, revivalFailure: revivalFailure)
    }

    /// adb 不安定等で取得できない場合は安全側(未完了=false)を返す
    /// (呼び出し元は「ブリッジ APK インストールを試みてよいか」の判定にこれを使う)。
    /// gRPC getStatus.booted は true のときだけ確定として使い、false/取得不可は従来の getprop で
    /// 再確認する(booted の立つタイミングが sys.boot_completed と同一である保証がないため、
    /// 判定 semantics を変えない安全側)
    public static func bootCompleted(serial: String) async -> Bool {
        if await EmulatorControl.statusBooted(serial: serial) == true { return true }
        guard let adbPath = try? AndroidDriver.findADB() else { return false }
        guard let result = try? Shell.run(
            [adbPath, "-s", serial, "shell", "getprop", "sys.boot_completed"],
            timeout: adbTimeoutSeconds) else {
            return false
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// serial → AVD 名。まずディスカバリファイル(adb 不要・EmulatorControl.avdName)、
    /// 無ければ `adb emu avd name`(出力 "<AVD名>\nOK")、それも空/失敗なら getprop の
    /// ro.boot.qemu.avd_name / ro.kernel.qemu.avd_name にフォールバック(環境依存で emu が返さない)
    static func avdName(adbPath: String, serial: String) -> String? {
        if let name = EmulatorControl.avdName(serial: serial) {
            return name
        }
        if let output = try? Shell.run([adbPath, "-s", serial, "emu", "avd", "name"], timeout: adbTimeoutSeconds).output,
           let first = output.split(separator: "\n").first
               .map({ $0.trimmingCharacters(in: .whitespaces) }),
           !first.isEmpty, first != "OK" {
            return first
        }
        for prop in ["ro.boot.qemu.avd_name", "ro.kernel.qemu.avd_name"] {
            if let output = try? Shell.run([adbPath, "-s", serial, "shell", "getprop", prop], timeout: adbTimeoutSeconds).output {
                let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }
}
