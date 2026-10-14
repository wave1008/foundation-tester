/// ComposeValue → ServiceSpec。許可リストを全階層で表にし、短縮形と長い形を畳む。
/// 不変条件: 拒否は最初の1件で止めず全部集める(利用者が1回で直せるように)。
/// 検査の対象は「キー・型・値の文法」まで。パスの実体・ホストのポート予約など環境に依存する検査は後段。
public enum ComposeNormalizer {
    public static func normalize(_ root: ComposeValue) -> Result<ServiceSpec, ComposeRefusals> {
        var state = State()
        let spec = state.normalizeRoot(root)
        if state.errors.isEmpty { return .success(spec) }
        return .failure(ComposeRefusals(state.errors))
    }

    static let serviceKeys: Set<String> = [
        "image", "build", "command", "entrypoint", "environment", "env_file", "ports", "expose", "volumes",
        "tmpfs", "healthcheck", "depends_on", "working_dir", "user", "networks", "labels", "platform", "init",
        "stop_grace_period", "mem_limit", "cpus",
    ]

    static let forbiddenServiceKeys: [String: String] = [
        "privileged": "gives the container full access to the host",
        "cap_add": "capabilities cannot be added",
        "cap_drop": "capabilities are managed by fleetest",
        "devices": "host devices cannot be passed through",
        "security_opt": "security options are managed by fleetest",
        "sysctls": "kernel parameters are managed by fleetest",
        "cgroup_parent": "cgroups are managed by fleetest",
        "network_mode": "networks are managed by fleetest",
        "pid": "sharing the host process namespace is not allowed",
        "ipc": "sharing the host IPC namespace is not allowed",
        "uts": "sharing the host UTS namespace is not allowed",
        "userns_mode": "user namespaces are managed by fleetest",
        "container_name": "container names are fixed by fleetest per project",
        "extra_hosts": "name resolution is managed by fleetest",
        "restart": "a container must not restart after fleetest has stopped it",
        "secrets": "compose secrets can read host files",
        "configs": "compose configs can read host files",
        "profiles": "profiles are not supported",
        "extends": "extends can read other files",
        "links": "links are not supported; use networks",
        "dns": "name resolution is managed by fleetest",
        "dns_search": "name resolution is managed by fleetest",
        "ulimits": "resource limits are managed by fleetest",
        "volumes_from": "mounts from other containers are not supported",
        "external_links": "links to containers outside the project are not allowed",
        "logging": "log drivers are managed by fleetest",
        "deploy": "swarm deployment options are not supported",
        "develop": "develop/watch is not supported",
    ]

    static let forbiddenBuildKeys: Set<String> = [
        "ssh", "secrets", "additional_contexts", "dockerfile_inline", "cache_from", "cache_to", "pull",
        "no_cache", "platforms", "privileged", "entitlements", "extra_hosts", "labels", "tags", "isolation",
        "shm_size", "ulimits",
    ]

    static let forbiddenNetworkKeys: Set<String> = [
        "driver", "driver_opts", "external", "name", "ipam", "attachable", "enable_ipv6", "labels",
    ]

    static let forbiddenVolumeKeys: Set<String> = ["driver", "driver_opts", "external", "name", "labels"]

    struct State {
        var errors: [ComposeRefusal] = []
        var networkNames: Set<String> = []
        var volumeNames: Set<String> = []

        mutating func fail(_ refusal: ComposeRefusal) { errors.append(refusal) }

        // MARK: ルート

