// PipeLinePump(Sources/FTRemote/PipeLinePump.swift)の陽性対照。子は /bin/sh の実プロセス。

import Foundation
import XCTest
import FTCore
import FTRemote

/// onLine は読み取りスレッドから呼ばれるので lock で守る
private final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func record(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

final class PipeLinePumpTests: XCTestCase {

    private func makeShellProcess(_ script: String) -> (process: Process, pipe: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        return (process, pipe)
    }

    func testDeliversLinesAndDrainsTrailingPartialLine() async throws {
        let (process, pipe) = makeShellProcess("printf \"a\\nb\\r\\nc\"")
        let exitStream = ProcessExitWait.prepare(process)  // 契約: run() より前に設定
        try process.run()
        let recorder = LineRecorder()
        let pump = PipeLinePump(handle: pipe.fileHandleForReading) { recorder.record($0) }
        pump.start()
        for await _ in exitStream {}
        let remaining = await pump.drain()

        XCTAssertEqual(recorder.snapshot(), ["a", "b"])
        XCTAssertEqual(remaining, "c")
    }

    func testEmptyOutputCallsNoLinesAndDrainsNil() async throws {
        let (process, pipe) = makeShellProcess(":")
        let exitStream = ProcessExitWait.prepare(process)
        try process.run()
        let recorder = LineRecorder()
        let pump = PipeLinePump(handle: pipe.fileHandleForReading) { recorder.record($0) }
        pump.start()
        for await _ in exitStream {}
        let remaining = await pump.drain()

        XCTAssertEqual(recorder.snapshot(), [])
        XCTAssertNil(remaining)
    }

    /// EOF が drain より先に来ても取りこぼさない(finish 済みの AsyncStream を後から待てる)
    func testDrainAfterEOFAlreadyArrivedStillWorks() async throws {
        let (process, pipe) = makeShellProcess("printf \"a\\nb\\r\\nc\"")
        let exitStream = ProcessExitWait.prepare(process)
        try process.run()
        let recorder = LineRecorder()
        let pump = PipeLinePump(handle: pipe.fileHandleForReading) { recorder.record($0) }
        pump.start()
        for await _ in exitStream {}
        try await Task.sleep(for: .milliseconds(200))
        let remaining = await pump.drain()

        XCTAssertEqual(recorder.snapshot(), ["a", "b"])
        XCTAssertEqual(remaining, "c")
    }

    /// availableData の分割境界を跨ぐ行が壊れない(chunk と行の境界は一致しない)
    func testHandlesManyLinesAcrossChunkBoundaries() async throws {
        let (process, pipe) = makeShellProcess("seq 1 5000")
        let exitStream = ProcessExitWait.prepare(process)
        try process.run()
        let recorder = LineRecorder()
        let pump = PipeLinePump(handle: pipe.fileHandleForReading) { recorder.record($0) }
        pump.start()
        for await _ in exitStream {}
        let remaining = await pump.drain()

        XCTAssertNil(remaining)
        XCTAssertEqual(recorder.snapshot(), (1...5000).map(String.init))
    }
}
