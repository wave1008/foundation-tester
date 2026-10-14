// ComposePolicy.Checked → 実行計画。純粋関数(ファイルシステム・ネットワーク・時刻・乱数に触れない)。
// 2つのランタイム(Docker / Apple)は計画を実行するだけ。設計は docs/remote-runner.md §17。

import CryptoKit
import Foundation

public struct CheckPorts: Sendable, Equatable {
    public var tcp: Int
    public var udp: Int
    public init(tcp: Int, udp: Int) {
        self.tcp = tcp
        self.udp = udp
    }
}

public struct PlanOptions: Sendable, Equatable {
    public var runtime: ServiceRuntime
    /// 接頭辞の元(実体パス)。
    public var workspaceRealpath: String
    /// 控えの世代。計画はラベルに写すだけ。
    public var generation: String
    /// true のとき lanAddress が要る。
    public var physicalLanes: Bool
    public var lanAddress: String?
    /// nil = 許可した宛先が無い(プロキシの環境も中継の転送も作らない)。
    public var proxyPort: Int?
    /// /udp の公開があるときは必須。
    public var checkPorts: CheckPorts?
    /// 中継とエコーのイメージ ID(親が記録した digest。タグでは探さない)。
    public var relayImageID: String

    public init(runtime: ServiceRuntime, workspaceRealpath: String, generation: String,
                physicalLanes: Bool = false, lanAddress: String? = nil, proxyPort: Int? = nil,
                checkPorts: CheckPorts? = nil, relayImageID: String) {
        self.runtime = runtime
        self.workspaceRealpath = workspaceRealpath
        self.generation = generation
        self.physicalLanes = physicalLanes
        self.lanAddress = lanAddress
        self.proxyPort = proxyPort
        self.checkPorts = checkPorts
        self.relayImageID = relayImageID
    }
}

public struct HostBinding: Sendable, Equatable {
    public var hostIP: String
    public var hostPort: Int
    public var containerPort: Int
    public var proto: PortPublish.Proto
    public init(hostIP: String, hostPort: Int, containerPort: Int, proto: PortPublish.Proto) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }
}

public struct ResolvedMount: Sendable, Equatable {
    /// bind は実体パス・volume は接頭辞つきの名前。
    public var source: String
    public var target: String
    public var readOnly: Bool
    public var isVolume: Bool
    public init(source: String, target: String, readOnly: Bool, isVolume: Bool) {
        self.source = source
        self.target = target
        self.readOnly = readOnly
        self.isVolume = isVolume
    }
}

public struct ContainerLaunch: Sendable, Equatable {
    public var name: String
    public var service: String
    /// build のときは nil(呼び手がビルドして埋める)。
    public var image: String?
    /// context / dockerfile は実体パスに置き換え済み。
    public var build: BuildDef?
    public var command: [String]?
    public var entrypoint: [String]?
    /// 展開済み。呼び手が親専用の env-file に書く(コマンドラインに載せない)。
    public var environment: [EnvEntry]
    public var envFiles: [String]
    public var mounts: [ResolvedMount]
    /// Apple だけ。Docker は空(中継が受け持つ)。
    public var publishes: [HostBinding]
    public var networks: [String]
    /// Docker だけ(--network-alias)。Apple は空。
    public var aliases: [String]
    public var labels: [String: String]
    public var healthcheck: Healthcheck?
    public var dependsOn: [Dependency]
    public var workingDir: String?
    public var user: String?
    public var platform: String?
    public var initProcess: Bool?
    public var stopGracePeriod: String?
    public var memLimit: String?
    public var cpus: Double?
    public var tmpfs: [String]
    /// 宣言した全サービス名 + localhost,127.0.0.1,::1。
    public var noProxy: [String]
    /// Apple の URL のホストは ServicePlanner.gatewayPlaceholder(呼び手が差し替える)。
    public var proxyEnvironment: [EnvEntry]