        mutating func normalizeRoot(_ root: ComposeValue) -> ServiceSpec {
            let base = ComposePath()
            guard let top = root.mapEntries else {
                fail(.wrongType(path: base, expected: "mapping"))
                return ServiceSpec(services: [], networks: [], volumes: [], ignoredTopLevelKeys: [])
            }
            var ignored: [String] = []
            var servicesValue: ComposeValue?
            var networks: [NetworkDef] = []
            var volumes: [VolumeDef] = []
            for entry in top {
                let path = base.append(key: entry.key)
                if entry.key == "version" || entry.key.hasPrefix("x-") {
                    ignored.append(entry.key)
                    continue
                }
                switch entry.key {
                case "services": servicesValue = entry.value
                case "networks": networks = topNetworks(entry.value, path: path)
                case "volumes": volumes = topVolumes(entry.value, path: path)
                default: fail(.unknownKey(path: path))
                }
            }
            networkNames = Set(networks.map(\.name))
            volumeNames = Set(volumes.map(\.name))
            var services: [ServiceDef] = []
            let servicesPath = base.append(key: "services")
            if let servicesValue {
                if let entries = servicesValue.mapEntries {
                    for entry in entries {
                        if let service = normalizeService(name: entry.key, value: entry.value, path: servicesPath.append(key: entry.key)) {
                            services.append(service)
                        }
                    }
                } else {
                    fail(.wrongType(path: servicesPath, expected: "mapping"))
                }
            } else {
                fail(.invalidValue(path: servicesPath, reason: "required"))
            }
            checkDependencies(services)
            return ServiceSpec(services: services, networks: networks, volumes: volumes, ignoredTopLevelKeys: ignored)
        }

        mutating func topNetworks(_ value: ComposeValue, path: ComposePath) -> [NetworkDef] {
            guard let entries = value.mapEntries else {
                if value != .null { fail(.wrongType(path: path, expected: "mapping")) }
                return []
            }
            var result: [NetworkDef] = []
            for entry in entries {
                let netPath = path.append(key: entry.key)
                var def = NetworkDef(name: entry.key)
                if let options = entry.value.mapEntries {
                    for option in options {
                        let optionPath = netPath.append(key: option.key)
                        if option.key == "internal" {
                            if case .bool(let flag) = option.value {
                                if flag { def.internal = true } else {
                                    fail(.invalidValue(path: optionPath, reason: "internal: false would allow the network to reach outside; remove it"))
                                }
                            } else {
                                fail(.wrongType(path: optionPath, expected: "boolean"))
                            }
                        } else if ComposeNormalizer.forbiddenNetworkKeys.contains(option.key) {
                            fail(.forbiddenKey(path: optionPath, reason: "networks are created and named by fleetest"))
                        } else {
                            fail(.unknownKey(path: optionPath))
                        }
                    }
                } else if entry.value != .null {
                    fail(.wrongType(path: netPath, expected: "mapping or null"))
                }
                result.append(def)
            }
            return result
        }

        mutating func topVolumes(_ value: ComposeValue, path: ComposePath) -> [VolumeDef] {
            guard let entries = value.mapEntries else {
                if value != .null { fail(.wrongType(path: path, expected: "mapping")) }
                return []
            }
            var result: [VolumeDef] = []
            for entry in entries {
                let volPath = path.append(key: entry.key)
                if let options = entry.value.mapEntries {
                    for option in options {
                        let optionPath = volPath.append(key: option.key)
                        if ComposeNormalizer.forbiddenVolumeKeys.contains(option.key) {
                            fail(.forbiddenKey(path: optionPath, reason: "volumes are declared by name only; drivers and external volumes can reach host paths"))
                        } else {
                            fail(.unknownKey(path: optionPath))
                        }
                    }
                } else if entry.value != .null {
                    fail(.wrongType(path: volPath, expected: "mapping or null"))
                }
                result.append(VolumeDef(name: entry.key))
            }
            return result
        }

        // MARK: サービス

        static func validServiceName(_ name: String) -> Bool {
            guard let first = name.unicodeScalars.first else { return false }
            func alnum(_ s: Unicode.Scalar) -> Bool {
                (s >= "a" && s <= "z") || (s >= "0" && s <= "9")
            }
            guard alnum(first) else { return false }
            return name.unicodeScalars.allSatisfy { alnum($0) || $0 == "_" || $0 == "." || $0 == "-" }
        }

