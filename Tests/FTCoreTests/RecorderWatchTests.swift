// 録画の見張り(RecorderWatch)の判定とループを、観測と SIGINT を差し替えて確かめる(製品バイナリ・デバイス不要)。
// 偽の client は「壁時計の期限か N 回目の SIGINT の早いほう」で gone になる = 送り直しを消す変異でもループが終わる。

import XCTest
@testable import FTCore

final class RecorderWatchTests: XCTestCase {
    private let target = RecorderWatch.Target(pid: 4242, startedMicroseconds: 1_700_000_000_123_456)

    private final class FakeClient: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var interrupts = 0
        private var unreadableLeft: Int
        private let diesAfter: Int
        private let deadline: Date
        private let startedMicroseconds: Int64

        init(startedMicroseconds: Int64, diesAfter: Int, unreadableFirst: Int = 0, lifetime: TimeInterval = 0.4) {
            self.startedMicroseconds = startedMicroseconds
            self.diesAfter = diesAfter
            self.unreadableLeft = unreadableFirst
            self.deadline = Date().addingTimeInterval(lifetime)
        }

        func observe(_ pid: pid_t) -> ProcessLiveness.Observation {
            lock.lock(); defer { lock.unlock() }
            if unreadableLeft > 0 { unreadableLeft -= 1; return .unreadable }
            if interrupts >= diesAfter || Date() >= deadline { return .gone }
            return .alive(startedMicroseconds: startedMicroseconds)
        }

        func interrupt(_ pid: pid_t) { lock.lock(); interrupts += 1; lock.unlock() }
    }

    private func makeFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fleetest-recorder-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.mov")
        try Data("x".utf8).write(to: file)
        return file
    }

    func testDecideTable() {
        XCTAssertEqual(RecorderWatch.decide(.gone, target: target), .finish)
        XCTAssertEqual(RecorderWatch.decide(.unreadable, target: target), .hold)
        XCTAssertEqual(RecorderWatch.decide(.alive(startedMicroseconds: target.startedMicroseconds), target: target), .interrupt)
        XCTAssertEqual(RecorderWatch.decide(.alive(startedMicroseconds: target.startedMicroseconds + 1), target: target), .finish,
                       "起動時刻が違う = pid が別のプロセスに使い回された。送らずに終わる")
    }

    /// 止まるまで送り直し、止まったらファイルを消す
    func testInterruptsUntilTheClientIsGoneThenDeletesTheFile() async throws {
        let file = try makeFile()
        let client = FakeClient(startedMicroseconds: target.startedMicroseconds, diesAfter: 3)
        let started = Date()
        await RecorderWatch.run(target: target, file: file, stdin: nil, interval: 0.02,
                                observe: client.observe, sendInterrupt: client.interrupt)
        XCTAssertEqual(client.interrupts, 3, "3 回目の SIGINT で止まる偽物には 3 回送るはず")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.4, "止まった直後に戻るはず(偽物の寿命 0.4 秒を待っていない)")
    }

    /// 起動時刻が一致しない相手には 1 度も送らない(ファイルは消す)
    func testDoesNotInterruptAReusedPid() async throws {
        let file = try makeFile()
        let client = FakeClient(startedMicroseconds: target.startedMicroseconds + 1, diesAfter: 1)
        await RecorderWatch.run(target: target, file: file, stdin: nil, interval: 0.02,
                                observe: client.observe, sendInterrupt: client.interrupt)
        XCTAssertEqual(client.interrupts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// 観測できない間は送らず・終わらず、見えたら送る
    func testHoldsWhileUnreadableAndResumes() async throws {
        let file = try makeFile()
        let client = FakeClient(startedMicroseconds: target.startedMicroseconds, diesAfter: 2, unreadableFirst: 3)
        await RecorderWatch.run(target: target, file: file, stdin: nil, interval: 0.02,
                                observe: client.observe, sendInterrupt: client.interrupt)
        XCTAssertEqual(client.interrupts, 2, "unreadable の 3 周は送らず、その後の 2 回で止まる")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDoesNothingForAClientThatIsAlreadyGone() async throws {
        let file = try makeFile()
        let client = FakeClient(startedMicroseconds: target.startedMicroseconds, diesAfter: 0)
        await RecorderWatch.run(target: target, file: file, stdin: nil, interval: 0.02,
                                observe: client.observe, sendInterrupt: client.interrupt)
        XCTAssertEqual(client.interrupts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// 消すのは最終名と `<最終名>.sb-` で始まる兄弟だけ(別の最終名の一時ファイルは残す)
    func testRemoveOutputsDeletesOnlyTheFileAndItsOwnTemporaries() throws {
        let file = try makeFile()
        let dir = file.deletingLastPathComponent()
        let own = dir.appendingPathComponent("a.mov.sb-1234")
        let lookalike = dir.appendingPathComponent("a.movie.sb-1234")
        let other = dir.appendingPathComponent("b.mov.sb-1234")
        for url in [own, lookalike, other] { try Data().write(to: url) }
        RecorderWatch.removeOutputs(of: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lookalike.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    /// 読み捨ては改行が無くても読み進める(行に分ける読み手は EOF まで何も捨てない)
    func testDrainConsumesOutputWithoutNewlinesBeforeEOF() async throws {
        let pipe = Pipe()
        let counted = LockedValue(0)
        RecorderWatch.drain(pipe.fileHandleForReading) { bytes in counted.withLock { $0 += bytes } }
        let total = 1_048_576
        let writer = Thread {
            pipe.fileHandleForWriting.write(Data(repeating: UInt8(ascii: "x"), count: total))
        }
        writer.start()
        let deadline = Date().addingTimeInterval(5)
        while counted.value < total, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(counted.value, total, "書き端が開いたまま(EOF の前)でも全部読み捨てているはず")
        try pipe.fileHandleForWriting.close()
    }
}
