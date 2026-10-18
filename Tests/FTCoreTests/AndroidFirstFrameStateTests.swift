// Android ブリッジの最初のフレームの確定(AndroidRunner/.../FirstFrameState.java)を javac / java で動かして固定する。
// Java の単体テストの仕組みは無いので、Android に依存しないこのクラスだけを手元の JDK で動かす(ブリッジのビルドにも JDK が要る)。
// 守るのは2つの経路: ①消す前の読みの当て込み(beforeLatencyClear)②取得(fetch)= 確定していれば今の履歴を読まない

import XCTest

final class AndroidFirstFrameStateTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// 各行 = 1ケース。`check` は失敗した名前を stdout に出して exit 1
    private static let driver = """
        package com.example.ftbridge;
        public final class FirstFrameStateDriver {
            static int failures = 0;
            static void check(String name, boolean ok) { if (!ok) { System.out.println("FAIL " + name); failures++; } }
            static Object[] frame(long ms) { return new Object[] {Long.valueOf(ms), null}; }
            static Object[] reason(String r) { return new Object[] {null, r}; }
            public static void main(String[] a) {
                FirstFrameState s = new FirstFrameState();
                s.absorb(reason("frameHistoryIncomplete"));
                s.absorb(frame(5000));
                check("incompleteThenFrameIsIncomplete", s.decided() && s.decidedResult()[0] == null
                    && "frameHistoryIncomplete".equals(s.decidedResult()[1]));

                s = new FirstFrameState();
                s.absorb(reason("noFrame"));
                check("noFrameIsProvisional", !s.decided() && s.decidedResult() == null);
                s.absorb(frame(800));
                check("laterFrameDecides", s.decided() && Long.valueOf(800).equals(s.decidedResult()[0]));

                s = new FirstFrameState();
                s.absorb(frame(60));
                s.absorb(reason("frameHistoryIncomplete"));
                s.absorb(frame(900));
                check("frameStaysOnceDecided", Long.valueOf(60).equals(s.decidedResult()[0]) && s.decidedResult()[1] == null);
                System.exit(failures == 0 ? 0 : 1);
            }
        }
        """

    private func run(_ tool: String, _ args: [String], log: URL) throws -> Int32 {
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = handle
        p.standardError = handle
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func testFirstFrameIsDecidedByTheFirstFrameOrAnEarlierHistoryGap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-firstframe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let driverURL = dir.appendingPathComponent("FirstFrameStateDriver.java")
        try Self.driver.write(to: driverURL, atomically: true, encoding: .utf8)
        let source = Self.repoRoot.appendingPathComponent("AndroidRunner/src/com/example/ftbridge/FirstFrameState.java")
        let classes = dir.appendingPathComponent("classes")
        let log = dir.appendingPathComponent("log.txt")

        let compiled = try run("/usr/bin/javac", ["-encoding", "UTF-8", "-d", classes.path, source.path, driverURL.path],
                               log: log)
        let compileLog = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertEqual(compiled, 0, "javac が通らない(JDK はブリッジのビルドにも要る): \(compileLog)")
        guard compiled == 0 else { return }

        let status = try run("/usr/bin/java", ["-cp", classes.path, "com.example.ftbridge.FirstFrameStateDriver"], log: log)
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertEqual(status, 0, output)
    }
}