        mutating func normalizeService(name: String, value: ComposeValue, path: ComposePath) -> ServiceDef? {
            if !Self.validServiceName(name) {
                fail(.invalidServiceName(name: name))
                return nil
            }
            if name == "localhost" || name == "host.docker.internal" || name.hasPrefix("fleetest-") {
                fail(.reservedName(path: path, name: name))
                return nil
            }
            guard let entries = value.mapEntries else {
                fail(.wrongType(path: path, expected: "mapping"))
                return nil
            }
            var def = ServiceDef(name: name)
            for entry in entries {
                let p = path.append(key: entry.key)
                let v = entry.value
                switch entry.key {
                case "image": def.image = string(v, p)
                case "build": def.build = build(v, p)
                case "command": def.command = words(v, p)
                case "entrypoint": def.entrypoint = words(v, p)
                case "environment": def.environment = environment(v, p)
                case "env_file": def.envFiles = stringOrList(v, p)
                case "ports": def.ports = ports(v, p)
                case "expose": def.expose = expose(v, p)
                case "volumes":
                    let parsed = volumes(v, p)
                    def.mounts = parsed.mounts
                    def.tmpfs += parsed.tmpfs
                case "tmpfs": def.tmpfs += stringOrList(v, p)
                case "healthcheck": def.healthcheck = healthcheck(v, p)
                case "depends_on": def.dependsOn = dependsOn(v, p)
                case "working_dir": def.workingDir = scalarString(v, p)
                case "user": def.user = scalarString(v, p)
                case "networks": def.networks = serviceNetworks(v, p)
                case "labels": def.labels = labels(v, p)
                case "platform": def.platform = string(v, p)
                case "init": def.initProcess = bool(v, p)
                case "stop_grace_period": def.stopGracePeriod = scalarString(v, p)
                case "mem_limit": def.memLimit = scalarString(v, p)
                case "cpus": def.cpus = number(v, p)
                default:
                    if let reason = ComposeNormalizer.forbiddenServiceKeys[entry.key] {
                        fail(.forbiddenKey(path: p, reason: reason))
                    } else {
                        fail(.unknownKey(path: p))
                    }
                }
            }
            if def.image == nil && def.build == nil {
                fail(.invalidValue(path: path, reason: "either image or build is required"))
            }
            return def
        }

        // MARK: 型の取り出し

        mutating func string(_ v: ComposeValue, _ p: ComposePath) -> String? {
            if let text = v.stringValue { return text }
            fail(.wrongType(path: p, expected: "string"))
            return nil
        }

        /// 数や真偽も文字列として受ける欄(user: 1000 など)。
        mutating func scalarString(_ v: ComposeValue, _ p: ComposePath) -> String? {
            if let text = v.scalarText { return text }
            fail(.wrongType(path: p, expected: "string"))
            return nil
        }

        mutating func bool(_ v: ComposeValue, _ p: ComposePath) -> Bool? {
            if case .bool(let flag) = v { return flag }
            fail(.wrongType(path: p, expected: "boolean"))
            return nil
        }

        mutating func number(_ v: ComposeValue, _ p: ComposePath) -> Double? {
            switch v {
            case .int(let n): return Double(n)
            case .double(let n): return n
            case .string(let text):
                if let n = Double(text) { return n }
            default: break
            }
            fail(.wrongType(path: p, expected: "number"))
            return nil
        }

        mutating func integer(_ v: ComposeValue, _ p: ComposePath) -> Int? {
            if case .int(let n) = v { return n }
            if case .string(let text) = v, let n = Int(text) { return n }
            fail(.wrongType(path: p, expected: "integer"))
            return nil
        }

        mutating func stringOrList(_ v: ComposeValue, _ p: ComposePath) -> [String] {
            if let text = v.stringValue { return [text] }
            guard let items = v.listItems else {
                fail(.wrongType(path: p, expected: "string or list of strings"))
                return []
            }
            var result: [String] = []
            for (i, item) in items.enumerated() {
                if let text = item.stringValue { result.append(text) } else {
                    fail(.wrongType(path: p.append(index: i), expected: "string"))
                }
            }
            return result
        }

