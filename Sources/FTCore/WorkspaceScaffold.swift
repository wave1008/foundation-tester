// WorkspaceScaffold.swift
// `remoteControl.workspace` 配下の規約フォルダ(apps/scripts/data)。中身は自由 —— 強制はしない。
// 無いフォルダだけを作る(ftester run/api run が ResolvedProfile.workspaceRoot を使うたび、
// RemoteRunDispatcher がミラー前に呼ぶ)。

import Foundation

public enum WorkspaceScaffold {

    /// 既定ワークスペースのフォルダ名(プロジェクト直下。`remoteControl.workspace` 未宣言時の
    /// 置き場所)。ProfileResolver.resolveWorkspaceRoot と ProjectScaffold/project sync が共有する
    public static let defaultRootName = "workspace"

    /// 規約フォルダ名(順序は表示・作成の順序として使う)
    public static let directoryNames = ["apps", "scripts", "data"]

    /// プロジェクト直下の既定ワークスペースに規約フォルダを揃える(create/sync 用。
    /// 宣言されたワークスペースは run 時の ensure が受け持つ —— 宣言は実行プロファイルの
    /// 属性で、プロジェクト作成時点では存在しない)
    @discardableResult
    public static func ensureDefault(projectRoot: URL) throws -> [String] {
        try ensure(root: projectRoot.appendingPathComponent(defaultRootName))
    }

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
