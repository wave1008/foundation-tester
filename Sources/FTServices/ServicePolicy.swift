// スクリプト(Seatbelt の中)からの中継コマンドの要求 → ランタイム CLI の argv(docs/remote-runner.md §17「スクリプト」④)。
// 純粋。認めるのは exec(標準入力つき)・logs・status・port の4形だけで、ランタイムのオプションは利用者に書かせない
// (`--env-file` 等で親に任意のファイルを読ませない)。サービスの集合は宣言(`containers`)だけが決める。

import FTCore

/// スクリプトへ見せる公開ポート1つ(ServicePlan の HostBinding から呼び手が写す)。
public struct ServicePublication: Sendable, Equatable {
    public var service: String
    public var containerPort: Int
    public var proto: PortPublish.Proto
    public var hostIP: String
    public var hostPort: Int

    public init(service: String, containerPort: Int, proto: PortPublish.Proto, hostIP: String, hostPort: Int) {
        self.service = service
        self.containerPort = containerPort
        self.proto = proto
        self.hostIP = hostIP
        self.hostPort = hostPort
    }
}

/// 方針が知っていること(呼び手が計画と解決済みランタイムから作る)。
public struct ServiceGatewayInputs: Sendable, Equatable {
    public var runtime: ServiceRuntime
    /// ランタイム CLI の絶対パス。
    public var executable: String
    /// /usr/bin/env へ先頭で渡す "NAME=VALUE"(DOCKER_HOST 等の制御変数)。
    public var controlEnvironment: [String]
    /// サービス名 → コンテナ名。宣言したサービスだけ(中継・エコーは入れない = 入っていないものは断られる)。
    public var containers: [String: String]
    public var published: [ServicePublication]

    public init(runtime: ServiceRuntime, executable: String, controlEnvironment: [String],
                containers: [String: String], published: [ServicePublication]) {
        self.runtime = runtime
        self.executable = executable
        self.controlEnvironment = controlEnvironment
        self.containers = containers
        self.published = published
    }
}

public struct ServicePolicy: ServiceGatewayPolicy, Sendable {
    /// logs の既定の行数と上限(行)。根拠: 既定 100 は端末1画面分の数倍で原因の把握に足りる。
    /// 上限 10_000 は 1 行 200 B として約 2 MB = 中継で一度に返す量の上限(それ以上はログの保存の仕事)。
    /// 尽きたとき = 断る(切り詰めない)。
    public static let defaultLogLines = 100
    public static let maxLogLines = 10_000

    static let usage = "usage: fleetest-services exec <service> -- <command…> | logs <service> [--tail N] | status | port <service> <containerPort>[/udp]"

    private let inputs: ServiceGatewayInputs

    public init(inputs: ServiceGatewayInputs) { self.inputs = inputs }

    public func decide(_ request: [String]) -> ServiceGatewayDecision {
        guard let verb = request.first else { return .refused(Self.usage) }
        let rest = Array(request.dropFirst())
        switch verb {
        case "exec": return exec(rest)
        case "logs": return logs(rest)
        case "status": return status(rest)
        case "port": return port(rest)
        default: return .refused(Self.usage)
        }
    }

    private func undeclared(_ name: String) -> ServiceGatewayDecision {
        .refused("service \(name) is not declared in compose.yaml (declared: \(declaredNames().joined(separator: ", ")))")
    }

    private func declaredNames() -> [String] {
        inputs.containers.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    private func invocation(_ runtimeArgs: [String], stdin: Bool) -> ServiceGatewayDecision {
        .run(argv: inputs.controlEnvironment + [inputs.executable] + runtimeArgs, stdin: stdin)
    }

    private func exec(_ args: [String]) -> ServiceGatewayDecision {
        guard let service = args.first else { return .refused(Self.usage) }
        if service.hasPrefix("-") {
            return .refused("exec takes no options; write: fleetest-services exec <service> -- <command…>")
        }
        guard let container = inputs.containers[service] else { return undeclared(service) }
        var command = Array(args.dropFirst())
        // `--` は1つだけ落とす(2つ目以降はコマンド自身の引数)。**ランタイムへは `--` を渡さない** —— Docker も Apple も
        // コンテナ名の後ろを全部コマンドとして扱い(`-e` / `--env-file` / `--` は実行対象になって失敗する。両方で実測)、
        // 利用者のコマンドがオプションとして解釈される経路は無い
        if command.first == "--" { command.removeFirst() }
        if command.isEmpty { return .refused("exec needs a command to run inside \(service)") }
        let argv: [String]
        switch inputs.runtime {
        case .docker: argv = DockerCommands.containerExecInteractive(name: container, argv: command)
        case .apple: argv = AppleContainerCommands.containerExecInteractive(name: container, argv: command)
        }
        return invocation(argv, stdin: true)
    }

    private func logs(_ args: [String]) -> ServiceGatewayDecision {
        guard let service = args.first else { return .refused(Self.usage) }
        guard let container = inputs.containers[service] else { return undeclared(service) }
        let extra = Array(args.dropFirst())
        var tail = Self.defaultLogLines
        if !extra.isEmpty {
            guard extra[0] == "--tail", extra.count <= 2 else { return .refused("logs takes only --tail N") }
            let tailMessage = "--tail takes an integer from 1 to \(Self.maxLogLines)"
            guard extra.count == 2, let n = Self.decimal(extra[1]), n >= 1, n <= Self.maxLogLines else {
                return .refused(tailMessage)
            }
            tail = n
        }
        let argv: [String]
        switch inputs.runtime {
        case .docker: argv = DockerCommands.containerLogs(name: container, tail: tail)
        case .apple: argv = AppleContainerCommands.containerLogs(name: container, tail: tail)
        }
        return invocation(argv, stdin: false)
    }

    private func status(_ args: [String]) -> ServiceGatewayDecision {
        if !args.isEmpty { return .refused("status takes no arguments") }
        return .text(declaredNames().map { "\($0)\t\(inputs.containers[$0] ?? "")" }.joined(separator: "\n"))
    }

    private func port(_ args: [String]) -> ServiceGatewayDecision {
        guard args.count == 2 else { return .refused(Self.usage) }
        let service = args[0]
        guard inputs.containers[service] != nil else { return undeclared(service) }
        let portMessage = "port takes a container port such as 5432 or 5432/udp"
        let parts = args[1].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let number = Self.decimal(parts[0]), (1...65535).contains(number) else {
            return .refused(portMessage)
        }
        var proto = PortPublish.Proto.tcp
        if parts.count == 2 {
            guard parts[1] == "udp" else { return .refused(portMessage) }
            proto = .udp
        }
        guard let hit = inputs.published.first(where: {
            $0.service == service && $0.containerPort == number && $0.proto == proto
        }) else {
            return .refused("service \(service) publishes no port \(number)/\(proto.rawValue)")
        }
        return .text("\(hit.hostIP):\(hit.hostPort)")
    }

    /// ASCII 数字だけの非負整数(`Int()` は "+5" "-5" も受けるので使わない。桁あふれは nil)。
    private static func decimal(_ s: String) -> Int? {
        guard !s.isEmpty, s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(s)
    }
}
