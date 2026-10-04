// run の開始時に補助プロセス(`fleetest api vision-serve`)を1つ起こし、終了時に止める(起動する側)。
// 呼び口は `RunOrchestrator.run` の1箇所(`fleetest run` / `fleetest api run` / リモートのランナー機の run はどれもここを通る)。
// 設計は docs/maintainer-notes.md §67。
//
// **プロセスに1つ**(1 つの親の中で RunOrchestrator が複数回走る = 複数機械に跨るプロファイル。参照を数えて最初の acquire で起こし、
// 最後の release で止める)。起こすのは**画像の見本を持つプロジェクトのときだけ**(`FindImage.prewarmIfNeeded` と同じ条件)・
// **実行ファイルが `fleetest` のときだけ**(テストの xctest などを `api vision-serve` で起こさない)。
// 寿命: 親の死は `ParentDeathWatch`(`FT_PARENT_PID`)と stdin の EOF の両方で拾う。止めるときは stdin を閉じて SIGTERM
// (補助は自分でソケットを消す = 後始末を持つので時限 SIGKILL は送らない。process-lifecycle.md)。

import Foundation
import Synchronization

public enum VisionHelperHost {
    private struct State {
        var references = 0
        var process: Process?
        var stdin: Pipe?
        var socketPath: String?
    }
    private static let state = Mutex(State())

    /// 起動中ならそのソケットのパス(`ScenarioHost.childEnvironment` がシナリオのプロセスへ渡す)
    static var activeSocketPath: String? { state.withLock { $0.socketPath } }

    /// 補助を起こす条件(純粋関数): 画像の見本があり、実行ファイルが `fleetest`
    static func shouldStart(hasTemplates: Bool, executableName: String?) -> Bool {
        hasTemplates && executableName == "fleetest"
    }

    /// 返したトークンを run の終わりに必ず `release` する(参照を数えるので、起こさなかった場合も同じ形で呼んでよい)
    public static func acquire(project: TestProject) -> Lease {
        let directory = VisionClassifier.directory(projectRoot: project.rootURL, name: DefaultClassifier.name)
        let hasTemplates = !FindImage.templateFiles(label: "", classifierDirectory: directory, isAndroid: false).isEmpty
        let executable = Bundle.main.executableURL
        let wanted = shouldStart(hasTemplates: hasTemplates, executableName: executable?.lastPathComponent)
        state.withLock { state in
            state.references += 1
            guard wanted, state.process == nil, let executable,
                  let path = VisionHelperWire.socketPath(parentPID: getpid()) else { return }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["api", "vision-serve", "--socket", path]
            process.environment = ParentDeathWatch.childEnvironment()
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.qualityOfService = .utility
            do {
                try process.run()
            } catch {
                return
            }
            state.process = process
            state.stdin = stdin
            state.socketPath = path
        }
        return Lease()
    }

    public struct Lease: Sendable {
        public func release() { VisionHelperHost.release() }
    }

    private static func release() {
        // UncheckedTransfer の根拠: 取り出した Process / Pipe は state から外れ、ここから先は release だけが触る
        let stopping: UncheckedTransfer<(Process, Pipe)>? = state.withLock { state in
            state.references -= 1
            guard state.references <= 0, let process = state.process, let stdin = state.stdin else { return nil }
            state.process = nil
            state.stdin = nil
            state.socketPath = nil
            state.references = 0
            return UncheckedTransfer((process, stdin))
        }
        guard let (process, stdin) = stopping?.value else { return }
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
