// サービスの控え(docs/remote-runner.md §17「片付けの保証」)。純粋: 読み書きと生存確認は呼び手。
// 値は書かない: 秘密は名前だけ(`secretNames`)。

import FTCore
import Foundation

public struct ServicesLease: Codable, Sendable, Equatable {
    public struct PublishedPort: Codable, Sendable, Equatable {
        public var hostIP: String
        public var hostPort: Int
        public var proto: String
        public var service: String
        public init(hostIP: String, hostPort: Int, proto: String, service: String) {
            self.hostIP = hostIP
            self.hostPort = hostPort
            self.proto = proto
            self.service = service
        }
    }

    public struct AdbReverseEntry: Codable, Sendable, Equatable {
        public var serial: String
        public var hostPort: Int
        public init(serial: String, hostPort: Int) {
            self.serial = serial
            self.hostPort = hostPort
        }
    }

    /// 開始時刻つき(pid の再利用で別のプロセスを殺さないため)。スクリプトの子孫の回収に使う。
    public struct ChildProcess: Codable, Sendable, Equatable {
        public var pid: Int32
        public var startedAt: String
        public init(pid: Int32, startedAt: String) {
            self.pid = pid
            self.startedAt = startedAt
        }
    }

    public enum Phase: String, Codable, Sendable, Equatable {
        case starting, running, tearingDown
    }

    /// 誰が握っているか。`run` = run の親プロセス(終わると自分で片付ける)、`owner` = `fleetest services up` が起こした
    /// 常駐の所有者(`services down` か run の引き取りの SIGTERM で片付ける)。生存判定はどちらも pid で同じ。
    public enum Kind: String, Codable, Sendable, Equatable {
        case run, owner
    }

    /// 欄を変えたら +1。読み替えは置かない(読めない控えは「不明」として残す)。
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var pid: Int32
    /// ISO8601(秒精度)。
    public var pidStartedAt: String
    public var kind: Kind
    public var runtime: String
    /// docker の unix ソケットの実体パス、または "apple"。
    public var endpoint: String
    public var prefix: String
    public var generation: String
    public var workspace: String
    public var project: String
    public var profile: String
    public var approvedServices: [String]
    /// 名前 → ランタイムの ID。
    public var containers: [String: String]
    public var networks: [String: String]
    public var relay: String?
    public var udpCheck: String?
    public var publishedPorts: [PublishedPort]
    public var adbReverse: [AdbReverseEntry]
    public var secretNames: [String]
    public var childProcesses: [ChildProcess]
    /// コンテナ名 → 宣言した `stop_grace_period`(秒)。無いコンテナは片付け側の既定。控えからの回収(孤児・引き取り・down)が
    /// 宣言を読み直さずに同じ猶予で止めるために持つ。
    public var stopGraceSeconds: [String: Int]
    public var phase: Phase

    public init(
        schemaVersion: Int = ServicesLease.currentSchemaVersion, pid: Int32, pidStartedAt: String, kind: Kind,
        runtime: String, endpoint: String, prefix: String, generation: String, workspace: String,
        project: String, profile: String, approvedServices: [String] = [],
        containers: [String: String] = [:], networks: [String: String] = [:], relay: String? = nil,
        udpCheck: String? = nil, publishedPorts: [PublishedPort] = [], adbReverse: [AdbReverseEntry] = [],
        secretNames: [String] = [], childProcesses: [ChildProcess] = [], stopGraceSeconds: [String: Int] = [:],
        phase: Phase = .starting
    ) {
        self.schemaVersion = schemaVersion
        self.pid = pid
        self.pidStartedAt = pidStartedAt
        self.kind = kind
        self.runtime = runtime
        self.endpoint = endpoint
        self.prefix = prefix
        self.generation = generation
        self.workspace = workspace
        self.project = project
        self.profile = profile
        self.approvedServices = approvedServices
        self.containers = containers
        self.networks = networks
        self.relay = relay
        self.udpCheck = udpCheck
        self.publishedPorts = publishedPorts
        self.adbReverse = adbReverse
        self.secretNames = secretNames
        self.childProcesses = childProcesses
        self.stopGraceSeconds = stopGraceSeconds
        self.phase = phase
    }

    /// 文言用: 誰が握っているか(run と `services up` で利用者の対処が違う)。
    public var holderDescription: String {
        switch kind {
        case .run: return "run pid \(pid)"
        case .owner: return "`fleetest services up` (pid \(pid))"
        }
    }
}

public enum ServicesLeaseFile {
    private static let separator: Character = "~"
    private static let suffix = ".json"

    /// "<pid>~<prefix>.json"。
    public static func fileName(pid: Int32, prefix: String) -> String {
        "\(pid)\(separator)\(prefix)\(suffix)"
    }

    /// 旧形式 "<pid>.json"(`RunHookLease` の控え)は nil = 同じ置き場に同居しても取り違えない。
    public static func parse(fileName: String) -> (pid: Int32, prefix: String)? {
        guard fileName.hasSuffix(suffix) else { return nil }
        let stem = fileName.dropLast(suffix.count)
        guard let cut = stem.firstIndex(of: separator) else { return nil }
        let prefix = stem[stem.index(after: cut)...]
        guard let pid = Int32(stem[..<cut]), pid > 0, !prefix.isEmpty else { return nil }
        return (pid, String(prefix))
    }

    /// `RunHookLease.directory` と同じ置き場(= .fleetest/hooks)。
    public static func directory(stateDir: URL) -> URL {
        RunHookLease.directory(stateDir: stateDir)
    }

    public static func encode(_ lease: ServicesLease) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(lease) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ raw: String) -> ServicesLease? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ServicesLease.self, from: data)
    }

    /// pid と開始時刻の両方で判定する(pid の再利用で別のプロセスを「生きている」と見ない)。
    /// `isAlive(pid, pidStartedAt)` は呼び手が `ProcessLiveness.isAliveAndNotStartedAfter` で作る。
    public static func isOrphan(_ lease: ServicesLease, isAlive: (Int32, String) -> Bool) -> Bool {
        guard lease.pid > 0 else { return true }
        return !isAlive(lease.pid, lease.pidStartedAt)
    }
}
