// SandboxBroker.swift
// サンドボックスの中のシナリオ実行バイナリは CoreSimulator・adb サーバへ繋げない(繋げると `simctl spawn` /
// `adb shell` で枠の外にプロセスを起こせる)。Simulator・iOS 実機・Android の操作は**親が代わりに実行する**:
// 子の `Shell.run` が `xcrun simctl …` / `xcrun devicectl …` / `<…>/adb …` を unix ソケット越しに親へ送り
// (`SandboxGateway`)、親は `BrokerPolicy`(`SimctlPolicy` / `DevicectlPolicy` / `AdbPolicy`)が認めた形だけを
// 枠の外で実行して結果を返す。
//
// ワイヤ(1接続 = 1往復・どちらも JSON 1行。対向は同じファイルの `SandboxGateway`):
//   要求 {"argv":[…], "timeout":秒?, "stdin":base64?}
//   応答 {"status":Int, "output":base64} / {"refused":"理由"}
import Foundation

// MARK: - 方針(純粋)

/// 親が子の代わりに実行してよい `simctl` の形。**列挙に無い形は断る**(新しい呼び出しを足したら
/// ここにも足す。足し忘れはサンドボックス有効時だけ赤になる = `Scripts/e2e.sh --sandbox`)
public enum SimctlPolicy {
    public struct Context: Sendable, Equatable {
        /// このレーンのデバイス。nil(ポートだけを指定した run)ならデバイスは問わない
        public var udid: String?
        public var deviceName: String?
        /// ツール本体のルート(注入する dylib の置き場 `<root>/InAppBridge/build/` の親)
        public var toolRoots: [String]
        /// 子が書ける場所(実体パス)。ここにある物はインストールも注入もさせない
        public var childWritableRoots: [String]
        public var childWritablePattern: String?
        /// このレーンの Android 端末。nil(serial を持たない run)なら端末は問わない
        public var serial: String?
        /// 親が adb を代行するときに使う adb(子が送ってきたパスは使わない)。nil なら adb は断る
        public var adbPath: String?
        /// 親が `.apks` のインストールを代行するときに使う bundletool。nil なら bundletool は断る
        public var bundletool: [String]?

        public init(udid: String?, deviceName: String?, toolRoots: [String],
                    childWritableRoots: [String], childWritablePattern: String? = nil,
                    serial: String? = nil, adbPath: String? = nil, bundletool: [String]? = nil) {
            self.udid = udid
            self.deviceName = deviceName
            self.toolRoots = toolRoots
            self.childWritableRoots = childWritableRoots
            self.childWritablePattern = childWritablePattern
            self.serial = serial
            self.adbPath = adbPath
            self.bundletool = bundletool
        }
    }

    public struct Refusal: Error, Equatable {
        public let reason: String
    }

    /// アプリへ渡してよい環境変数(`InAppLauncher.relaunch` が渡す集合)
    static let launchEnvironmentKeys: Set<String> = [
        "DYLD_INSERT_LIBRARIES", "FT_PORT", "FT_OWNER_REPO", "FT_WEBVIEW_DOM",
    ]

    /// `Shell.run` の引数列(先頭に `NAME=VALUE` が並びうる)から simctl の呼び出しを切り出す。
    /// simctl でなければ nil
    public static func split(_ argv: [String]) -> (environment: [String: String], simctl: [String])? {
        guard let parts = BrokerPolicy.split(argv), parts.tool == "simctl" else { return nil }
        return (parts.environment, parts.arguments)
    }

