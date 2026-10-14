// `fleetest api services-owner`: `fleetest services up` が起こす常駐の所有者(docs/remote-runner.md §17「調停」)。
// サービスを上げ、控え(kind = owner)・プロキシ・adb reverse を持ったまま SIGTERM/SIGINT/SIGHUP を待ち、受けたら片付けて終わる。
// 起こすのは `ServicesOwnerLaunch.spawn`(stdin は /dev/null・出力は .fleetest/services/<prefix>.log・FT_PARENT_PID は消す = 親より長く生きる)。
// 止めるのは `services down` と run の引き取り(`ServicesSession.takeOverOwners`)。dispatch.lock は取らない(MCP の印と同じ扱い)。
// 2 度目のシグナルは `RunInterruptState` の規律どおり即終了(資源は控えが残る = 次の run / reap が片付ける)。

import ArgumentParser
import FTCore
import Foundation

struct ApiServicesOwnerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "services-owner",
        abstract: "Hold a workspace's services (scripts/compose.yaml) up until SIGTERM"
            + " (started by `fleetest services up`; not meant to be run directly)")

    @Option(name: .long, help: "Test project")
    var project: String?

    @Option(name: .long, help: "Run profile")
    var profile: String?

    @Flag(help: "Also publish the ports on this Mac's LAN address (services.publishForPhysicalDevices)")
    var physical = false

    @Option(name: .long, help: "Android physical device (adb serial) that receives `adb reverse` for each published TCP port; repeatable")
    var serial: [String] = []

    func run() async throws {
        signal(SIGPIPE, SIG_IGN)   // 読み手の居ないログへの書き込みで落ちない
        let target = try ServicesCommand.resolveTarget(project: project, profile: profile)
        let stopped = DispatchSemaphore(value: 0)
        let interruptState = RunInterruptState(recorder: nil, notice: "⏹ services-owner: stop requested — removing the services")
        // 片付けに入った後のシグナル(`services down` の打ち直し・run の引き取り)は無視する ——
        // `requestStop()` の 2 度目は即終了なので、片付けの途中で落ちて資源と控えを残す
        let tearingDown = LockedValue(false)
        let relay = InterruptRelay.observing {
            if !tearingDown.value { interruptState.requestStop() }   // 起動の途中なら pull / build / 待ちを止める
            stopped.signal()
        }
        defer { relay.stop() }
        let log: (String) -> Void = { ConsoleOut.out(Self.timestamp() + " " + $0) }
        let options = ServicesUpOptions(kind: .owner, publishForPhysicalDevices: physical, adbReverseSerials: serial)

        let session: ServicesSession
        do {
            guard let started = try ServicesSession.up(resolved: target.resolved, stateDir: target.stateDir, options: options,
                                                       interruptState: interruptState, log: log) else {
                ConsoleOut.err("✗ services: no scripts/compose.yaml in \(target.workspace.root.path)")
                throw ExitCode.failure
            }
            session = started
        } catch let error as ServicesError {
            ConsoleOut.err("✗ \(error.shortDescription)")
            throw ExitCode.failure
        } catch let error as ExitCode {
            throw error
        } catch {
            ConsoleOut.err("✗ services: \(error.localizedDescription)")
            throw ExitCode.failure
        }
        log("→ services: up; holding them until `fleetest services down` (or SIGTERM)")

        // シグナルが起動の途中に来ていれば semaphore は既に立っている = 待たずに片付けへ
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                stopped.wait()
                continuation.resume()
            }
            thread.name = "fleetest-api-services-owner-wait"
            thread.start()
        }
        tearingDown.value = true
        session.down(log: log)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
