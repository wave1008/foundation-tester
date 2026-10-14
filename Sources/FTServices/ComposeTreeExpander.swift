// ComposeTreeExpander.swift
// 変数の展開は、正規化の**前**に ComposeValue の木へ1回だけかける(経路は1つ)。
// 読む(ComposeReader)→ 展開(ここ)→ 正規化(ComposeNormalizer)→ 検査(ComposePolicy)→ 計画(ServicePlanner)。
// 正規化後の型(ServiceSpec)に展開をかける経路は置かない —— ports のように正規化で整数になる欄の `${…}` を
// 展開できず、同じ規則が2箇所に分かれる。
struct ExpansionSession {
    let dictionaries: ExpansionDictionaries
    var errors: [ComposeRefusal] = []
    var used: Set<String> = []

    init(dictionaries: ExpansionDictionaries) {
        self.dictionaries = dictionaries
    }

    mutating func text(_ source: String, secrets: Bool, _ path: ComposePath) -> String {
        switch VariableExpansion.expand(source, dictionaries: dictionaries, allowSecrets: secrets, path: path) {
        case .success(let expanded):
            used.formUnion(expanded.usedSecrets)
            return expanded.value
        case .failure(let refusal):
            errors.append(refusal)
            return source
        }
    }
}

/// 正規化済み ServiceSpec の文字列欄を展開する。**秘密を展開できるのは environment の値だけ**。
/// 注意: ports / expose は正規化の時点で整数になっているので、ここでは `${…}` を展開できない。
/// 変数つきのポートを許すなら ComposeTreeExpander を正規化の前に通す(パイプラインの正は木の展開)。
/// 展開の結果。`usedSecretsByService` は「そのサービスの environment が実際に使った秘密の名前」
/// (setup.sh / teardown.sh へ渡す名前と、親の伏せ字登録の入力)
public struct ExpandedTree: Sendable, Equatable {
    public let value: ComposeValue
    public let usedSecretsByService: [String: Set<String>]

    public init(value: ComposeValue, usedSecretsByService: [String: Set<String>]) {
        self.value = value
        self.usedSecretsByService = usedSecretsByService
    }
}

/// 正規化の前に ComposeValue の木へ展開をかける(ports など正規化で整数になる欄の `${…}` を展開できる)。
/// 秘密は `services.<name>.environment` の値(map の値・list の要素)だけ。キーは展開しない。
/// `version` と最上位の `x-*` は無視される欄なので展開しない。
public enum ComposeTreeExpander {
    public static func expand(
        _ root: ComposeValue,
        dictionaries: ExpansionDictionaries
    ) -> Result<ExpandedTree, ComposeRefusals> {
        var session = ExpansionSession(dictionaries: dictionaries)
        var usedByService: [String: Set<String>] = [:]
        guard let top = root.mapEntries else { return .success(ExpandedTree(value: root, usedSecretsByService: [:])) }
        var entries: [ComposeMapEntry] = []
        for entry in top {
            let path = ComposePath().append(key: entry.key)
            if entry.key == "version" || entry.key.hasPrefix("x-") {
                entries.append(entry)
            } else if entry.key == "services", let services = entry.value.mapEntries {
                var out: [ComposeMapEntry] = []
                for service in services {
                    let sp = path.append(key: service.key)
                    guard let fields = service.value.mapEntries else {
                        out.append(ComposeMapEntry(key: service.key, value: walk(service.value, sp, false, &session)))
                        continue
                    }
                    var fieldOut: [ComposeMapEntry] = []
                    for field in fields {
                        let allow = field.key == "environment"
                        var local = ExpansionSession(dictionaries: dictionaries)
                        let value = walk(field.value, sp.append(key: field.key), allow, &local)
                        session.errors += local.errors
                        if allow, !local.used.isEmpty { usedByService[service.key, default: []].formUnion(local.used) }
                        fieldOut.append(ComposeMapEntry(key: field.key, value: value))
                    }
                    out.append(ComposeMapEntry(key: service.key, value: .map(fieldOut)))
                }
                entries.append(ComposeMapEntry(key: entry.key, value: .map(out)))
            } else {
                entries.append(ComposeMapEntry(key: entry.key, value: walk(entry.value, path, false, &session)))
            }
        }
        if !session.errors.isEmpty { return .failure(ComposeRefusals(session.errors)) }
        return .success(ExpandedTree(value: .map(entries), usedSecretsByService: usedByService))
    }

    private static func walk(
        _ value: ComposeValue, _ path: ComposePath, _ secrets: Bool, _ session: inout ExpansionSession
    ) -> ComposeValue {
        switch value {
        case .string(let text):
            return .string(session.text(text, secrets: secrets, path))
        case .list(let items):
            var out: [ComposeValue] = []
            for (index, item) in items.enumerated() {
                out.append(walk(item, path.append(index: index), secrets, &session))
            }
            return .list(out)
        case .map(let entries):
            var out: [ComposeMapEntry] = []
            for entry in entries {
                out.append(ComposeMapEntry(key: entry.key, value: walk(entry.value, path.append(key: entry.key), secrets, &session)))
            }
            return .map(out)
        default:
            return value
        }
    }
}