    public static func check(_ argv: [String], context: Context) -> Refusal? {
        guard let (environment, simctl) = split(argv), let verb = simctl.first else {
            return Refusal(reason: "not a simctl command")
        }
        let rest = Array(simctl.dropFirst())
        if verb != "launch", !environment.isEmpty {
            return Refusal(reason: "environment variables are only accepted for simctl launch")
        }
        func device(_ token: String) -> Refusal? {
            guard let udid = context.udid else { return nil }
            return token == udid || token == context.deviceName
                ? nil : Refusal(reason: "simctl \(verb) targets another device: \(token)")
        }
        func bundle(_ token: String) -> Refusal? {
            isBundleID(token) ? nil : Refusal(reason: "not a bundle ID: \(token)")
        }
        switch verb {
        case "list":
            return rest == ["devices", "-j"] || rest == ["-j", "devicetypes", "devices"]
                ? nil : Refusal(reason: "simctl list \(rest.joined(separator: " ")) is not allowed")
        case "listapps":
            guard rest.count == 1 else { return shape(verb) }
            return device(rest[0])
        case "bootstatus":
            guard rest.count == 2, rest[1] == "-b" else { return shape(verb) }
            return device(rest[0])
        case "terminate", "uninstall":
            guard rest.count == 2 else { return shape(verb) }
            return device(rest[0]) ?? bundle(rest[1])
        case "get_app_container":
            guard rest.count == 2 || (rest.count == 3 && ["app", "data"].contains(rest[2])) else {
                return shape(verb)
            }
            return device(rest[0]) ?? bundle(rest[1])
        case "privacy":
            guard rest.count == 4, rest[1] == "reset", rest[2] == "all" else { return shape(verb) }
            return device(rest[0]) ?? bundle(rest[3])
        case "openurl":
            guard rest.count == 2 else { return shape(verb) }
            return device(rest[0])
        case "install":
            guard rest.count == 2 else { return shape(verb) }
            if let refusal = device(rest[0]) { return refusal }
            // 子が書ける場所のアプリは入れない(枠の中で作った実行物を Simulator = 枠の外で動かせる)
            return isChildWritable(rest[1], context: context)
                ? Refusal(reason: "simctl install from a location the sandboxed scenario can write: \(rest[1])")
                : nil
        case "launch":
            var arguments = rest
            if arguments.first == "--terminate-running-process" { arguments.removeFirst() }
            guard arguments.count == 2 else { return shape(verb) }
            return device(arguments[0]) ?? bundle(arguments[1]) ?? launchEnvironment(environment, context: context)
        case "spawn":
            // `simctl spawn` は Simulator の中(= 枠の外)で任意のコマンドを起こす口。固定の2形だけ
            guard rest.count >= 1 else { return shape(verb) }
            let command = Array(rest.dropFirst())
            guard command == ["launchctl", "list"]
                    || command == ["launchctl", "kickstart", "-k", "system/com.apple.cfprefsd.xpc.daemon"] else {
                return Refusal(reason: "simctl spawn \(command.joined(separator: " ")) is not allowed")
            }
            return device(rest[0])
        default:
            return Refusal(reason: "simctl \(verb) is not allowed from a sandboxed scenario")
        }
    }

    private static func shape(_ verb: String) -> Refusal {
        Refusal(reason: "simctl \(verb) was called with arguments the sandbox does not allow")
    }