        /// command / entrypoint。string は空白区切り(引用符を尊重)、list はそのまま。
        mutating func words(_ v: ComposeValue, _ p: ComposePath) -> [String]? {
            if let text = v.stringValue {
                switch ComposeNormalizer.splitShellWords(text) {
                case .some(let parts): return parts
                case .none:
                    fail(.invalidValue(path: p, reason: "unterminated quote"))
                    return nil
                }
            }
            guard let items = v.listItems else {
                fail(.wrongType(path: p, expected: "string or list"))
                return nil
            }
            var result: [String] = []
            for (i, item) in items.enumerated() {
                if let text = item.scalarText { result.append(text) } else {
                    fail(.wrongType(path: p.append(index: i), expected: "string"))
                }
            }
            return result
        }

        mutating func environment(_ v: ComposeValue, _ p: ComposePath) -> [EnvEntry] {
            if let entries = v.mapEntries {
                var result: [EnvEntry] = []
                for entry in entries {
                    if entry.value == .null {
                        result.append(EnvEntry(key: entry.key, value: nil))
                    } else if let text = entry.value.scalarText {
                        result.append(EnvEntry(key: entry.key, value: text))
                    } else {
                        fail(.wrongType(path: p.append(key: entry.key), expected: "scalar or null"))
                    }
                }
                return result
            }
            guard let items = v.listItems else {
                fail(.wrongType(path: p, expected: "mapping or list"))
                return []
            }
            var result: [EnvEntry] = []
            for (i, item) in items.enumerated() {
                guard let text = item.stringValue else {
                    fail(.wrongType(path: p.append(index: i), expected: "string"))
                    continue
                }
                if let eq = text.firstIndex(of: "=") {
                    result.append(EnvEntry(key: String(text[..<eq]), value: String(text[text.index(after: eq)...])))
                } else {
                    result.append(EnvEntry(key: text, value: nil))
                }
            }
            return result
        }

        mutating func labels(_ v: ComposeValue, _ p: ComposePath) -> [String: String] {
            var pairs: [(String, String)] = []
            if let entries = v.mapEntries {
                for entry in entries {
                    if let text = entry.value.scalarText { pairs.append((entry.key, text)) } else if entry.value == .null {
                        pairs.append((entry.key, ""))
                    } else {
                        fail(.wrongType(path: p.append(key: entry.key), expected: "scalar"))
                    }
                }
            } else if let items = v.listItems {
                for (i, item) in items.enumerated() {
                    guard let text = item.stringValue else {
                        fail(.wrongType(path: p.append(index: i), expected: "string"))
                        continue
                    }
                    if let eq = text.firstIndex(of: "=") {
                        pairs.append((String(text[..<eq]), String(text[text.index(after: eq)...])))
                    } else {
                        pairs.append((text, ""))
                    }
                }
            } else {
                fail(.wrongType(path: p, expected: "mapping or list"))
                return [:]
            }
            var result: [String: String] = [:]
            for (key, value) in pairs {
                if key.hasPrefix("fleetest-") || key.hasPrefix("fleetest.") {
                    fail(.reservedName(path: p.append(key: key), name: key))
                } else {
                    result[key] = value
                }
            }
            return result
        }

        // MARK: ports / expose / volumes

        static func parsePort(_ text: String) -> Int? {
            guard let n = Int(text), n >= 1, n <= 65535 else { return nil }
            return n
        }

        mutating func ports(_ v: ComposeValue, _ p: ComposePath) -> [PortPublish] {
            guard let items = v.listItems else {
                fail(.wrongType(path: p, expected: "list"))
                return []
            }
            var result: [PortPublish] = []
            for (i, item) in items.enumerated() {
                let ip = p.append(index: i)
                switch item {
                case .string(let text):
                    if let port = shortPort(text, ip) { result.append(port) }
                case .map(let entries):
                    if let port = longPort(entries, ip) { result.append(port) }
                default:
                    fail(.wrongType(path: ip, expected: "string or mapping"))
                }
            }
            return result
        }

