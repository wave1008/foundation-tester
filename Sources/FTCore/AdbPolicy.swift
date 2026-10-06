// AdbPolicy.swift
// サンドボックスの中のシナリオ実行バイナリは adb サーバ(5037)と Emulator の adbd / コンソールへ繋げない
// (繋げると `adb shell` で Emulator の中 = 枠の外から外部へ出られ、繋がった全 Android 端末を操作・読み出せる)。
// 子の `adb …` は `SandboxGateway` が親へ送り、親はここで認めた形だけを**自分の adb で**実行する。
// **列挙に無い形は断る**(新しい adb の呼び出しを足したらここにも足す。足し忘れはサンドボックスの中でだけ赤になる。
// FTAndroid の引数の組み立てとの一致は `AdbPolicyBuilderSyncTests` が見る)。
// `adb shell` は引数を空白で結合して端末の sh に解釈し直させるので、値が入る欄はすべて文法で検める。
import Foundation

/// Android のパッケージ名のうち、端末の sh へそのまま渡してよいもの(唯一の定義元。
/// FTAndroid の `AndroidPackageName` とブリッジの Java `isShellSafePackageName` が写す)
public enum AndroidPackageNameGrammar {
    /// 先頭が英字・残りが英数字 / `_` / `.` だけ
    public static func isShellSafe(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isASCIILetter(first) else { return false }
        return name.unicodeScalars.allSatisfy {
            isASCIILetter($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "."
        }
    }

    private static func isASCIILetter(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s)
    }
}