    public static func isBundleID(_ token: String) -> Bool {
        !token.isEmpty && !token.hasPrefix("-")
            && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    private static func launchEnvironment(_ environment: [String: String], context: Context) -> Refusal? {
        for (key, value) in environment {
            guard key.hasPrefix("SIMCTL_CHILD_") else {
                return Refusal(reason: "environment variable \(key) is not allowed for simctl launch")
            }
            let name = String(key.dropFirst("SIMCTL_CHILD_".count))
            guard launchEnvironmentKeys.contains(name) else {
                return Refusal(reason: "environment variable \(name) is not allowed for the launched app")
            }
            if name == "DYLD_INSERT_LIBRARIES", !isBridgeLibrary(value, context: context) {
                return Refusal(reason: "DYLD_INSERT_LIBRARIES is not the in-app bridge: \(value)")
            }
        }
        return nil
    }

    /// 注入してよいのはツール本体の `InAppBridge/build/` の下だけ(子には書けない場所)
    static func isBridgeLibrary(_ path: String, context: Context) -> Bool {
        guard !path.contains(":"), !isChildWritable(path, context: context) else { return false }
        let real = ScenarioSandbox.canonicalPath(path)
        return context.toolRoots.contains { real.hasPrefix(ScenarioSandbox.canonicalPath($0) + "/InAppBridge/build/") }
    }

    static func isChildWritable(_ path: String, context: Context) -> Bool {
        let real = ScenarioSandbox.canonicalPath(path)
        if context.childWritableRoots.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) {
            return true
        }
        if let pattern = context.childWritablePattern,
           real.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}

/// 親が子の代わりに実行してよい `devicectl`(iOS 実機)の形。子は `devicectl` を枠の中から使えない
/// (CoreDevice の XPC を開けると、`simctl` と同じく枠の外で操作させる口になる)。
/// **列挙に無い形は断る**(新しい呼び出しを足したらここにも足す)
public enum DevicectlPolicy {
    public static func check(_ args: [String], context: SimctlPolicy.Context) -> SimctlPolicy.Refusal? {
        func refuse(_ reason: String) -> SimctlPolicy.Refusal { SimctlPolicy.Refusal(reason: reason) }
        func device(_ token: String) -> SimctlPolicy.Refusal? {
            guard let udid = context.udid else { return nil }
            return token == udid ? nil : refuse("devicectl targets another device: \(token)")
        }
        /// 親に書かせる出力先。`-`(標準出力)か、子が元々書ける場所だけ(親を使って任意の場所へ書かせない)
        func output(_ token: String) -> SimctlPolicy.Refusal? {
            token == "-" || SimctlPolicy.isChildWritable(token, context: context)
                ? nil : refuse("devicectl --json-output outside the sandbox's writable locations: \(token)")
        }
        switch args {
        case ["list", "devices", "--json-output", "-", "-q"]:
            return nil
        case let a where a.count == 8 && Array(a[0..<4]) == ["device", "info", "apps", "--device"]
                && a[5] == "--include-all-apps" && a[6] == "--json-output":
            return device(a[4]) ?? output(a[7])
        case let a where a.count == 7 && Array(a[0..<4]) == ["device", "info", "lockState", "--device"]
                && Array(a[5...]) == ["--json-output", "-"]:
            return device(a[4])
        case let a where a.count == 8 && Array(a[0..<4]) == ["device", "info", "details", "--device"]
                && Array(a[5...]) == ["--json-output", "-", "-q"]:
            return device(a[4])
        case let a where a.count == 7 && Array(a[0..<4]) == ["device", "info", "processes", "--device"]
                && a[5] == "--json-output":
            return device(a[4]) ?? output(a[6])
        case let a where a.count == 6 && Array(a[0..<4]) == ["device", "install", "app", "--device"]:
            if let refusal = device(a[4]) { return refusal }
            // 子が書ける場所のアプリは入れない(枠の中で作った実行物を実機で動かせる)
            return SimctlPolicy.isChildWritable(a[5], context: context)
                ? refuse("devicectl install from a location the sandboxed scenario can write: \(a[5])") : nil
        case let a where a.count == 6 && Array(a[0..<4]) == ["device", "uninstall", "app", "--device"]:
            return device(a[4]) ?? (SimctlPolicy.isBundleID(a[5]) ? nil : refuse("not a bundle ID: \(a[5])"))
        case let a where a.count == 6 && Array(a[0..<4]) == ["device", "process", "openURL", "--device"]:
            return device(a[4])
        default:
            return refuse("devicectl \(args.prefix(3).joined(separator: " ")) is not allowed from a sandboxed scenario")
        }
    }
}

/// broker が代行するコマンドの振り分け(`xcrun simctl …` / `xcrun devicectl …` / `<…>/adb …` / bundletool)
public enum BrokerPolicy {
    static let tools: Set<String> = ["simctl", "devicectl"]

    /// `Shell.run` の引数列(先頭に `NAME=VALUE` が並びうる)から代行の対象を切り出す。対象でなければ nil
    public static func split(_ argv: [String]) -> (environment: [String: String], tool: String, arguments: [String])? {
        var environment: [String: String] = [:]
        var index = 0
        while index < argv.count, let eq = argv[index].firstIndex(of: "="),
              !argv[index].hasPrefix("/"), argv[index] != "xcrun" {
            let key = String(argv[index][..<eq])
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { break }
            environment[key] = String(argv[index][argv[index].index(after: eq)...])
            index += 1
        }
        // adb は絶対パスで起こされる(`AndroidDriver.findADB`)。名前だけで見分け、実行は親の adb で行う
        if argv.count >= index + 2, (argv[index] as NSString).lastPathComponent == "adb" {
            return (environment, "adb", Array(argv[(index + 1)...]))
        }
        // bundletool は実行ファイルか `java -jar <….jar>`(`BundletoolLocator`)。実行は親の bundletool で行う
        if argv.count >= index + 2, (argv[index] as NSString).lastPathComponent == "bundletool" {
            return (environment, "bundletool", Array(argv[(index + 1)...]))
        }
        if argv.count >= index + 4, (argv[index] as NSString).lastPathComponent == "java",
           argv[index + 1] == "-jar", argv[index + 2].lowercased().hasSuffix(".jar") {
            return (environment, "bundletool", Array(argv[(index + 3)...]))
        }
        guard argv.count >= index + 3, argv[index] == "xcrun", tools.contains(argv[index + 1]) else {
            return nil
        }
        return (environment, argv[index + 1], Array(argv[(index + 2)...]))
    }