        mutating func shortPort(_ text: String, _ p: ComposePath) -> PortPublish? {
            var body = text
            var proto = PortPublish.Proto.tcp
            if let slash = body.lastIndex(of: "/") {
                let protoText = String(body[body.index(after: slash)...])
                switch protoText {
                case "tcp": proto = .tcp
                case "udp": proto = .udp
                default:
                    fail(.invalidValue(path: p, reason: "protocol must be tcp or udp"))
                    return nil
                }
                body = String(body[..<slash])
            }
            let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 || parts.count == 3 else {
                fail(.invalidValue(path: p, reason: "expected [host_ip:]host_port:container_port[/proto]"))
                return nil
            }
            let hostIP: String? = parts.count == 3 ? parts[0] : nil
            if let hostIP, hostIP.isEmpty {
                fail(.invalidValue(path: p, reason: "empty host_ip"))
                return nil
            }
            let hostText = parts[parts.count - 2]
            let containerText = parts[parts.count - 1]
            if hostText.contains("-") || containerText.contains("-") {
                fail(.invalidValue(path: p, reason: "port ranges are not supported; list each port"))
                return nil
            }
            guard let host = Self.parsePort(hostText), let container = Self.parsePort(containerText) else {
                fail(.invalidValue(path: p, reason: "ports must be integers from 1 to 65535 (the host port is required)"))
                return nil
            }
            return PortPublish(hostIP: hostIP, hostPort: host, containerPort: container, proto: proto)
        }

        mutating func longPort(_ entries: [ComposeMapEntry], _ p: ComposePath) -> PortPublish? {
            var target: Int?
            var published: Int?
            var hostIP: String?
            var proto = PortPublish.Proto.tcp
            var ok = true
            for entry in entries {
                let ep = p.append(key: entry.key)
                switch entry.key {
                case "target":
                    if let n = portNumber(entry.value, ep) { target = n } else { ok = false }
                case "published":
                    if let n = portNumber(entry.value, ep) { published = n } else { ok = false }
                case "host_ip":
                    if let text = string(entry.value, ep) { hostIP = text } else { ok = false }
                case "protocol":
                    switch entry.value.stringValue {
                    case "tcp": proto = .tcp
                    case "udp": proto = .udp
                    default:
                        fail(.invalidValue(path: ep, reason: "protocol must be tcp or udp"))
                        ok = false
                    }
                default:
                    fail(.unknownKey(path: ep))
                    ok = false
                }
            }
            guard ok else { return nil }
            guard let target else {
                fail(.invalidValue(path: p, reason: "target is required"))
                return nil
            }
            guard let published else {
                fail(.invalidValue(path: p, reason: "published (the host port) is required"))
                return nil
            }
            return PortPublish(hostIP: hostIP, hostPort: published, containerPort: target, proto: proto)
        }

        mutating func portNumber(_ v: ComposeValue, _ p: ComposePath) -> Int? {
            switch v {
            case .int(let n):
                if let port = Self.parsePort(String(n)) { return port }
            case .string(let text):
                if text.contains("-") {
                    fail(.invalidValue(path: p, reason: "port ranges are not supported; list each port"))
                    return nil
                }
                if let port = Self.parsePort(text) { return port }
            default:
                fail(.wrongType(path: p, expected: "integer"))
                return nil
            }
            fail(.invalidValue(path: p, reason: "ports must be integers from 1 to 65535"))
            return nil
        }

        mutating func expose(_ v: ComposeValue, _ p: ComposePath) -> [Int] {
            guard let items = v.listItems else {
                fail(.wrongType(path: p, expected: "list"))
                return []
            }
            var result: [Int] = []
            for (i, item) in items.enumerated() {
                let ip = p.append(index: i)
                if case .string(let text) = item {
                    var body = text
                    if let slash = body.firstIndex(of: "/") { body = String(body[..<slash]) }
                    if body.contains("-") {
                        fail(.invalidValue(path: ip, reason: "port ranges are not supported; list each port"))
                    } else if let port = Self.parsePort(body) { result.append(port) } else {
                        fail(.invalidValue(path: ip, reason: "ports must be integers from 1 to 65535"))
                    }
                } else if let port = portNumber(item, ip) {
                    result.append(port)
                }
            }
            return result
        }

