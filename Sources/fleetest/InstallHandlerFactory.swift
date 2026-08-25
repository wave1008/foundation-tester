// InstallHandlerFactory.swift
// installApp() の RPC ハンドラ(RunOrchestrator.installHandler へ注入)を組み立てる。
// ProfileRunner(fleetest run --profile)と ApiRunCommand(fleetest api run --profile 並列経路)が共用する
// (ロジックを複製しない): パス解決は FTCore.InstallPathResolver、実インストールは
// FTAndroid.ProfileWorkerFactory.installOne で一本化されている。

import FTAndroid
import FTCore

enum InstallHandlerFactory {
    static func make(apps: [String: ResolvedAppTarget])
        -> @Sendable (RunWorker, String?) async -> (ok: Bool, message: String) {
        { worker, explicitPath in
            switch InstallPathResolver.resolve(platform: worker.platform,
                                               explicitPath: explicitPath, apps: apps) {
            case .error(let message):
                return (false, message)
            case .resolved(let path, let bundleID):
                do {
                    try await ProfileWorkerFactory.installOne(
                        worker: worker, bundleID: bundleID, appPath: path)
                } catch {
                    return (false, "installApp: \(error.localizedDescription)")
                }
                // in-app/hybrid は simctl install でアプリ内常駐ブリッジが道連れに終了するが、
                // 次の launchApp()(InAppDriver.launch)が simctl 再起動+dylib 再注入で必ず張り直す
                // (installIfNeeded が inapp/hybrid をスキップするのと対照的に、installApp() は
                // 利用者の明示要求なので普通にインストールし、注記だけ返す)
                if worker.platform == "ios", let engine = worker.connection.engine,
                   engine == "inapp" || engine == "hybrid" {
                    return (true, "the in-app bridge will be reinjected on the next launchApp()")
                }
                return (true, "")
            }
        }
    }
}