    /// 親が実際に実行する引数列。adb と bundletool は子が送ったパスを捨てて親が見つけたものへ差し替える
    /// (子に任意の実行ファイルを `adb` / `bundletool` という名前で実行させない)
    public static func executableArgv(_ argv: [String], context: SimctlPolicy.Context) -> [String]? {
        guard let (_, tool, arguments) = split(argv) else { return nil }
        switch tool {
        case "adb": return context.adbPath.map { [$0] + arguments }
        case "bundletool": return BundletoolPolicy.executableArgv(arguments, context: context)
        default: return argv
        }
    }

    public static func check(_ argv: [String], context: SimctlPolicy.Context) -> SimctlPolicy.Refusal? {
        guard let (environment, tool, arguments) = split(argv) else {
            return SimctlPolicy.Refusal(reason: "not a simctl or devicectl command")
        }
        if tool == "simctl" { return SimctlPolicy.check(argv, context: context) }
        guard environment.isEmpty else {
            return SimctlPolicy.Refusal(reason: "environment variables are not accepted for \(tool)")
        }
        if tool == "adb" {
            guard context.adbPath != nil else {
                return SimctlPolicy.Refusal(reason: "adb was not found on this Mac (set ANDROID_HOME)")
            }
            return AdbPolicy.check(arguments, context: context)
        }
        if tool == "bundletool" {
            guard context.bundletool != nil, context.adbPath != nil else {
                return SimctlPolicy.Refusal(reason: "bundletool or adb was not found on this Mac"
                    + " (brew install bundletool, or set FT_BUNDLETOOL / ANDROID_HOME)")
            }
            return BundletoolPolicy.check(arguments, context: context)
        }
        return DevicectlPolicy.check(arguments, context: context)
    }
}

// MARK: - 親側

/// シナリオ1本(子1つ)ごとに立てる。レーンのデバイスに固定した方針で答えるので、子が他のレーンの
/// ソケットへ繋いでも自分のデバイス以外は触れない(プロファイルは自分のソケットしか開けない)
// @unchecked: 格納プロパティはすべて不変(`execute` は @Sendable)。接続ごとのスレッドは引数の fd だけを触る
public final class SandboxBroker: @unchecked Sendable {
    public let socketPath: String
    private let context: SimctlPolicy.Context
    private let descriptor: Int32
    private let execute: @Sendable ([String], Double?, Data?) -> (status: Int32, output: Data)

    /// 1往復で読む要求の上限(バイト)。`simctl` の引数列と base64 の stdin が収まればよい
    static let maxRequestBytes = 1 << 20

    public init(context: SimctlPolicy.Context, directory: String,
                execute: (@Sendable ([String], Double?, Data?) -> (status: Int32, output: Data))? = nil) throws {
        self.context = context
        self.execute = execute ?? { argv, timeout, stdin in
            let result = try? Shell.runRaw(argv, timeout: timeout, stdin: stdin)
            return (result?.0 ?? 127, result?.1 ?? Data("cannot run \(argv.first ?? "the command")".utf8))
        }
        socketPath = (directory as NSString).appendingPathComponent("ftb-\(UUID().uuidString.prefix(8)).sock")
        descriptor = try UnixSocket.listen(path: socketPath)
        let thread = Thread { [descriptor, weak self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                guard let self else { close(client); return }
                Thread.detachNewThread { self.serve(client) }
            }
        }
        thread.name = "fleetest-sandbox-broker"
        thread.start()
    }

