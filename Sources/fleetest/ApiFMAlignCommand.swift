import ArgumentParser
import Foundation
import FTCore

struct ApiFMAlignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fm-align",
        abstract: "Align a running FM helper with this executable after all inference finishes")

    @Option(help: "Unix domain socket path (default: ~/.fleetest/fm.sock)")
    var socket: String?

    @Option(help: "FM executable to align after the build (default: fleetest beside this executable)")
    var targetExecutable: String?

    @Option(help: "Shell command to build the target after the old FM process has safely retired")
    var buildCommand: String?

    @Flag(help: "With --build-command: do not start FM again after the build (the next FM caller starts the new executable)")
    var noRestart = false

    func validate() throws {
        if buildCommand != nil, targetExecutable == nil {
            throw ValidationError("--build-command requires --target-executable")
        }
        if noRestart, buildCommand == nil {
            throw ValidationError("--no-restart requires --build-command")
        }
    }

    func run() async throws {
        do {
            let target = targetExecutable.map { URL(fileURLWithPath: $0) }
            _ = try await FMServeAlignment.align(socketPath: socket, executable: target,
                                                build: Self.buildOperation(command: buildCommand),
                                                restartAfterBuild: !noRestart) { ConsoleOut.err($0) }
        } catch {
            ConsoleOut.err("FM alignment failed: \(ErrorText.user(error))")
            throw ExitCode.failure
        }
    }

    struct BuildFailure: Error, CustomStringConvertible {
        let status: Int32
        var description: String { "the FM build command exited with status \(status)" }
    }

    static func buildOperation(command: String?) -> (() async throws -> Void)? {
        guard let command else { return nil }
        return { try await runBuildCommand(command) }
    }

    static func runBuildCommand(_ command: String) async throws {
        let arguments = ["-c", command]
        if let index = ProcessArguments.firstNULIndex(arguments) { throw ShellError.argumentContainsNUL(index: index) }
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        let interrupted = LockedValue(false)
        let terminate: @Sendable () -> Void = {
            interrupted.withLock { $0 = true }
            // shの子も同じグループに居る。ビルドの後始末を待ち、時限のSIGKILLは送らない。
            if process.isRunning { killpg(process.processIdentifier, SIGTERM) }
        }
        let relay = InterruptRelay.observing(terminate)
        defer { relay.stop() }
        let status: Int32 = try await withTaskCancellationHandler {
            // AsyncStreamは取消で先に終わるため使わず、子の実際の終了通知まで所有権を保持する。
            try await withCheckedThrowingContinuation { continuation in
                guard !interrupted.value, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                process.terminationHandler = { child in continuation.resume(returning: child.terminationStatus) }
                do {
                    try process.run()
                    if interrupted.value || Task.isCancelled { terminate() }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            terminate()
        }
        try Task.checkCancellation()
        if interrupted.value { throw CancellationError() }
        guard process.terminationReason == .exit, status == 0 else { throw BuildFailure(status: status) }
    }
}
