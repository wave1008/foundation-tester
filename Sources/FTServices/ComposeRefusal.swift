/// compose.yaml を断る理由。解釈(Reader)・正規化(Normalizer)・展開(Expansion)と、
/// 後続の検査・計画が同じ enum を使う(case を足すのはここだけ)。
public enum ComposeRefusal: Error, Sendable, Equatable {
    case documentTooLarge(bytes: Int, limit: Int)
    case tooManyNodes(limit: Int)
    case tooDeep(limit: Int)
    case malformedYAML(message: String)
    case duplicateKey(path: ComposePath)
    case unsupportedMergeKey(path: ComposePath)
    case nonStringKey(path: ComposePath)
    case unknownKey(path: ComposePath)
    case forbiddenKey(path: ComposePath, reason: String)
    case wrongType(path: ComposePath, expected: String)
    case invalidValue(path: ComposePath, reason: String)
    case invalidServiceName(name: String)
    case reservedName(path: ComposePath, name: String)
    case unknownService(path: ComposePath, name: String)
    case dependencyCycle(services: [String])
    case undeclaredVolume(path: ComposePath, name: String)
    case undeclaredNetwork(path: ComposePath, name: String)
    case envFileOutsideScripts(path: ComposePath)
    case secretInForbiddenField(path: ComposePath, name: String)
    case secretReferencedFromDotEnv(name: String)
    case unsetVariable(path: ComposePath, name: String)
    case badSubstitution(path: ComposePath, detail: String)
    case bindSourceOutsideAllowedRoots(path: ComposePath, source: String)
    case bindSourceUnderWritableRoot(path: ComposePath, source: String)
    case bindSourceIsSymlink(path: ComposePath, source: String)
    case scriptsMountMustBeReadOnly(path: ComposePath)
    case hostIPNotLoopback(path: ComposePath)
    case hostPortReserved(path: ComposePath, port: Int)
    case buildContextOutsideAllowedRoots(path: ComposePath)
    case buildDockerfileOutsideContext(path: ComposePath)
    case buildContextUnderPrivate(path: ComposePath)
    case healthcheckUnsupported(path: ComposePath, reason: String)
    case resourceLimitInvalid(path: ComposePath, reason: String)

    /// 利用者が読む英語1文。
    public var message: String {
        switch self {
        case .documentTooLarge(let bytes, let limit):
            return "compose file is too large: \(bytes) bytes (limit \(limit) bytes)"
        case .tooManyNodes(let limit):
            return "compose file has too many nodes after expanding aliases (limit \(limit))"
        case .tooDeep(let limit):
            return "compose file is nested too deeply (limit \(limit) levels)"
        case .malformedYAML(let message):
            return "compose file is not valid YAML: \(message)"
        case .duplicateKey(let path):
            return "\(path): duplicate key"
        case .unsupportedMergeKey(let path):
            return "\(path): the YAML merge key '<<' is not supported"
        case .nonStringKey(let path):
            return "\(path): mapping keys must be strings"
        case .unknownKey(let path):
            return "\(path): unknown key (not on the list of supported compose keys)"
        case .forbiddenKey(let path, let reason):
            return "\(path): not allowed (\(reason))"
        case .wrongType(let path, let expected):
            return "\(path): wrong type, expected \(expected)"
        case .invalidValue(let path, let reason):
            return "\(path): invalid value (\(reason))"
        case .invalidServiceName(let name):
            return "services.\(name): invalid service name (must match [a-z0-9][a-z0-9_.-]*)"
        case .reservedName(let path, let name):
            return "\(path): the name '\(name)' is reserved by fleetest"
        case .unknownService(let path, let name):
            return "\(path): refers to the service '\(name)', which is not defined"
        case .dependencyCycle(let services):
            return "depends_on forms a cycle: " + services.joined(separator: " -> ")
        case .undeclaredVolume(let path, let name):
            return "\(path): the volume '\(name)' is not declared in the top-level volumes"
        case .undeclaredNetwork(let path, let name):
            return "\(path): the network '\(name)' is not declared in the top-level networks"
        case .envFileOutsideScripts(let path):
            return "\(path): env_file must be inside the scripts directory"
        case .secretInForbiddenField(let path, let name):
            return "\(path): the secret '\(name)' can only be expanded in a service's environment values"
        case .secretReferencedFromDotEnv(let name):
            return "the secret '\(name)' cannot be referenced from a .env file"
        case .unsetVariable(let path, let name):
            return "\(path): the variable '\(name)' is not set (define it in the secrets or in scripts/.env, or give a default with ${\(name):-default})"
        case .badSubstitution(let path, let detail):
            return "\(path): invalid variable substitution (\(detail))"
        case .bindSourceOutsideAllowedRoots(let path, let source):
            return "\(path): bind mount source '\(source)' must be inside the scripts or data directory"
        case .bindSourceUnderWritableRoot(let path, let source):
            return "\(path): bind mount source '\(source)' is below a writable directory; mount the data directory itself instead"
        case .bindSourceIsSymlink(let path, let source):
            return "\(path): bind mount source '\(source)' is a symbolic link"
        case .scriptsMountMustBeReadOnly(let path):
            return "\(path): mounts of the scripts directory must be read-only (add :ro)"
        case .hostIPNotLoopback(let path):
            return "\(path): host_ip must be 127.0.0.1 (LAN publishing is decided by the machine settings, not by compose.yaml)"
        case .hostPortReserved(let path, let port):
            return "\(path): host port \(port) is reserved by fleetest"
        case .buildContextOutsideAllowedRoots(let path):
            return "\(path): build context must be inside the scripts directory or a build source named in the machine settings"
        case .buildDockerfileOutsideContext(let path):
            return "\(path): dockerfile must be inside the build context"
        case .buildContextUnderPrivate(let path):
            return "\(path): build context must not be inside a directory the scenario can write"
        case .healthcheckUnsupported(let path, let reason):
            return "\(path): unsupported healthcheck (\(reason))"
        case .resourceLimitInvalid(let path, let reason):
            return "\(path): invalid resource limit (\(reason))"
        }
    }
}

/// 複数の拒否をまとめて返す箱(`[ComposeRefusal]` は `Error` に適合しないので `Result` の失敗型に使えない)。
/// 配列として読めるようにしてある(数える・含むか見る・順に出す)
public struct ComposeRefusals: Error, Sendable, Equatable, RandomAccessCollection {
    public let items: [ComposeRefusal]
    public init(_ items: [ComposeRefusal]) { self.items = items }
    public var startIndex: Int { items.startIndex }
    public var endIndex: Int { items.endIndex }
    public subscript(position: Int) -> ComposeRefusal { items[position] }
    public func index(after i: Int) -> Int { items.index(after: i) }
    public func index(before i: Int) -> Int { items.index(before: i) }
}