        mutating func volumes(_ v: ComposeValue, _ p: ComposePath) -> (mounts: [MountDecl], tmpfs: [String]) {
            guard let items = v.listItems else {
                fail(.wrongType(path: p, expected: "list"))
                return ([], [])
            }
            var mounts: [MountDecl] = []
            var tmpfs: [String] = []
            for (i, item) in items.enumerated() {
                let ip = p.append(index: i)
                switch item {
                case .string(let text):
                    if let mount = shortMount(text, ip) { mounts.append(mount) }
                case .map(let entries):
                    switch longMount(entries, ip) {
                    case .mount(let mount): mounts.append(mount)
                    case .tmpfs(let target): tmpfs.append(target)
                    case .failed: break
                    }
                default:
                    fail(.wrongType(path: ip, expected: "string or mapping"))
                }
            }
            return (mounts, tmpfs)
        }

        mutating func makeMount(source: String, target: String, readOnly: Bool, isBind: Bool, _ p: ComposePath) -> MountDecl? {
            if isBind { return .bind(source: source, target: target, readOnly: readOnly) }
            if !volumeNames.contains(source) {
                fail(.undeclaredVolume(path: p, name: source))
                return nil
            }
            return .volume(name: source, target: target, readOnly: readOnly)
        }

        mutating func shortMount(_ text: String, _ p: ComposePath) -> MountDecl? {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 || parts.count == 3 else {
                fail(.invalidValue(path: p, reason: "expected source:target[:ro|rw] (anonymous volumes are not supported)"))
                return nil
            }
            var readOnly = false
            if parts.count == 3 {
                switch parts[2] {
                case "ro": readOnly = true
                case "rw": readOnly = false
                default:
                    fail(.invalidValue(path: p, reason: "mount mode must be ro or rw"))
                    return nil
                }
            }
            let source = parts[0]
            guard !source.isEmpty, !parts[1].isEmpty else {
                fail(.invalidValue(path: p, reason: "source and target must not be empty"))
                return nil
            }
            let isBind = source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~")
            return makeMount(source: source, target: parts[1], readOnly: readOnly, isBind: isBind, p)
        }

        enum LongMount {
            case mount(MountDecl)
            case tmpfs(String)
            case failed
        }

        mutating func longMount(_ entries: [ComposeMapEntry], _ p: ComposePath) -> LongMount {
            var type: String?
            var source: String?
            var target: String?
            var readOnly = false
            var ok = true
            for entry in entries {
                let ep = p.append(key: entry.key)
                switch entry.key {
                case "type": if let t = string(entry.value, ep) { type = t } else { ok = false }
                case "source": if let t = string(entry.value, ep) { source = t } else { ok = false }
                case "target": if let t = string(entry.value, ep) { target = t } else { ok = false }
                case "read_only": if let b = bool(entry.value, ep) { readOnly = b } else { ok = false }
                default:
                    fail(.unknownKey(path: ep))
                    ok = false
                }
            }
            guard ok else { return .failed }
            guard let target, !target.isEmpty else {
                fail(.invalidValue(path: p, reason: "target is required"))
                return .failed
            }
            switch type {
            case "tmpfs": return .tmpfs(target)
            case "bind", "volume":
                guard let source, !source.isEmpty else {
                    fail(.invalidValue(path: p, reason: "source is required"))
                    return .failed
                }
                if let mount = makeMount(source: source, target: target, readOnly: readOnly, isBind: type == "bind", p) {
                    return .mount(mount)
                }
                return .failed
            case .some(let other):
                fail(.forbiddenKey(path: p.append(key: "type"), reason: "mount type '\(other)' is not supported; use bind, volume or tmpfs"))
                return .failed
            case .none:
                fail(.invalidValue(path: p, reason: "type is required"))
                return .failed
            }
        }

        // MARK: healthcheck / depends_on / build / networks

