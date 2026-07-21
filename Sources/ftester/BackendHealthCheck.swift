// アプリプロファイルの healthCheckURL(バックエンド死活確認)の実行前プローブ。
// 不達でも実行はブロックしない(オフライン検証を妨げない)— 警告だけを確実に出す。
// 背景: バックエンド停止中はアプリが非同期処理の未処理例外でクラッシュし、テストが
// 「Application is not running」で全滅して原因が見えにくい(2026-07-21 実害)。

import Foundation
import FTCore

enum BackendHealthCheck {
    /// resolved の全アプリの healthCheckURL を並列プローブし、不達なら警告を log に出す。
    /// HTTP 応答があれば(4xx/5xx でも)到達とみなす(死活確認であってヘルス判定ではない)
    static func warnIfUnreachable(resolved: ResolvedProfile, log: @escaping (String) -> Void) async {
        let targets = Set(resolved.apps.values.compactMap(\.healthCheckURL))
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: (String, Bool).self) { group in
            for urlString in targets {
                group.addTask { (urlString, await reachable(urlString)) }
            }
            for await (urlString, ok) in group where !ok {
                log("⚠️ バックエンド死活確認に失敗: \(urlString) に到達できません。"
                    + "アプリがクラッシュ・シナリオが全滅する可能性があります"
                    + "(サーバの起動を確認してください。apps プロファイル healthCheckURL)")
            }
        }
    }

    private static func reachable(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}