    public func stop() {
        // shutdown で accept を起こしてから閉じる(close だけでは待っているスレッドが戻らない)
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(socketPath)
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        guard let line = UnixSocket.readLine(client, limit: Self.maxRequestBytes),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let argv = object["argv"] as? [String] else {
            UnixSocket.writeLine(client, ["refused": "malformed request"])
            return
        }
        if let refusal = BrokerPolicy.check(argv, context: context) {
            // 親のログにも残す: 子のドライバには失敗を捨てる呼び出し(`try?`)があり、子へ返すだけでは
            // 方針の足し忘れが黙った縮退になる
            let shown = argv.map { ($0 as NSString).lastPathComponent == "adb" ? "adb" : $0 }.joined(separator: " ")
            ConsoleOut.err("sandbox: refused \(shown) — \(refusal.reason)")
            UnixSocket.writeLine(client, ["refused": refusal.reason])
            return
        }
        guard let executable = BrokerPolicy.executableArgv(argv, context: context) else {
            UnixSocket.writeLine(client, ["refused": "cannot resolve the command to run"])
            return
        }
        let stdin = (object["stdin"] as? String).flatMap { Data(base64Encoded: $0) }
        let result = execute(executable, object["timeout"] as? Double, stdin)
        UnixSocket.writeLine(client, [
            "status": Int(result.status), "output": result.output.base64EncodedString(),
        ])
    }
}

// MARK: - 子側

/// `Shell.runRaw` の入口で呼ぶ。**`FT_SANDBOX_BROKER` が立っているときだけ**働く(立てるのは
/// サンドボックスで包むときの `ScenarioHost`)。simctl / devicectl / adb / bundletool 以外は nil を返して素通しする
public enum SandboxGateway {
    public static let environmentKey = "FT_SANDBOX_BROKER"
    /// 立っていると adb / bundletool を親へ送らず子が自分で実行する(`MachineSettings.allowDirectAdb`)
    public static let directAdbKey = "FT_SANDBOX_DIRECT_ADB"
    /// 断られたときの終了コード(シェルの「実行できない」と同じ 126)
    public static let refusedStatus: Int32 = 126

    static let socketPath: String? = {
        let path = ProcessInfo.processInfo.environment[environmentKey]
        return (path?.isEmpty ?? true) ? nil : path
    }()

    static let directAdb = ProcessInfo.processInfo.environment[directAdbKey] == "1"

    static func intercept(_ argv: [String], timeout: Double?, stdin: Data?) -> (Int32, Data)? {
        guard let socketPath else { return nil }
        if directAdb, passesThroughWhenDirect(argv) { return nil }
        return forward(argv, timeout: timeout, stdin: stdin, socketPath: socketPath)
    }

    /// `allowDirectAdb` のとき子が自分で実行する呼び出し(adb と bundletool)
    static func passesThroughWhenDirect(_ argv: [String]) -> Bool {
        guard let tool = BrokerPolicy.split(argv)?.tool else { return false }
        return tool == "adb" || tool == "bundletool"
    }

    static func forward(_ argv: [String], timeout: Double?, stdin: Data?,
                        socketPath: String) -> (Int32, Data)? {
        guard BrokerPolicy.split(argv) != nil else { return nil }
        var request: [String: Any] = ["argv": argv]
        if let timeout { request["timeout"] = timeout }
        if let stdin { request["stdin"] = stdin.base64EncodedString() }
        guard let client = try? UnixSocket.connect(path: socketPath) else {
            return (refusedStatus, Data("sandbox: cannot reach the fleetest broker at \(socketPath)".utf8))
        }
        defer { close(client) }
        UnixSocket.writeLine(client, request)
        guard let line = UnixSocket.readLine(client, limit: Int.max),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return (refusedStatus, Data("sandbox: the fleetest broker closed the connection".utf8))
        }
        if let refused = object["refused"] as? String {
            return (refusedStatus, Data("sandbox: refused — \(refused)".utf8))
        }
        let output = (object["output"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        return (Int32(object["status"] as? Int ?? Int(refusedStatus)), output)
    }
}

// MARK: - ソケット

enum UnixSocket {
    struct PathTooLong: Error {}

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw PathTooLong() }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func listen(path: String) throws -> Int32 {
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        // **待受に掛ける**(accept したソケットが引き継ぐ)。相手が先に閉じた後では setsockopt が
        // 失敗し、応答の write が SIGPIPE で親ごと落とす = 子が接続を切るだけで run を殺せる
        var noSigpipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // 同じユーザーの他プロセスからも繋がせない理由は無いが、他ユーザーには開けない
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    static func connect(path: String) throws -> Int32 {
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var noSigpipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    static func readLine(_ descriptor: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count <= limit {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return data.isEmpty ? nil : data }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[..<newline])
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        return nil
    }

    static func writeLine(_ descriptor: Int32, _ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        var noSigpipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}