        mutating func healthcheck(_ v: ComposeValue, _ p: ComposePath) -> Healthcheck? {
            guard let entries = v.mapEntries else {
                fail(.wrongType(path: p, expected: "mapping"))
                return nil
            }
            var check = Healthcheck(test: .none)
            var haveTest = false
            for entry in entries {
                let ep = p.append(key: entry.key)
                switch entry.key {
                case "test":
                    haveTest = true
                    if let test = healthcheckTest(entry.value, ep) { check.test = test }
                case "interval": check.interval = scalarString(entry.value, ep)
                case "timeout": check.timeout = scalarString(entry.value, ep)
                case "start_period": check.startPeriod = scalarString(entry.value, ep)
                case "retries": check.retries = integer(entry.value, ep)
                case "disable": if let b = bool(entry.value, ep) { check.disable = b }
                default: fail(.unknownKey(path: ep))
                }
            }
            if !haveTest && !check.disable {
                fail(.invalidValue(path: p, reason: "test is required"))
            }
            return check
        }

        mutating func healthcheckTest(_ v: ComposeValue, _ p: ComposePath) -> Healthcheck.Test? {
            if let text = v.stringValue { return .cmdShell(text) }
            guard let items = v.listItems else {
                fail(.wrongType(path: p, expected: "string or list"))
                return nil
            }
            let words = items.compactMap(\.stringValue)
            guard words.count == items.count, let head = words.first else {
                fail(.invalidValue(path: p, reason: "expected a non-empty list of strings starting with CMD, CMD-SHELL or NONE"))
                return nil
            }
            switch head {
            case "CMD": return .cmd(Array(words.dropFirst()))
            case "CMD-SHELL": return .cmdShell(words.dropFirst().joined(separator: " "))
            case "NONE": return Healthcheck.Test.none
            default:
                fail(.invalidValue(path: p.append(index: 0), reason: "the first element must be CMD, CMD-SHELL or NONE"))
                return nil
            }
        }

        mutating func dependsOn(_ v: ComposeValue, _ p: ComposePath) -> [Dependency] {
            if let items = v.listItems {
                var result: [Dependency] = []
                for (i, item) in items.enumerated() {
                    if let name = item.stringValue {
                        result.append(Dependency(service: name, condition: .serviceStarted))
                    } else {
                        fail(.wrongType(path: p.append(index: i), expected: "string"))
                    }
                }
                return result
            }
            guard let entries = v.mapEntries else {
                fail(.wrongType(path: p, expected: "list or mapping"))
                return []
            }
            var result: [Dependency] = []
            for entry in entries {
                let ep = p.append(key: entry.key)
                var condition = Dependency.Condition.serviceStarted
                if let options = entry.value.mapEntries {
                    for option in options {
                        let op = ep.append(key: option.key)
                        if option.key == "condition" {
                            if let text = option.value.stringValue, let c = Dependency.Condition(rawValue: text) {
                                condition = c
                            } else {
                                fail(.invalidValue(path: op, reason: "condition must be service_started, service_healthy or service_completed_successfully"))
                            }
                        } else {
                            fail(.unknownKey(path: op))
                        }
                    }
                } else if entry.value != .null {
                    fail(.wrongType(path: ep, expected: "mapping"))
                }
                result.append(Dependency(service: entry.key, condition: condition))
            }
            return result
        }

        mutating func build(_ v: ComposeValue, _ p: ComposePath) -> BuildDef? {
            if let text = v.stringValue { return BuildDef(context: text) }
            guard let entries = v.mapEntries else {
                fail(.wrongType(path: p, expected: "string or mapping"))
                return nil
            }
            var def = BuildDef(context: "")
            var haveContext = false
            for entry in entries {
                let ep = p.append(key: entry.key)
                switch entry.key {
                case "context":
                    if let text = string(entry.value, ep) {
                        def.context = text
                        haveContext = true
                    }
                case "dockerfile": def.dockerfile = string(entry.value, ep)
                case "target": def.target = string(entry.value, ep)
                case "args": def.args = buildArgs(entry.value, ep)
                case "network":
                    if let text = string(entry.value, ep) {
                        if text == "none" { def.network = text } else {
                            fail(.forbiddenKey(path: ep, reason: "only network: none is allowed for builds"))
                        }
                    }
                default:
                    if ComposeNormalizer.forbiddenBuildKeys.contains(entry.key) {
                        fail(.forbiddenKey(path: ep, reason: "this build option can reach host files, credentials or the network"))
                    } else {
                        fail(.unknownKey(path: ep))
                    }
                }
            }
            if !haveContext { fail(.invalidValue(path: p, reason: "context is required")) }
            return def
        }

