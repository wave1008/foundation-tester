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
                                               explicitPath: explicitPath, apps: apps,
                                               physical: worker.connection.physical) {
            case .error(let message):
                return (false, message)
            case .resolved(let path, let bundleID):
                let note: String?
                do {
                    note = try await ProfileWorkerFactory.installOne(
                        worker: worker, bundleID: bundleID, appPath: path)
                } catch {
                    return (false, "installApp: \(error.localizedDescription)")
                }
                // inapp モードは simctl install でアプリ内常駐ブリッジが道連れに終了するが、
                // 次の launchApp()(InAppDriver.launch)が simctl 再起動+dylib 再注入で必ず張り直す
                // (installIfNeeded が inapp モードをスキップするのと対照的に、installApp() は
                // 利用者の明示要求なので普通にインストールし、注記だけ返す)
                if worker.platform == "ios", worker.connection.mode == IOSMode.inapp {
                    let reinject = "the in-app bridge will be reinjected on the next launchApp()"
                    return (true, note.map { "\($0); \(reinject)" } ?? reinject)
                }
                return (true, note ?? "")
            }
        }
    }
}
