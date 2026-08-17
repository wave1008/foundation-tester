// WorkspaceScaffold.swift
// `fileSync.workspace` 配下の規約フォルダ(apps/scripts/data)。中身は自由 —— 強制はしない。
// 無いフォルダだけを作る(ftester run/api run が ResolvedProfile.workspaceRoot を使うたび、
// RemoteRunDispatcher がミラー前に呼ぶ)。

import Foundation

public enum WorkspaceScaffold {

    /// 規約フォルダ名(順序は表示・作成の順序として使う)
    public static let directoryNames = ["apps", "scripts", "data"]

    /// root 配下に欠けている規約フォルダだけを作る(既存の中身には触らない)。
    /// 戻り値: 実際に作成したフォルダ名(ログ表示用。空 = 何もしなかった = 初回ではない)
    @discardableResult
    public static func ensure(root: URL) throws -> [String] {
        let fm = FileManager.default
        var created: [String] = []
        for name in directoryNames {
            let dir = root.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dir.path) else { continue }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            created.append(name)
        }
        return created
    }
}