        mutating func buildArgs(_ v: ComposeValue, _ p: ComposePath) -> [String: String] {
            var result: [String: String] = [:]
            if let entries = v.mapEntries {
                for entry in entries {
                    if let text = entry.value.scalarText { result[entry.key] = text } else {
                        fail(.invalidValue(path: p.append(key: entry.key), reason: "a build argument needs a value"))
                    }
                }
            } else if let items = v.listItems {
                for (i, item) in items.enumerated() {
                    let ip = p.append(index: i)
                    guard let text = item.stringValue, let eq = text.firstIndex(of: "=") else {
                        fail(.invalidValue(path: ip, reason: "expected KEY=VALUE"))
                        continue
                    }
                    result[String(text[..<eq])] = String(text[text.index(after: eq)...])
                }
            } else {
                fail(.wrongType(path: p, expected: "mapping or list"))
            }
            return result
        }

        mutating func serviceNetworks(_ v: ComposeValue, _ p: ComposePath) -> [String] {
            var names: [(String, ComposePath)] = []
            if let items = v.listItems {
                for (i, item) in items.enumerated() {
                    if let name = item.stringValue { names.append((name, p.append(index: i))) } else {
                        fail(.wrongType(path: p.append(index: i), expected: "string"))
                    }
                }
            } else if let entries = v.mapEntries {
                for entry in entries {
                    let ep = p.append(key: entry.key)
                    if let options = entry.value.mapEntries {
                        for option in options {
                            fail(.forbiddenKey(path: ep.append(key: option.key), reason: "per-network options (aliases, addresses) are not supported"))
                        }
                    } else if entry.value != .null {
                        fail(.wrongType(path: ep, expected: "mapping or null"))
                    }
                    names.append((entry.key, ep))
                }
            } else {
                fail(.wrongType(path: p, expected: "list or mapping"))
                return []
            }
            var result: [String] = []
            for (name, np) in names {
                if networkNames.contains(name) { result.append(name) } else {
                    fail(.undeclaredNetwork(path: np, name: name))
                }
            }
            return result
        }

        // MARK: サービス間

        mutating func checkDependencies(_ services: [ServiceDef]) {
            let known = Set(services.map(\.name))
            for service in services {
                for (i, dep) in service.dependsOn.enumerated() where !known.contains(dep.service) {
                    let path = ComposePath().append(key: "services").append(key: service.name)
                        .append(key: "depends_on").append(index: i)
                    fail(.unknownService(path: path, name: dep.service))
                }
            }
            let edges = Dictionary(services.map { service in
                (service.name, service.dependsOn.map(\.service).filter { known.contains($0) })
            }, uniquingKeysWith: { first, _ in first })
            var done = Set<String>()
            var stack: [String] = []
            func visit(_ name: String) -> [String]? {
                if let at = stack.firstIndex(of: name) { return Array(stack[at...]) + [name] }
                if done.contains(name) { return nil }
                stack.append(name)
                for next in edges[name] ?? [] {
                    if let cycle = visit(next) { return cycle }
                }
                stack.removeLast()
                done.insert(name)
                return nil
            }
            for service in services {
                if let cycle = visit(service.name) {
                    fail(.dependencyCycle(services: cycle))
                    return
                }
            }
        }
    }

    /// 空白区切りの簡易 shlex(単引用符は文字どおり・二重引用符内は `\"` と `\\` のみエスケープ・
    /// 引用符の外では `\` が次の1文字を文字にする)。閉じていない引用符は nil。
    static func splitShellWords(_ text: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for ch in text {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if q == "\"" && ch == "\\" {
                    escaped = true
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                inWord = true
            } else if ch == "\\" {
                escaped = true
                inWord = true
            } else if ch == " " || ch == "\t" || ch == "\n" {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            } else {
                current.append(ch)
                inWord = true
            }
        }
        if quote != nil || escaped { return nil }
        if inWord { words.append(current) }
        return words
    }
}