    public init(
        name: String, service: String, image: String?, build: BuildDef?, command: [String]?,
        entrypoint: [String]?, environment: [EnvEntry], envFiles: [String], mounts: [ResolvedMount],
        publishes: [HostBinding], networks: [String], aliases: [String], labels: [String: String],
        healthcheck: Healthcheck?, dependsOn: [Dependency], workingDir: String?, user: String?,
        platform: String?, initProcess: Bool?, stopGracePeriod: String?, memLimit: String?,
        cpus: Double?, tmpfs: [String], noProxy: [String], proxyEnvironment: [EnvEntry]
    ) {
        self.name = name
        self.service = service
        self.image = image
        self.build = build
        self.command = command
        self.entrypoint = entrypoint
        self.environment = environment
        self.envFiles = envFiles
        self.mounts = mounts
        self.publishes = publishes
        self.networks = networks
        self.aliases = aliases
        self.labels = labels
        self.healthcheck = healthcheck
        self.dependsOn = dependsOn
        self.workingDir = workingDir
        self.user = user
        self.platform = platform
        self.initProcess = initProcess
        self.stopGracePeriod = stopGracePeriod
        self.memLimit = memLimit
        self.cpus = cpus
        self.tmpfs = tmpfs
        self.noProxy = noProxy
        self.proxyEnvironment = proxyEnvironment
    }
}

public struct RelayForward: Sendable, Equatable {
    public var hostIP: String
    public var hostPort: Int
    public var targetService: String
    public var targetPort: Int
    public var proto: PortPublish.Proto
    public init(hostIP: String, hostPort: Int, targetService: String, targetPort: Int,
                proto: PortPublish.Proto) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.targetService = targetService
        self.targetPort = targetPort
        self.proto = proto
    }
}

/// Docker だけ。
public struct RelayPlan: Sendable, Equatable {
    public var name: String
    public var imageID: String
    public var internalNetwork: String
    public var egressNetwork: String
    /// targetService は宣言したサービス名か、確認用のエコーのコンテナ名。
    public var forwards: [RelayForward]
    /// 中継の中で待ち受け、host.docker.internal:<proxyPort> へ転送するポート。
    public var proxyListenPort: Int?
    public init(name: String, imageID: String, internalNetwork: String, egressNetwork: String,
                forwards: [RelayForward], proxyListenPort: Int?) {
        self.name = name
        self.imageID = imageID
        self.internalNetwork = internalNetwork
        self.egressNetwork = egressNetwork
        self.forwards = forwards
        self.proxyListenPort = proxyListenPort
    }
}

public struct UDPCheckPlan: Sendable, Equatable {
    public var echoName: String
    public var imageID: String
    public var tcpHostPort: Int
    public var udpHostPort: Int
    /// 常に 127.0.0.1(実機のレーンを含む run でも LAN に出さない)。
    public var hostIP: String
    public init(echoName: String, imageID: String, tcpHostPort: Int, udpHostPort: Int, hostIP: String) {
        self.echoName = echoName
        self.imageID = imageID
        self.tcpHostPort = tcpHostPort
        self.udpHostPort = udpHostPort
        self.hostIP = hostIP
    }
}

public struct ServicePlan: Sendable, Equatable {
    public var prefix: String
    public var internalNetwork: String
    public var userNetworks: [String: String]
    public var volumes: [String: String]
    /// depends_on のトポロジカル順(同順位は compose の記述順)。
    public var containers: [ContainerLaunch]
    public var relay: RelayPlan?
    public var udpCheck: UDPCheckPlan?
    /// Apple だけ。起動のたびに親が追記する順 = containers の順。
    public var hostsFileOrder: [String]
    /// 予約の名前空間 "fleetest-*" に入る全ての名前(片付けの列挙に使う)。
    public var publicNames: [String]
    public init(prefix: String, internalNetwork: String, userNetworks: [String: String],
                volumes: [String: String], containers: [ContainerLaunch], relay: RelayPlan?,
                udpCheck: UDPCheckPlan?, hostsFileOrder: [String], publicNames: [String]) {
        self.prefix = prefix
        self.internalNetwork = internalNetwork
        self.userNetworks = userNetworks
        self.volumes = volumes
        self.containers = containers
        self.relay = relay
        self.udpCheck = udpCheck
        self.hostsFileOrder = hostsFileOrder
        self.publicNames = publicNames
    }
}

public enum ServicePlanError: Error, Sendable, Equatable {
    case physicalLanesNeedLANAddress
    case udpPublishedWithoutCheckPorts
    case unresolvedRealpath(String)
}

public enum ServicePlanner {
    /// 予約ラベルのキー。利用者の同名ラベルは上書きする。片付けの照合がこの綴りに依る。
    public static let generationLabel = "fleetest-generation"
    public static let prefixLabel = "fleetest-prefix"
    public static let serviceLabel = "fleetest-service"
    /// Apple のプロキシ URL のホスト。ゲートウェイの IP は起動してから分かるので呼び手が差し替える。
    public static let gatewayPlaceholder = "<gateway>"

