// ディスパッチの ssh を包む sh(ParentBoundCommand)を本物のプロセスで確かめる。
// 子(ssh の代わりに sleep / sh)の終了コードを返すこと・正常終了に遅れを足さないこと・
// 親が死んだら子を止めること・包みへの中断が子へ届くこと。

import Foundation
import XCTest
import FTRemote

final class ParentBoundCommandTests: XCTestCase {

    private func run(_ argv: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func childPIDs(of pid: Int32) -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        try? pgrep.run()
        pgrep.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
            .split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    private func isRunning(_ pid: Int32) -> Bool {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "stat=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        ps.waitUntilExit()
        let stat = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !stat.isEmpty && !stat.hasPrefix("Z")
    }

    /// 子の終了コードをそのまま返し、見張りの間隔(2 秒)を待たずに終わる
    func testReturnsTheChildsExitCodeWithoutWaitingForThePoll() throws {
        let start = Date()
        let wrapped = try run(ParentBoundCommand.wrap(["/bin/sh", "-c", "exit 7"],
                                                      parentPID: ProcessInfo.processInfo.processIdentifier))
        wrapped.waitUntilExit()
        XCTAssertEqual(wrapped.terminationStatus, 7)
        XCTAssertLessThan(Date().timeIntervalSince(start), Double(ParentBoundCommand.pollSeconds))
    }

    /// **出力をパイプで読む側の EOF も遅らせない**(ディスパッチャは ssh の stdout を EOF まで中継する)。
    /// 見張りが stdout を継いでいると、見張りの `sleep` がパイプを握って EOF が見張りの間隔ぶん遅れる
    func testOutputPipeReachesEOFWithoutWaitingForThePoll() throws {
        let process = Process()
        let argv = ParentBoundCommand.wrap(["/bin/echo", "hi"],
                                           parentPID: ProcessInfo.processInfo.processIdentifier)
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let start = Date()
        try process.run()
        var output = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
        }
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "hi\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), Double(ParentBoundCommand.pollSeconds) / 2)
        process.waitUntilExit()
    }

    /// **親(包みを起こしたプロセス)が SIGKILL で死んだら、子を止める**(孤児の ssh を残さない)
    func testStopsTheChildWhenItsParentDies() throws {
        // 親 = 包みを背景で起こして待つ sh(launcher)。包みには launcher 自身の pid($$)を親として渡す
        // (wrap の argv と同じ並び: script, $0, 親の pid, 子の argv)
        let script = ParentBoundCommand.wrap([], parentPID: 0)[2]
        let launcher = try run(["/bin/sh", "-c",
                                "/bin/sh -c \"$1\" watch $$ /bin/sleep 60 & wait", "launcher", script])
        Thread.sleep(forTimeInterval: 0.5)
        guard let wrapper = childPIDs(of: launcher.processIdentifier).first,
              let sleeper = childPIDs(of: wrapper).first(where: { pid in
                  // 見張りのサブシェル(sh)ではなく sleep 60 のほう
                  let ps = Process()
                  ps.executableURL = URL(fileURLWithPath: "/bin/ps")
                  ps.arguments = ["-o", "command=", "-p", String(pid)]
                  let pipe = Pipe()
                  ps.standardOutput = pipe
                  try? ps.run()
                  ps.waitUntilExit()
                  return String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
                      .contains("sleep 60")
              }) else {
            launcher.terminate()
            return XCTFail("could not find the wrapper and its child")
        }
        XCTAssertTrue(isRunning(sleeper))
        kill(launcher.processIdentifier, SIGKILL)
        launcher.waitUntilExit()

        let deadline = Date().addingTimeInterval(Double(ParentBoundCommand.pollSeconds) + 3)
        while isRunning(sleeper), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        let stopped = !isRunning(sleeper)
        if !stopped { kill(sleeper, SIGKILL) }
        XCTAssertTrue(stopped, "the child must be stopped within the poll interval after its parent dies")
    }

    /// 包みへの `terminate()`(InterruptRelay が撃つもの)は子にも届く —— プロセスグループごと届くため。
    /// 見張り(2 秒)より十分短く止まることで、見張りに頼っていないことも確かめる
    func testTerminateOnTheWrapperReachesTheChild() throws {
        let wrapped = try run(ParentBoundCommand.wrap(["/bin/sleep", "60"],
                                                      parentPID: ProcessInfo.processInfo.processIdentifier))
        Thread.sleep(forTimeInterval: 0.5)
        // 止める前に子(sleep 60)を控える —— 包みが中継せずに死んでも「子の一覧が空」になるので、
        // 一覧ではなく子そのものの生死で見る
        let children = childPIDs(of: wrapped.processIdentifier)
        XCTAssertFalse(children.isEmpty)
        let start = Date()
        wrapped.terminate()
        wrapped.waitUntilExit()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        // **見張りの間隔より短く**(1 秒)で止まっていること(それより長く待つと見張りが止めた回と区別できない)
        let deadline = start.addingTimeInterval(Double(ParentBoundCommand.pollSeconds) / 2)
        while children.contains(where: isRunning), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let survivors = children.filter(isRunning)
        survivors.forEach { kill($0, SIGKILL) }
        XCTAssertTrue(survivors.isEmpty, "terminate() on the wrapper must reach its child")
    }
}
