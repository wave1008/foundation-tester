// ScenarioSelection.swift
// `fleetest run <id>...` / MCP `ft_run_scenario`/`ft_dry_run` が共有するクラス名展開ロジック。
// @Deleted(論理削除)/ @Draft(実装中)は全件実行・クラス名展開から除外(完全一致の明示指定のみ
// 実行可。実装しながら個別に回す運用のため)。

import Foundation

public enum ScenarioSelection {
    /// `scenariosDir` は「見つからない」を `_disabled`(コンパイル対象外)在住と見分けるための
    /// 追加情報。省略した呼び出し元(profile/fleet 経由)は従来文のまま
    public static func resolve(_ ids: [String], from all: [ScenarioInfo],
                               scenariosDir: URL? = nil) throws -> [ScenarioInfo] {
        guard !ids.isEmpty else { return all.filter { !$0.deleted && !$0.draft } }
        var result: [ScenarioInfo] = []
        for id in ids {
            if let exact = all.first(where: { $0.id == id }) {
                result.append(exact)
                continue
            }
            let classMatches = all.filter { $0.id.hasPrefix(id + ".") && !$0.deleted && !$0.draft }
            guard !classMatches.isEmpty else {
                if all.contains(where: { $0.id.hasPrefix(id + ".") }) {
                    let allDeleted = all.filter { $0.id.hasPrefix(id + ".") }.allSatisfy(\.deleted)
                    throw ScenarioSelectionError.allDeletedOrDraft(id: id, allDeleted: allDeleted)
                }
                if let scenariosDir {
                    throw ScenarioSelectionError.notFoundInScenariosDir(
                        id: id, available: all.map(\.id), scenariosDir: scenariosDir)
                }
                throw ScenarioSelectionError.notFound(id: id, available: all.map(\.id))
            }
            result.append(contentsOf: classMatches)
        }
        return result
    }
}

public enum ScenarioSelectionError: Error, LocalizedError, CustomStringConvertible {
    case allDeletedOrDraft(id: String, allDeleted: Bool)
    case notFoundInScenariosDir(id: String, available: [String], scenariosDir: URL)
    case notFound(id: String, available: [String])

    public var errorDescription: String? {
        switch self {
        case .allDeletedOrDraft(let id, let allDeleted):
            let reason = allDeleted
                ? "is deleted (@Deleted)"
                : "is deleted (@Deleted) or a draft (@Draft)"
            return "every scenario of \(id) \(reason)"
                + " (an exact Class.method reference still runs it)"
        case .notFoundInScenariosDir(let id, let available, let scenariosDir):
            return ScenarioFolders.notFoundMessage(id: id, available: available, scenariosDir: scenariosDir)
        case .notFound(let id, let available):
            return "scenario not found: \(id) (available: \(available.joined(separator: ", ")))"
        }
    }

    public var description: String { errorDescription ?? "" }
}