    /// 接頭辞の桁数: 12 桁の hex = 48 ビット。同一マシン上のプロジェクト数では衝突を無視できる
    /// (WorkspaceAppStaging.declaredPathNamespace と同じ長さ)。
    private static let prefixHexDigits = 12
    private static let loopback = "127.0.0.1"
    private static let noProxyFixed = ["localhost", "127.0.0.1", "::1"]

    public static func prefix(forWorkspace realpath: String) -> String {
        let hex = SHA256.hash(data: Data(realpath.utf8)).map { String(format: "%02x", $0) }.joined()
        return "fleetest-" + hex.prefix(prefixHexDigits)
    }

    public static func make(_ checked: ComposePolicy.Checked, options: PlanOptions)
        -> Result<ServicePlan, ServicePlanError> {
        let spec = checked.spec
        let isDocker = options.runtime == .docker
        let hasLAN = options.physicalLanes
        if hasLAN && options.lanAddress == nil { return .failure(.physicalLanesNeedLANAddress) }

        let hasUDP = spec.services.contains { $0.ports.contains { $0.proto == .udp } }
        if hasUDP && options.checkPorts == nil { return .failure(.udpPublishedWithoutCheckPorts) }

        let prefix = prefix(forWorkspace: options.workspaceRealpath)
        let internalNetwork = prefix
        var userNetworks: [String: String] = [:]
        for n in spec.networks { userNetworks[n.name] = "\(prefix)-\(n.name)" }
        var volumes: [String: String] = [:]
        for v in spec.volumes { volumes[v.name] = "\(prefix)-\(v.name)" }

        func real(_ declared: String) -> Result<String, ServicePlanError> {
            if let r = checked.realpaths[declared] { return .success(r) }
            return .failure(.unresolvedRealpath(declared))
        }

        let serviceNames = spec.services.map(\.name)
        let noProxy = serviceNames + noProxyFixed
        let proxyEnv = proxyEnvironment(options: options, prefix: prefix, noProxy: noProxy)

        var launches: [String: ContainerLaunch] = [:]
        var relayForwards: [RelayForward] = []
        let serviceHostIP = hasLAN ? "0.0.0.0" : loopback

        for s in spec.services {
            var mounts: [ResolvedMount] = []
            for m in s.mounts {
                switch m {
                case let .bind(source, target, readOnly):
                    switch real(source) {
                    case let .success(p): mounts.append(ResolvedMount(source: p, target: target, readOnly: readOnly, isVolume: false))
                    case let .failure(e): return .failure(e)
                    }
                case let .volume(name, target, readOnly):
                    mounts.append(ResolvedMount(source: volumes[name] ?? "\(prefix)-\(name)", target: target,
                                                readOnly: readOnly, isVolume: true))
                }
            }
            var envFiles: [String] = []
            for f in s.envFiles {
                switch real(f) {
                case let .success(p): envFiles.append(p)
                case let .failure(e): return .failure(e)
                }
            }
            var build = s.build
            if var b = build {
                switch real(b.context) {
                case let .success(p): b.context = p
                case let .failure(e): return .failure(e)
                }
                // dockerfile は省略時も鍵がある(context/Dockerfile)。検査が記録した実体パスを同じ鍵で引く
                switch real(ComposePolicy.dockerfileKey(context: s.build?.context ?? b.context, dockerfile: b.dockerfile)) {
                case let .success(p): b.dockerfile = p
                case let .failure(e): return .failure(e)
                }
                build = b
            }

            var networks = [internalNetwork]
            for n in s.networks {
                let mapped = (n == "default") ? internalNetwork : (userNetworks[n] ?? "\(prefix)-\(n)")
                if !networks.contains(mapped) { networks.append(mapped) }
            }

            var publishes: [HostBinding] = []
            for p in s.ports {
                if isDocker {
                    relayForwards.append(RelayForward(hostIP: serviceHostIP, hostPort: p.hostPort,
                                                      targetService: s.name, targetPort: p.containerPort,
                                                      proto: p.proto))
                } else {
                    publishes.append(HostBinding(hostIP: p.hostIP ?? loopback, hostPort: p.hostPort,
                                                 containerPort: p.containerPort, proto: p.proto))
                    if hasLAN, let lan = options.lanAddress {
                        publishes.append(HostBinding(hostIP: lan, hostPort: p.hostPort,
                                                     containerPort: p.containerPort, proto: p.proto))
                    }
                }
            }

            var labels = s.labels
            labels[generationLabel] = options.generation
            labels[prefixLabel] = prefix
            labels[serviceLabel] = s.name

            launches[s.name] = ContainerLaunch(
                name: "\(prefix)-\(s.name)", service: s.name, image: s.image, build: build,
                command: s.command, entrypoint: s.entrypoint, environment: s.environment,
                envFiles: envFiles, mounts: mounts, publishes: publishes, networks: networks,
                aliases: isDocker ? [s.name] : [], labels: labels, healthcheck: s.healthcheck,
                dependsOn: s.dependsOn, workingDir: s.workingDir, user: s.user, platform: s.platform,
                initProcess: s.initProcess, stopGracePeriod: s.stopGracePeriod, memLimit: s.memLimit,
                cpus: s.cpus, tmpfs: s.tmpfs, noProxy: noProxy, proxyEnvironment: proxyEnv)
        }

        let order = topologicalOrder(spec.services)
        let containers = order.compactMap { launches[$0] }

        var udpCheck: UDPCheckPlan?
        let echoName = "\(prefix)-udpcheck"
        if hasUDP, let cp = options.checkPorts {
            udpCheck = UDPCheckPlan(echoName: echoName, imageID: options.relayImageID, tcpHostPort: cp.tcp,
                                    udpHostPort: cp.udp, hostIP: loopback)
            if isDocker {
                // 確認用は実機のときも 127.0.0.1(確認する経路が 127.0.0.1 なので LAN に出す理由が無い)
                relayForwards.append(RelayForward(hostIP: loopback, hostPort: cp.tcp, targetService: echoName,
                                                  targetPort: cp.tcp, proto: .tcp))
                relayForwards.append(RelayForward(hostIP: loopback, hostPort: cp.udp, targetService: echoName,
                                                  targetPort: cp.udp, proto: .udp))
            }
        }

        let egress = "\(prefix)-egress"
        let relayName = "\(prefix)-relay"
        var relay: RelayPlan?
        if isDocker {
            relay = RelayPlan(name: relayName, imageID: options.relayImageID, internalNetwork: internalNetwork,
                              egressNetwork: egress, forwards: relayForwards, proxyListenPort: options.proxyPort)
        }

        var publicNames = containers.map(\.name)
        if relay != nil { publicNames.append(relayName) }
        if udpCheck != nil { publicNames.append(echoName) }
        publicNames.append(internalNetwork)
        if isDocker { publicNames.append(egress) }
        publicNames += spec.networks.compactMap { userNetworks[$0.name] }
        publicNames += spec.volumes.compactMap { volumes[$0.name] }

        return .success(ServicePlan(
            prefix: prefix, internalNetwork: internalNetwork, userNetworks: userNetworks, volumes: volumes,
            containers: containers, relay: relay, udpCheck: udpCheck,
            hostsFileOrder: isDocker ? [] : containers.map(\.name), publicNames: publicNames))
    }

