import Yams

/// YAML 文字列 → `ComposeValue`。Yams の `load` は使わない(型と順序とエイリアスの数え方を自前で決める)。
/// 不変条件: 重複キー・`<<`・文字列以外のキーはここで断る(後段は「キーは一意な文字列」を前提にしてよい)。
public enum ComposeReader {
    public static func read(
        yaml: String,
        limits: ComposeLimits = .standard
    ) -> Result<ComposeValue, ComposeRefusal> {
        let bytes = yaml.utf8.count
        if bytes > limits.maxBytes {
            return .failure(.documentTooLarge(bytes: bytes, limit: limits.maxBytes))
        }
        let node: Node?
        do {
            node = try Yams.compose(yaml: yaml)
        } catch let YamlError.duplicatedKeysInMapping(duplicates, _) {
            // 重複キーは Yams が構文解析の段階で断る(自前の検出には届かない)。Yams はキーと位置しか持たないので、
            // path は親を欠いたキー名だけになる
            let key = duplicates.keys.compactMap(\.string).sorted().first ?? "?"
            return .failure(.duplicateKey(path: ComposePath(key)))
        } catch {
            return .failure(.malformedYAML(message: String(describing: error)))
        }
        guard let node else { return .success(.null) }
        var converter = Converter(limits: limits)
        do {
            return .success(try converter.convert(node, path: ComposePath(), depth: 1))
        } catch let refusal as ComposeRefusal {
            return .failure(refusal)
        } catch {
            return .failure(.malformedYAML(message: String(describing: error)))
        }
    }

    private struct Converter {
        let limits: ComposeLimits
        /// エイリアスは同じ Node への参照として返る。展開した後の数を数えるので、走査のたびに加算する。
        var nodeCount = 0

        init(limits: ComposeLimits) {
            self.limits = limits
        }

        mutating func tick(depth: Int) throws {
            nodeCount += 1
            if nodeCount > limits.maxNodes { throw ComposeRefusal.tooManyNodes(limit: limits.maxNodes) }
            if depth > limits.maxDepth { throw ComposeRefusal.tooDeep(limit: limits.maxDepth) }
        }

        mutating func convert(_ node: Node, path: ComposePath, depth: Int) throws -> ComposeValue {
            try tick(depth: depth)
            switch node {
            case .scalar(let scalar):
                return Self.scalarValue(node, scalar: scalar)
            case .sequence(let sequence):
                var items: [ComposeValue] = []
                var index = 0
                for item in sequence {
                    items.append(try convert(item, path: path.append(index: index), depth: depth + 1))
                    index += 1
                }
                return .list(items)
            case .mapping(let mapping):
                var entries: [ComposeMapEntry] = []
                for pair in mapping {
                    try tick(depth: depth + 1)
                    let key = try Self.keyText(pair.key, path: path)
                    let keyPath = path.append(key: key)
                    entries.append(ComposeMapEntry(
                        key: key, value: try convert(pair.value, path: keyPath, depth: depth + 1)))
                }
                return .map(entries)
            default:
                throw ComposeRefusal.malformedYAML(message: "unresolved alias")
            }
        }

        static func keyText(_ node: Node, path: ComposePath) throws -> String {
            guard case .scalar(let scalar) = node else { throw ComposeRefusal.nonStringKey(path: path) }
            let isPlain = scalar.style == .plain || scalar.style == .any
            if isPlain {
                if scalar.string == "<<" { throw ComposeRefusal.unsupportedMergeKey(path: path) }
                if Resolver.default.resolveTag(of: node) != .str {
                    throw ComposeRefusal.nonStringKey(path: path.append(key: scalar.string))
                }
            }
            return scalar.string
        }

        /// 引用符つき・ブロックスカラーは常に文字列(`"8080"` は string のまま)。
        static func scalarValue(_ node: Node, scalar: Node.Scalar) -> ComposeValue {
            guard scalar.style == .plain || scalar.style == .any else { return .string(scalar.string) }
            let name = Resolver.default.resolveTag(of: node)
            if name == .null { return .null }
            if name == .bool, let flag = node.bool { return .bool(flag) }
            if name == .int, let number = node.int { return .int(number) }
            if name == .float, let number = node.float { return .double(number) }
            return .string(scalar.string)
        }
    }
}
