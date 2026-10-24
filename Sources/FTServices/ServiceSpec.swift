// 正規化後の compose.yaml。短縮形と長い形は ComposeNormalizer が1つの形に畳んである。
// 文字列は宣言どおり(変数の展開前・パスの解決前)。

public struct ServiceSpec: Sendable, Equatable {
    /// compose の記述順。
    public var services: [ServiceDef]
    public var networks: [NetworkDef]
    public var volumes: [VolumeDef]
    /// 無視して通した最上位のキー(`version`・`x-*`)。起動時に1行言うための記録。
    public var ignoredTopLevelKeys: [String]

    public init(services: [ServiceDef], networks: [NetworkDef], volumes: [VolumeDef], ignoredTopLevelKeys: [String]) {
        self.services = services
        self.networks = networks
        self.volumes = volumes
        self.ignoredTopLevelKeys = ignoredTopLevelKeys
    }
}

public struct ServiceDef: Sendable, Equatable {
    public var name: String
    public var image: String?
    public var build: BuildDef?
    public var command: [String]?
    public var entrypoint: [String]?
    /// 順序つき。
    public var environment: [EnvEntry]
    public var envFiles: [String]
    public var ports: [PortPublish]
    public var expose: [Int]
    public var mounts: [MountDecl]
    public var tmpfs: [String]
    public var healthcheck: Healthcheck?
    public var dependsOn: [Dependency]
    public var workingDir: String?
    public var user: String?
    public var networks: [String]
    public var labels: [String: String]
    public var platform: String?
    public var initProcess: Bool?
    public var stopGracePeriod: String?
    public var memLimit: String?
    public var cpus: Double?

    public init(
        name: String, image: String? = nil, build: BuildDef? = nil, command: [String]? = nil,
        entrypoint: [String]? = nil, environment: [EnvEntry] = [], envFiles: [String] = [],
        ports: [PortPublish] = [], expose: [Int] = [], mounts: [MountDecl] = [], tmpfs: [String] = [],
        healthcheck: Healthcheck? = nil, dependsOn: [Dependency] = [], workingDir: String? = nil,
        user: String? = nil, networks: [String] = [], labels: [String: String] = [:],
        platform: String? = nil, initProcess: Bool? = nil, stopGracePeriod: String? = nil,
        memLimit: String? = nil, cpus: Double? = nil
    ) {
        self.name = name
        self.image = image
        self.build = build
        self.command = command
        self.entrypoint = entrypoint
        self.environment = environment
        self.envFiles = envFiles
        self.ports = ports
        self.expose = expose
        self.mounts = mounts
        self.tmpfs = tmpfs
        self.healthcheck = healthcheck
        self.dependsOn = dependsOn
        self.workingDir = workingDir
        self.user = user
        self.networks = networks
        self.labels = labels
        self.platform = platform
        self.initProcess = initProcess
        self.stopGracePeriod = stopGracePeriod
        self.memLimit = memLimit
        self.cpus = cpus
    }
}

public struct EnvEntry: Sendable, Equatable {
    public var key: String
    /// nil = 値なし。親の環境から継がない(後段は空として扱う)。
    public var value: String?

    public init(key: String, value: String?) {
        self.key = key
        self.value = value
    }
}

public struct PortPublish: Sendable, Equatable {
    public enum Proto: String, Sendable, Equatable {
        case tcp
        case udp
    }

    public var hostIP: String?
    public var hostPort: Int
    public var containerPort: Int
    public var proto: Proto

    public init(hostIP: String?, hostPort: Int, containerPort: Int, proto: Proto) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }
}

public enum MountDecl: Sendable, Equatable {
    /// source は宣言どおりの文字列。
    case bind(source: String, target: String, readOnly: Bool)
    case volume(name: String, target: String, readOnly: Bool)
}

public struct Healthcheck: Sendable, Equatable {
    public enum Test: Sendable, Equatable {
        case cmd([String])
        case cmdShell(String)
        case none
    }

    public var test: Test
    public var interval: String?
    public var timeout: String?
    public var retries: Int?
    public var startPeriod: String?
    public var disable: Bool

    public init(test: Test, interval: String? = nil, timeout: String? = nil, retries: Int? = nil,
                startPeriod: String? = nil, disable: Bool = false) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
        self.startPeriod = startPeriod
        self.disable = disable
    }
}

public struct Dependency: Sendable, Equatable {
    public enum Condition: String, Sendable, Equatable {
        case serviceStarted = "service_started"
        case serviceHealthy = "service_healthy"
        case serviceCompletedSuccessfully = "service_completed_successfully"
    }

    public var service: String
    public var condition: Condition

    public init(service: String, condition: Condition) {
        self.service = service
        self.condition = condition
    }
}

public struct BuildDef: Sendable, Equatable {
    public var context: String
    public var dockerfile: String?
    public var args: [String: String]
    public var target: String?
    public var network: String?

    public init(context: String, dockerfile: String? = nil, args: [String: String] = [:],
                target: String? = nil, network: String? = nil) {
        self.context = context
        self.dockerfile = dockerfile
        self.args = args
        self.target = target
        self.network = network
    }
}

public struct NetworkDef: Sendable, Equatable {
    public var name: String
    public var `internal`: Bool?

    public init(name: String, internal: Bool? = nil) {
        self.name = name
        self.internal = `internal`
    }
}

public struct VolumeDef: Sendable, Equatable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}