    private static func proxyEnvironment(options: PlanOptions, prefix: String, noProxy: [String]) -> [EnvEntry] {
        guard let port = options.proxyPort else { return [] }
        let host = options.runtime == .docker ? "\(prefix)-relay" : gatewayPlaceholder
        let url = "http://\(host):\(port)"
        let np = noProxy.joined(separator: ",")
        return [
            EnvEntry(key: "HTTP_PROXY", value: url), EnvEntry(key: "HTTPS_PROXY", value: url),
            EnvEntry(key: "http_proxy", value: url), EnvEntry(key: "https_proxy", value: url),
            EnvEntry(key: "NO_PROXY", value: np), EnvEntry(key: "no_proxy", value: np),
        ]
    }

    /// 記述順に辿り、各サービスの依存を先に出す(深さ優先の後順)= 利用者が書いた順を依存が許す限り保つ。
    /// 宣言に無い相手への依存は無視する。循環は辿り中の印で止めて記述順で続ける(断るのは正規化の役目)
    private static func topologicalOrder(_ services: [ServiceDef]) -> [String] {
        let byName = Dictionary(services.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var emitted: [String] = []
        var done = Set<String>()
        var visiting = Set<String>()
        func visit(_ service: ServiceDef) {
            if done.contains(service.name) || visiting.contains(service.name) { return }
            visiting.insert(service.name)
            for dependency in service.dependsOn {
                if let target = byName[dependency.service] { visit(target) }
            }
            visiting.remove(service.name)
            done.insert(service.name)
            emitted.append(service.name)
        }
        for service in services { visit(service) }
        return emitted
    }
}
