// InstallPathResolver.swift
// installApp() RPC の親側(オーケストレータ)パス解決。実機・プロセスに触れない純粋ロジックなので
// ここに切り出して単体テストで固める(実インストール実行は呼び出し側 [fleetest ターゲットの
// InstallHandlerFactory] が ProfileWorkerFactory.installOne を呼んで行う)。

import Foundation

/// installApp() の親側パス解決結果
public enum InstallPathResolution: Equatable, Sendable {
    /// `~` 展開・存在確認済みの絶対パスと、インストール記録(iOS の InstalledAppCheck)に使う bundleID
    case resolved(path: String, bundleID: String)
    case error(String)
}

public enum InstallPathResolver {
    /// 優先順: 明示引数(installApp("...") の path)→ 実行プロファイルの appPath(apps[platform])。
    /// どちらも無い、または platform に app 設定自体が無ければエラー。
    /// fileExists はテスト用の差し替え口(既定は実ファイルシステム)
    public static func resolve(platform: String, explicitPath: String?,
                               apps: [String: ResolvedAppTarget],
                               fileExists: (String) -> Bool = {
                                   FileManager.default.fileExists(atPath: $0)
                               }) -> InstallPathResolution {
        guard let app = apps[platform] else {
            return .error("installApp: no app is configured for platform \(platform) in the run profile")
        }
        guard let rawPath = explicitPath ?? app.appPath else {
            return .error("installApp: no package path was given and the run profile has no appPath "
                + "for platform \(platform). Pass the path explicitly: installApp(\"/path/to/App\")")
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard fileExists(expanded) else {
            return .error("installApp: package not found at \(expanded)")
        }
        return .resolved(path: expanded, bundleID: app.bundleID)
    }
}
