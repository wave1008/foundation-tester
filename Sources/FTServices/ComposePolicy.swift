// compose.yaml の検査(§17「compose.yaml の検査」「ビルドとデータ投入の規則」)。純粋関数:
// ファイルシステムは読まない。パスの実体・symlink・存在は呼び手が PathFact で渡す(枠の外の親が埋める)。

public enum ServiceRuntime: String, Sendable { case docker, apple }

/// 宣言どおりの文字列 → その実体。
public struct PathFact: Sendable, Equatable {
    public var exists: Bool
    /// symlink 解決済み(/private 付きの形)。無ければ nil。
    public var realpath: String?
    /// 宣言のパス自身が symlink か(途中の要素は realpath が吸収する)。
    public var isSymlink: Bool
    public var isDirectory: Bool

    public init(exists: Bool, realpath: String?, isSymlink: Bool = false, isDirectory: Bool = false) {
        self.exists = exists
        self.realpath = realpath
        self.isSymlink = isSymlink
        self.isDirectory = isDirectory
    }
}

public enum ComposePolicy {
    public struct Context: Sendable {
        public var runtime: ServiceRuntime
        /// 実体パス。末尾の "/" は付けない。
        public var scriptsRoot: String
        public var dataRoot: String
        /// 根そのものが symlink なら起動しない。
        public var scriptsRootIsSymlink: Bool
        public var dataRootIsSymlink: Bool
        /// マシン側 `services.buildSources`(実体パス)。
        public var buildSources: [String]
        /// bind の source・build.context・build.dockerfile・env_file の宣言文字列 → 事実。
        /// dockerfile の鍵は「context + "/" + dockerfile」(dockerfile が "/" 始まりならそのまま・省略時は context + "/Dockerfile")。
        public var pathFacts: [String: PathFact]
        /// 断るホストのポート。範囲は呼び手が既存の定数から組む(ここに数字を置かない)。
        public var reservedHostPorts: [ClosedRange<Int>]

        public init(
            runtime: ServiceRuntime, scriptsRoot: String, dataRoot: String,
            scriptsRootIsSymlink: Bool = false, dataRootIsSymlink: Bool = false,
            buildSources: [String] = [], pathFacts: [String: PathFact] = [:],
            reservedHostPorts: [ClosedRange<Int>] = []
        ) {
            self.runtime = runtime
            self.scriptsRoot = scriptsRoot
            self.dataRoot = dataRoot
            self.scriptsRootIsSymlink = scriptsRootIsSymlink
            self.dataRootIsSymlink = dataRootIsSymlink
            self.buildSources = buildSources
            self.pathFacts = pathFacts
            self.reservedHostPorts = reservedHostPorts
        }
    }

    public struct Checked: Sendable, Equatable {
        public let spec: ServiceSpec
        /// 宣言の文字列 → 実体パス(通った bind の source・build.context・dockerfile・env_file)。
        public let realpaths: [String: String]

        public init(spec: ServiceSpec, realpaths: [String: String]) {
            self.spec = spec
            self.realpaths = realpaths
        }
    }

    /// TCP/UDP のポート番号の範囲(1...65535 = 16 bit の無符号整数から 0 を除く)。
    private static let validPorts = 1...65535