/// adb の場所(唯一の定義元。FTAndroid の `AndroidDriver.findADB` もここを引く)。
/// 親(サンドボックスの broker)が子に代わって実行するときは、子が送ってきたパスではなくこれを使う
public enum AdbLocator {
    public static func adbPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let candidates = [
            environment["ANDROID_HOME"].map { $0 + "/platform-tools/adb" },
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// adb サーバのポート(`ANDROID_ADB_SERVER_PORT`。既定 5037)
    public static func adbServerPort(environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt16 {
        environment["ANDROID_ADB_SERVER_PORT"].flatMap(UInt16.init) ?? 5037
    }

    /// Emulator がホストのループバックに開くポート(コンソール = 偶数・adbd = 奇数)。adb が Emulator を
    /// 探す範囲と同じ 5554〜5585(16 台ぶん)
    public static let emulatorPorts: ClosedRange<UInt16> = 5554...5585
}

/// bundletool の場所(唯一の定義元。FTAndroid の `ApksBundle.findBundletool` もここを引く)。
/// 実行コマンド(argv の先頭部分)。`FT_BUNDLETOOL` は実行ファイルでも `.jar` でもよい(jar なら `java -jar`)。
/// PATH に頼り切らず既知の場所も見るのは、ssh 越しの非対話シェルが /opt/homebrew を PATH に持たないため
public enum BundletoolLocator {
    public static func find(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [String]? {
        if let override = environment["FT_BUNDLETOOL"], !override.isEmpty {
            if override.lowercased().hasSuffix(".jar") { return ["java", "-jar", override] }
            return isExecutable(override) ? [override] : nil
        }
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in pathDirs + ["/opt/homebrew/bin", "/usr/local/bin"] where !dir.isEmpty {
            let candidate = dir.hasSuffix("/") ? dir + "bundletool" : dir + "/bundletool"
            if isExecutable(candidate) { return [candidate] }
        }
        return nil
    }
}

/// 親が子の代わりに実行してよい bundletool の形(`.apks` のインストールだけ)。bundletool は adb サーバへ
/// 自分で繋ぐので、枠の中(adb サーバを閉じている)では動かない。**親自身の bundletool と adb で**実行する
public enum BundletoolPolicy {
    /// `args` は bundletool のコマンドを除いた引数列:
    /// `install-apks --apks=<絶対パス.apks> --adb=<無視して親の adb> [--device-id=<レーンの serial>]`
    public static func check(_ args: [String], context: SimctlPolicy.Context) -> SimctlPolicy.Refusal? {
        func refuse(_ reason: String) -> SimctlPolicy.Refusal { SimctlPolicy.Refusal(reason: reason) }
        guard let parsed = parse(args) else {
            return refuse("bundletool \(args.first ?? "") is not allowed from a sandboxed scenario")
        }
        guard parsed.apks.hasPrefix("/"), parsed.apks.lowercased().hasSuffix(".apks") else {
            return refuse("bundletool install-apks needs an absolute .apks path: \(parsed.apks)")
        }
        // 子が書ける場所の物は入れない(枠の中で作った実行物を端末で動かせる)
        if SimctlPolicy.isChildWritable(parsed.apks, context: context) {
            return refuse("bundletool install-apks from a location the sandboxed scenario can write: \(parsed.apks)")
        }
        if let lane = context.serial, parsed.deviceID != lane {
            return refuse("bundletool install-apks targets another device: \(parsed.deviceID ?? "(none)")")
        }
        return nil
    }

    static func parse(_ args: [String]) -> (apks: String, deviceID: String?)? {
        guard args.count == 3 || args.count == 4, args[0] == "install-apks",
              args[1].hasPrefix("--apks="), args[2].hasPrefix("--adb=") else { return nil }
        var deviceID: String?
        if args.count == 4 {
            guard args[3].hasPrefix("--device-id=") else { return nil }
            deviceID = String(args[3].dropFirst("--device-id=".count))
        }
        return (String(args[1].dropFirst("--apks=".count)), deviceID)
    }

    /// 親が実際に実行する引数列(bundletool と adb は親が見つけたもの)
    static func executableArgv(_ args: [String], context: SimctlPolicy.Context) -> [String]? {
        guard let bundletool = context.bundletool, let adb = context.adbPath, let parsed = parse(args) else { return nil }
        var argv = bundletool + ["install-apks", "--apks=\(parsed.apks)", "--adb=\(adb)"]
        if let deviceID = parsed.deviceID { argv.append("--device-id=\(deviceID)") }
        return argv
    }
}

public enum AdbPolicy {

    /// 端末の sh へ渡す文字列ごとの形(どれも FTAndroid の組み立てと一字一句同じ。同期は `AdbPolicyBuilderSyncTests`)
    static let screenCheckCommand = "dumpsys power | grep -m1 mWakefulness=; "
        + "dumpsys activity activities | grep -m1 topResumedActivity=; true"
    static let bridgeCodePathCommand = "pm path com.example.ftbridge 2>/dev/null; echo FT_PM_PATH_DONE"
    static let instrumentPattern = #"^am instrument -w -e port 8123 -e ttl [0-9]+( -e owner '[^'\n]*')?( -e timing 1)? com\.example\.ftbridge/\.BridgeInstrumentation </dev/null >/data/local/tmp/ftbridge-instrument\.log 2>&1 &\z"#
    static let webViewSocketProbePattern = #"^pidof ([A-Za-z0-9_.]+); echo --ft-sockets--; cat /proc/net/unix \| grep devtools_remote\z"#
    static let debuggableProbePattern = #"^getprop ro\.debuggable; echo --ft-debuggable--; dumpsys package ([A-Za-z0-9_.]+) \| grep flags=\z"#
    static let logcatTimePattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\z"#

    /// 引数を持たない(または値が固定の)形
    static let exactCommands: Set<[String]> = [
        ["shell", "true"], ["shell", "wm", "density"], ["shell", "wm", "dismiss-keyguard"],
        ["shell", "dumpsys", "window", "windows"], ["shell", "dumpsys", "window", "displays"],
        ["shell", "dumpsys", "activity", "service", "com.android.systemui/.SystemUIService"],
        ["shell", "dumpsys", "activity", "activities"], ["shell", "dumpsys", "power"],
        ["shell", "dumpsys", "deviceidle", "get", "deep"], ["shell", "date", "+%z"],
        ["shell", "dumpsys", "package", "com.example.ftbridge"],
        ["shell", "cat", "/data/local/tmp/ftbridge-instrument.log"],
        ["shell", "settings", "get", "system", "user_rotation"],
        ["shell", "settings", "get", "system", "accelerometer_rotation"],
        ["shell", "settings", "put", "secure", "stylus_handwriting_enabled", "0"],
        ["shell", "settings", "put", "global", "hide_error_dialogs", "1"],
        ["shell", "settings", "put", "global", "hidden_api_policy", "1"],
        ["shell", "settings", "get", "global", "verifier_verify_adb_installs"],
        ["shell", "settings", "delete", "global", "verifier_verify_adb_installs"],
        ["shell", screenCheckCommand], ["shell", bridgeCodePathCommand],
        ["forward", "tcp:0", "tcp:8123"], ["forward", "--list"],
        ["get-serialno"], ["get-state"],
    ]

    static let keyEvents: Set<String> = ["KEYCODE_APP_SWITCH", "KEYCODE_HOME", "KEYCODE_BACK", "KEYCODE_WAKEUP", "66"]
    static let animationKeys: Set<String> = ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"]

    /// `args` は adb のパスを除いた引数列(`-s <serial>` から始まりうる)
    public static func check(_ args: [String], context: SimctlPolicy.Context) -> SimctlPolicy.Refusal? {
        func refuse(_ reason: String) -> SimctlPolicy.Refusal { SimctlPolicy.Refusal(reason: reason) }
        var command = args
        if command.first == "-s" {
            guard command.count >= 2 else { return refuse("adb -s without a serial") }
            if let lane = context.serial, command[1] != lane {
                return refuse("adb targets another device: \(command[1])")
            }
            command.removeFirst(2)
        } else if let lane = context.serial, command != ["devices"] {
            // `-s` 無しは「繋がっている唯一の端末」= レーン以外にも届きうる
            return refuse("adb without -s \(lane) is not allowed (this lane drives \(lane))")
        }
        guard !command.isEmpty else { return refuse("empty adb command") }
        if command == ["devices"] { return nil }
        return shapeAllowed(command, context: context)
            ? nil : refuse("adb \(command.prefix(4).joined(separator: " ")) is not allowed from a sandboxed scenario")
    }

    static func shapeAllowed(_ c: [String], context: SimctlPolicy.Context) -> Bool {
        if exactCommands.contains(c) { return true }
        let pkg = AndroidPackageNameGrammar.isShellSafe
        switch c.count {
        case 2:
            if c[0] == "uninstall" { return pkg(c[1]) }
            if c[0] == "install" { return installable(c[1], context: context) }
            if c[0] == "shell" {
                return matches(c[1], instrumentPattern)
                    || captured(c[1], webViewSocketProbePattern).map(pkg) == true
                    || captured(c[1], debuggableProbePattern).map(pkg) == true
            }
        case 3:
            if c[0] == "shell", c[1] == "pidof" { return pkg(c[2]) }
            if c[0] == "install", c[1] == "-r" { return installable(c[2], context: context) }
            if c[0] == "forward", c[1] == "--remove" { return tcpPort(c[2]) != nil }
            if c[0] == "forward" { return (tcpPort(c[1]) ?? 0) > 0 && devtoolsSocket(c[2]) }
        case 4:
            if Array(c[0..<3]) == ["shell", "pm", "clear"] || Array(c[0..<3]) == ["shell", "am", "force-stop"] {
                return pkg(c[3])
            }
            if Array(c[0..<3]) == ["shell", "input", "keyevent"] { return keyEvents.contains(c[3]) }
        case 5:
            if Array(c[0..<4]) == ["shell", "pm", "list", "packages"] { return pkg(c[4]) || c[4] == "-3" || c[4] == "-s" }
            if Array(c[0..<4]) == ["shell", "settings", "get", "global"] { return animationKeys.contains(c[4]) }
        case 6:
            if Array(c[0..<4]) == ["shell", "settings", "put", "system"],
               ["user_rotation", "accelerometer_rotation"].contains(c[4]) { return integer(c[5]) }
            if Array(c[0..<4]) == ["shell", "settings", "put", "global"] {
                if animationKeys.contains(c[4]) { return decimal(c[5]) }
                if c[4] == "verifier_verify_adb_installs" { return integer(c[5]) }
            }
        default:
            break
        }
        if c.first == "logcat" { return logcatAllowed(c) }
        if c.count == 8, Array(c[0..<3]) == ["shell", "input", "swipe"] { return c[3...].allSatisfy(integer) }
        if c.count == 7, Array(c[0..<3]) == ["shell", "monkey", "-p"] {
            return pkg(c[3]) && Array(c[4...]) == ["-c", "android.intent.category.LAUNCHER", "1"]
        }
        // shell am start -W -a android.intent.action.VIEW -d '<url>' [<pkg>]
        if c.count == 8 || c.count == 9,
           Array(c[0..<7]) == ["shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d"] {
            return quotedURL(c[7]) && (c.count == 8 || pkg(c[8]))
        }
        return false
    }

    /// `logcat -d -b crash [-t <ts>]` / `logcat -d -b main -b crash [-t <ts>] [--pid <n>]`
    static func logcatAllowed(_ c: [String]) -> Bool {
        var rest: ArraySlice<String>
        if c.starts(with: ["logcat", "-d", "-b", "main", "-b", "crash"]) {
            rest = c.dropFirst(6)
        } else if c.starts(with: ["logcat", "-d", "-b", "crash"]) {
            rest = c.dropFirst(4)
        } else {
            return false
        }
        if rest.first == "-t" {
            guard rest.count >= 2, matches(rest[rest.startIndex + 1], logcatTimePattern) else { return false }
            rest = rest.dropFirst(2)
        }
        if rest.first == "--pid" {
            guard rest.count == 2, integer(rest[rest.startIndex + 1]) else { return false }
            rest = rest.dropFirst(2)
        }
        return rest.isEmpty
    }

    /// 端末の sh に解釈させない URL: 1要素の中で `'…'` に包まれ、中に `'` が無い
    static func quotedURL(_ token: String) -> Bool {
        token.count >= 2 && token.hasPrefix("'") && token.hasSuffix("'")
            && !token.dropFirst().dropLast().contains("'")
    }

    /// 子が書ける場所の APK は入れない(枠の中で作った実行物を端末で動かせる)
    static func installable(_ path: String, context: SimctlPolicy.Context) -> Bool {
        path.hasPrefix("/") && path.hasSuffix(".apk") && !SimctlPolicy.isChildWritable(path, context: context)
    }

    static func devtoolsSocket(_ token: String) -> Bool {
        guard token.hasPrefix("localabstract:") else { return false }
        let name = String(token.dropFirst("localabstract:".count))
        if name == "chrome_devtools_remote" { return true }
        let prefix = "webview_devtools_remote_"
        return name.hasPrefix(prefix) && integer(String(name.dropFirst(prefix.count)))
    }

    static func tcpPort(_ token: String) -> UInt16? {
        guard token.hasPrefix("tcp:") else { return nil }
        return UInt16(token.dropFirst(4))
    }

    static func integer(_ token: String) -> Bool {
        let digits = token.hasPrefix("-") ? Substring(token.dropFirst()) : Substring(token)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func decimal(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    static func matches(_ token: String, _ pattern: String) -> Bool {
        token.range(of: pattern, options: .regularExpression) != nil
    }

    static func captured(_ token: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: token) else { return nil }
        return String(token[range])
    }
}
