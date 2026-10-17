import Foundation

/// アラインの保守経路だけが使う。通常の呼び手の版違い判定(FMServeHost.decide)からは呼ばない。
public enum FMServeAlignment {
    public enum Outcome: String, Sendable {
        case notRunning, reused, replaced
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    public static func align(socketPath: String? = nil, executable: URL? = nil,
                             build: (() async throws -> Void)? = nil,
                             log: (String) -> Void) async throws -> Outcome {
        guard let path = socketPath ?? FMServeWire.socketPath(), FramedUnixSocket.fitsSunPath(path),
              let target = executable ?? FMServeHost.serverExecutable() else {
            throw Failure("the FM socket or executable path could not be resolved")
        }
        let resolved = ExecutablePath.resolved(target)
        let buildOperation: (() async throws -> Artifact)? = build.map { operation in
            return {
                try await operation()
                let built = ExecutablePath.resolved(target)
                guard FileManager.default.isExecutableFile(atPath: built.path) else {
                    throw Failure("the build did not produce an executable at \(target.path)")
                }
                return Artifact(executable: built, stamp: FMServeWire.buildStamp(executable: built.path))
            }
        }
        return try await align(socketPath: path, executable: resolved,
                               stamp: FMServeWire.buildStamp(executable: resolved.path), build: buildOperation, log: log)
    }