    public static func check(_ spec: ServiceSpec, context: Context) -> Result<Checked, ComposeRefusals> {
        var refusals: [ComposeRefusal] = []
        var realpaths: [String: String] = [:]
        let services = ComposePath("services")

        if spec.services.isEmpty {
            refusals.append(.invalidValue(path: services, reason: "at least one service is required"))
        }
        if context.scriptsRootIsSymlink || context.dataRootIsSymlink {
            refusals.append(.invalidValue(path: ComposePath("<workspace>"), reason: "scripts/ or data/ is a symlink"))
        }

        var publishedHost = Set<String>()
        for svc in spec.services {
            let base = services.append(key: svc.name)

            for (i, mount) in svc.mounts.enumerated() {
                guard case .bind(let source, _, let readOnly) = mount else { continue }
                let path = base.append(key: "volumes").append(index: i)
                var found: [ComposeRefusal] = []
                let outside = ComposeRefusal.bindSourceOutsideAllowedRoots(path: path, source: source)
                if let fact = context.pathFacts[source], fact.exists, let real = fact.realpath {
                    if fact.isSymlink {
                        found.append(.bindSourceIsSymlink(path: path, source: source))
                    } else if isUnder(real, root: context.scriptsRoot) {
                        if !readOnly { found.append(.scriptsMountMustBeReadOnly(path: path)) }
                    } else if isSame(real, context.dataRoot) {
                        // data/ の根そのものだけ書ける。
                    } else if isUnder(real, root: context.dataRoot) {
                        found.append(.bindSourceUnderWritableRoot(path: path, source: source))
                    } else {
                        found.append(outside)
                    }
                    if found.isEmpty { realpaths[source] = real }
                } else {
                    found.append(outside)
                }
                refusals += found
            }

            for (i, file) in svc.envFiles.enumerated() {
                let path = base.append(key: "env_file").append(index: i)
                if let real = context.pathFacts[file]?.realpath, isUnder(real, root: context.scriptsRoot) {
                    realpaths[file] = real
                } else {
                    refusals.append(.envFileOutsideScripts(path: path))
                }
            }

            if let build = svc.build {
                checkBuild(build, path: base.append(key: "build"), context: context,
                           refusals: &refusals, realpaths: &realpaths)
            }

            for (i, port) in svc.ports.enumerated() {
                let path = base.append(key: "ports").append(index: i)
                if port.hostIP != "127.0.0.1" { refusals.append(.hostIPNotLoopback(path: path)) }
                if !validPorts.contains(port.hostPort) {
                    refusals.append(.invalidValue(path: path, reason: "host port is out of range 1-65535"))
                }
                if !validPorts.contains(port.containerPort) {
                    refusals.append(.invalidValue(path: path, reason: "container port is out of range 1-65535"))
                }
                if context.reservedHostPorts.contains(where: { $0.contains(port.hostPort) }) {
                    refusals.append(.hostPortReserved(path: path, port: port.hostPort))
                }
                if !publishedHost.insert("\(port.proto.rawValue):\(port.hostPort)").inserted {
                    refusals.append(.invalidValue(path: path, reason: "host port is published twice"))
                }
            }

            if let hc = svc.healthcheck {
                checkHealthcheck(hc, path: base.append(key: "healthcheck"), refusals: &refusals)
            }

            if let mem = svc.memLimit, !isByteSize(mem) {
                refusals.append(.resourceLimitInvalid(path: base.append(key: "mem_limit"),
                                                      reason: "expected a byte size such as 512m or 2g"))
            }
            if let cpus = svc.cpus, !(cpus.isFinite && cpus > 0) {
                refusals.append(.resourceLimitInvalid(path: base.append(key: "cpus"),
                                                      reason: "must be a finite number greater than 0"))
            }
        }

        if refusals.isEmpty { return .success(Checked(spec: spec, realpaths: realpaths)) }
        return .failure(ComposeRefusals(refusals))
    }

    private static func checkBuild(
        _ build: BuildDef, path: ComposePath, context: Context,
        refusals: inout [ComposeRefusal], realpaths: inout [String: String]
    ) {
        let ctxPath = path.append(key: "context")
        if context.runtime == .apple && build.context.hasPrefix("/private/") {
            refusals.append(.buildContextUnderPrivate(path: ctxPath))
        }
        guard let ctxReal = context.pathFacts[build.context]?.realpath,
              ([context.scriptsRoot] + context.buildSources).contains(where: { isUnder(ctxReal, root: $0) }) else {
            refusals.append(.buildContextOutsideAllowedRoots(path: ctxPath))
            return
        }
        var found = 0
        let dfDecl = dockerfileKey(context: build.context, dockerfile: build.dockerfile)
        let dfPath = path.append(key: "dockerfile")
        if let dfReal = context.pathFacts[dfDecl]?.realpath, isUnder(dfReal, root: ctxReal) {
            realpaths[dfDecl] = dfReal
        } else {
            refusals.append(.buildDockerfileOutsideContext(path: dfPath))
            found += 1
        }
        if context.runtime == .apple && build.context.hasPrefix("/private/") { found += 1 }
        if found == 0 { realpaths[build.context] = ctxReal }
    }

