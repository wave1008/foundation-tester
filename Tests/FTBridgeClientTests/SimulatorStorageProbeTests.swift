// SimulatorStorageProbe の並列走査。一時ディレクトリに木を作り、du -sk と同じ量になることを確かめる
// (期待値は production の関数ではなく du で作る)。

import XCTest
@testable import FTBridgeClient

final class SimulatorStorageProbeTests: XCTestCase {

    /// 並列度はコア数の半分(ユーザー決定)。1 コアでも 1 本は動かす
    func testWalkerThreadsAreHalfTheCores() {
        XCTAssertEqual(SimulatorStorageProbe.walkerThreads(cores: 8), 4)
        XCTAssertEqual(SimulatorStorageProbe.walkerThreads(cores: 24), 12)
        XCTAssertEqual(SimulatorStorageProbe.walkerThreads(cores: 1), 1)
    }

    /// 隠しファイル・深い階層を含む木で du -sk と一致し、スレッド数で値が変わらない。
    /// シンボリックリンク先(木の外の大きなファイル)は数えない
    func testWalkMatchesDuAndDoesNotDependOnThreadCount() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("SimulatorStorageProbeTests-\(UUID().uuidString)")
        addTeardownBlock { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("data")
        for a in 0..<4 {
            for b in 0..<5 {
                let dir = root.appendingPathComponent("d\(a)/.hidden\(b)/deep/er")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for c in 0..<6 {
                    let size = 1 + (a * 97 + b * 31 + c * 7919) % 70_000
                    try Data(repeating: UInt8(c), count: size)
                        .write(to: dir.appendingPathComponent(c % 2 == 0 ? "f\(c)" : ".f\(c)"))
                }
            }
        }
        let outside = base.appendingPathComponent("outside.bin")
        try Data(repeating: 1, count: 5_000_000).write(to: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("linkdir"), withDestinationURL: base)

        let du = Process()
        du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        du.arguments = ["-sk", root.path]
        let pipe = Pipe()
        du.standardOutput = pipe
        try du.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        du.waitUntilExit()
        let expected = try XCTUnwrap(Int(output.split(whereSeparator: \.isWhitespace).first ?? "")) * 1024

        let deadline = Date().addingTimeInterval(60)
        XCTAssertEqual(SimulatorStorageProbe.allocatedBytes(under: root, threads: 1, deadline: deadline), expected)
        XCTAssertEqual(SimulatorStorageProbe.allocatedBytes(under: root, threads: 4, deadline: deadline), expected)
        XCTAssertEqual(SimulatorStorageProbe.allocatedBytes(under: root, threads: 16, deadline: deadline), expected)
    }

    /// 締切を過ぎたら途中の和を返さず nil(0 や一部の量で前回値を上書きしない)
    func testPassedDeadlineReturnsNil() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SimulatorStorageProbeTests-\(UUID().uuidString)")
        addTeardownBlock { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("a/f"))
        XCTAssertNil(SimulatorStorageProbe.allocatedBytes(under: root, threads: 4,
                                                          deadline: Date().addingTimeInterval(-1)))
    }
}