    /// 全枠を押さえる。**1 枠でも呼び手(FM の呼び出し・モニターの死活の確かめ)が握っていれば待って取り直す**
    /// (busy の再照会と同じ `waitSeconds`)。待たずに落とすと、1 分おきの確かめ(1 秒前後)と重なっただけで
    /// アラインが失敗した(実測: M1Max で `errno 35`。2 回目は通った)。開けない等の待っても直らない失敗は即座に返す
    static func holdMaintenance(within waitSeconds: Double,
                                hold: () throws -> any Sendable) async throws -> any Sendable {
        let deadline = ContinuousClock.now.advanced(by: .seconds(waitSeconds))
        while true {
            do {
                return try hold()
            } catch let error as FMCallSlots.MaintenanceError where error.slotHeld {
                guard ContinuousClock.now < deadline else {
                    throw Failure("an FM call or liveness probe kept holding an FM slot for \(Int(waitSeconds))s;"
                        + " no process was stopped. Retry alignment after it finishes (\(error.description))")
                }
                // 刻みは確かめ 1 回(約 1 秒)より十分短ければよい(空いた直後に取りにいくため)
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    struct Artifact: Sendable {
        let executable: URL
        let stamp: String
    }

    static func align(
        socketPath: String, executable: URL, stamp: String,
        waitSeconds: Double = FMServeHost.retirementWaitSeconds,
        holdMaintenance: () throws -> any Sendable = { try FMCallSlots.acquireForMaintenance() },
        spawn: (URL, String) -> Bool = FMServeHost.spawn,
        build: (() async throws -> Artifact)? = nil,
        log: (String) -> Void = { _ in }
    ) async throws -> Outcome {
        let client = FMServeClient(socketPath: socketPath, deadlineSeconds: 3)
        let initial: FMServeWire.Identity
        do {
            initial = try await client.status()
        } catch {
            guard FramedUnixSocket.isReleased(path: socketPath) else {
                throw Failure("the FM socket could not be confirmed as free and its identity could not be read; no process was stopped")
            }
            if let build {
                let maintenance = try await Self.holdMaintenance(within: waitSeconds, hold: holdMaintenance)
                defer { withExtendedLifetime(maintenance) {} }
                let artifact = try await buildWhileReserved(socketPath: socketPath, build: build)
                guard !artifact.stamp.isEmpty else { throw Failure("the built FM executable's build stamp could not be read") }
            }
            log("FM was not running before alignment; no FM process was started")
            return .notRunning
        }
        guard build != nil || !stamp.isEmpty else { throw Failure("the replacement FM executable's build stamp could not be read") }
        if build == nil, matches(initial, executable: executable.path, stamp: stamp) {
            log("FM process already matches protocol \(initial.serverVersion), \(initial.executable) \(initial.buildStamp)")
            return .reused
        }
        guard initial.serverVersion <= FMServeWire.protocolVersion else {
            throw Failure("the FM process uses newer protocol \(initial.serverVersion); no process was stopped")
        }
        guard initial.serverVersion >= FMServeWire.minimumRetirementServerVersion else {
            throw Failure("the FM process uses protocol \(initial.serverVersion) at \(initial.executable), which cannot"
                + " confirm that all inference has finished; no process was stopped. Stop its old callers and"
                + " arrange a one-time manual handover, then retry alignment")
        }
        let maintenance = try await Self.holdMaintenance(within: waitSeconds, hold: holdMaintenance)
        defer { withExtendedLifetime(maintenance) {} }
        // 枠は起動競争を防ぐだけ。期限を過ぎた推論まで終わったことは常駐プロセス自身が判定する。
        let response = try await client.waitForRetirement(target: initial, waitSeconds: waitSeconds)
        guard response.controlVersion == FMServeWire.retirementProtocolVersion,
              sameServer(response.identity, initial) else {
            throw Failure("the FM identity or retirement control version did not match; alignment was not completed")
        }
        switch response.outcome {
        case .retiring:
            log("FM process is idle and retiring: \(initial.executable) \(initial.buildStamp)")
        case .busy:
            throw Failure("the FM process is still busy (including possibly unfinished timed-out inference);"
                + " no process was stopped. Retry alignment after it finishes")
        case .identityMismatch, .newerServer, .unsupported:
            throw Failure("the FM process refused safe handover (\(response.outcome.rawValue)); no process was stopped")
        }
        let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(FMServeHost.startupWaitSeconds))
        while !FramedUnixSocket.isReleased(path: socketPath) {
            guard ContinuousClock.now < releaseDeadline else {
                throw Failure("the retiring FM process has not released its socket; alignment was not completed")
            }
            // 刻みは期限(startupWaitSeconds = 5 秒)より十分短ければよい。尽きたら上の Failure
            try await Task.sleep(for: .milliseconds(100))
        }
        let artifact: Artifact
        if let build {
            artifact = try await buildWhileReserved(socketPath: socketPath, build: build)
        } else {
            artifact = Artifact(executable: executable, stamp: stamp)
        }
        guard !artifact.stamp.isEmpty else { throw Failure("the built FM executable's build stamp could not be read") }
        try Task.checkCancellation()
        guard spawn(artifact.executable, socketPath) else { throw Failure("the replacement FM process could not be started") }
        let startupDeadline = ContinuousClock.now.advanced(by: .seconds(FMServeHost.startupWaitSeconds))
        while ContinuousClock.now < startupDeadline {
            if let status = try? await client.status() {
                guard matches(status, executable: artifact.executable.path, stamp: artifact.stamp) else {
                    throw Failure("another FM process owns the socket (protocol \(status.serverVersion),"
                        + " \(status.executable) \(status.buildStamp)); alignment was not completed")
                }
                log("FM process aligned: protocol \(status.serverVersion), \(status.executable) \(status.buildStamp)")
                return .replaced
            }
            // 刻みは期限(startupWaitSeconds = 5 秒)より十分短ければよい。尽きたら下の Failure
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("the replacement FM process did not answer within \(Int(FMServeHost.startupWaitSeconds))s")
    }

    private static func sameServer(_ lhs: FMServeWire.Identity, _ rhs: FMServeWire.Identity) -> Bool {
        lhs.serverVersion == rhs.serverVersion && lhs.executable == rhs.executable && lhs.buildStamp == rhs.buildStamp
    }

    private static func matches(_ status: FMServeWire.Identity, executable: String, stamp: String) -> Bool {
        status.status == .ok && status.serverVersion == FMServeWire.protocolVersion
            && status.executable == executable && status.buildStamp == stamp
    }

    private static func buildWhileReserved(socketPath: String,
                                           build: () async throws -> Artifact) async throws -> Artifact {
        try Task.checkCancellation()
        guard let ownership = FramedUnixSocket.acquireOwnership(path: socketPath) else {
            throw Failure("the FM socket ownership could not be reserved before the build; no build was started")
        }
        defer { withExtendedLifetime(ownership) {} }
        guard !FramedUnixSocket.isServed(path: socketPath) else {
            throw Failure("another FM process appeared before the build; no build was started")
        }
        return try await build()
    }
}