    private static func checkHealthcheck(_ hc: Healthcheck, path: ComposePath, refusals: inout [ComposeRefusal]) {
        let emptyTest: Bool
        switch hc.test {
        case .cmd(let argv): emptyTest = argv.isEmpty
        case .cmdShell(let text): emptyTest = text.isEmpty
        default: emptyTest = false
        }
        if emptyTest {
            refusals.append(.healthcheckUnsupported(path: path.append(key: "test"), reason: "empty command"))
        }
        if let r = hc.retries, r < 0 {
            refusals.append(.healthcheckUnsupported(path: path.append(key: "retries"), reason: "must not be negative"))
        }
        for (key, value) in [("interval", hc.interval), ("timeout", hc.timeout), ("start_period", hc.startPeriod)] {
            if let v = value, !isDuration(v) {
                refusals.append(.healthcheckUnsupported(path: path.append(key: key),
                                                        reason: "expected a duration such as 5s, 500ms or 1m30s"))
            }
        }
    }

    // MARK: 文法・パス

    /// compose の duration: `<数>(us|ms|s|m|h)` の連結。数は小数可。
    static func isDuration(_ s: String) -> Bool {
        let chars = Array(s.utf8)
        var i = 0
        var groups = 0
        while i < chars.count {
            var digits = 0
            var dots = 0
            while i < chars.count, (chars[i] >= 48 && chars[i] <= 57) || chars[i] == 46 {
                if chars[i] == 46 { dots += 1 } else { digits += 1 }
                i += 1
            }
            if digits == 0 || dots > 1 { return false }
            let rest = chars[i...]
            if rest.starts(with: Array("us".utf8)) || rest.starts(with: Array("ms".utf8)) {
                i += 2
            } else if let c = rest.first, c == UInt8(ascii: "s") || c == UInt8(ascii: "m") || c == UInt8(ascii: "h") {
                i += 1
            } else {
                return false
            }
            groups += 1
        }
        return groups > 0
    }

    /// compose の byte 文法: 整数 + 省略可の b|k|m|g(大文字小文字不問)。
    static func isByteSize(_ s: String) -> Bool {
        var chars = Array(s.lowercased().utf8)
        if let last = chars.last, [UInt8(ascii: "b"), UInt8(ascii: "k"), UInt8(ascii: "m"), UInt8(ascii: "g")].contains(last) {
            chars.removeLast()
        }
        return !chars.isEmpty && chars.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func components(_ p: String) -> [Substring] {
        p.split(separator: "/", omittingEmptySubsequences: true)
    }

    /// `pathFacts` / `Checked.realpaths` で dockerfile を引く鍵(compose の `dockerfile` は context 基準の相対パス)。
    /// 検査と計画の両方がこの1関数で鍵を作る(別々に組むと片方だけ引けなくなる)
    public static func dockerfileKey(context: String, dockerfile: String?) -> String {
        guard let dockerfile else { return trimmedSlash(context) + "/Dockerfile" }
        return dockerfile.hasPrefix("/") ? dockerfile : trimmedSlash(context) + "/" + dockerfile
    }

    private static func trimmedSlash(_ p: String) -> String {
        var s = p
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 同一または要素境界での配下(文字列の前方一致ではない)。
    static func isUnder(_ path: String, root: String) -> Bool {
        let p = components(path), r = components(root)
        return p.count >= r.count && Array(p.prefix(r.count)) == r
    }

    static func isSame(_ a: String, _ b: String) -> Bool { components(a) == components(b) }
}
