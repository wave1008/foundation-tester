// FM の常駐プロセス(fm-serve)の通信・起動の判断・配線。FM もデバイスも使わない(受け付けループは偽の処理で回す)。

import Foundation
import XCTest
@testable import FTCore

final class FMServeTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// sun_path(104 バイト)に収まる短い一時パス
    private func temporarySocketPath() -> String {
        "/tmp/ftfm-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    }

    // MARK: - 定数(既定値はリテラルで固定する)

    func testDefaultsArePinned() {
        XCTAssertEqual(FMServeWire.requestDeadlineSeconds, 20)
        XCTAssertEqual(FMServeWire.clientDeadlineSeconds, 25)
        XCTAssertEqual(FMServeWire.idleExitSeconds, 1800)
        XCTAssertEqual(FMServeHost.startupWaitSeconds, 5)
    }

    // MARK: - 通信の形

    func testRequestAndResponseSurviveTheFrameRoundTrip() throws {
        let request = FMServeWire.Request(kind: .screen, png: Data([1, 2, 3]), expected: "home", path: .vision)
        let frame = try FramedUnixSocket.encode(request)
        XCTAssertEqual(try FramedUnixSocket.decode(FMServeWire.Request.self, fromFrame: frame), request)
        XCTAssertEqual(request.version, FMServeWire.protocolVersion, "既定で今の版を載せる")
        let response = FMServeWire.Response(status: .ok, text: "tap=1", pass: true, reason: "r", error: nil,
                                            executable: "/x/fleetest", buildStamp: "1-2")
        XCTAssertEqual(try FramedUnixSocket.decode(FMServeWire.Response.self,
                                                   fromFrame: try FramedUnixSocket.encode(response)), response)
    }

    func testSocketPathIsTheMachineStateDirectory() throws {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(FMServeWire.socketPath(home: home), "/Users/someone/.fleetest/fm.sock")
        let long = URL(fileURLWithPath: "/" + String(repeating: "d", count: 120))
        XCTAssertNil(FMServeWire.socketPath(home: long), "sun_path に収まらないパスでは起こさない")
    }

    // MARK: - 起動の判断

    func testNeededFollowsTheTwoFMFeatures() {
        XCTAssertFalse(FMServeHost.needed(fmTextVisibilityCheck: false, screenLooksLike: false))
        XCTAssertTrue(FMServeHost.needed(fmTextVisibilityCheck: true, screenLooksLike: false))
        XCTAssertTrue(FMServeHost.needed(fmTextVisibilityCheck: false, screenLooksLike: true))
    }

    private func status(version: Int = FMServeWire.protocolVersion, executable: String, stamp: String) -> FMServeWire.Response {
        FMServeWire.Response(status: .ok, serverVersion: version, executable: executable, buildStamp: stamp)
    }

    /// 止めるのは「相手が自分の実行ファイルより古い」ときだけ。作り直す前から生きているプロセスが新しい常駐プロセスを止めない・
    /// 別のクローン同士が止め合わない
    func testLiveServerDecision() {
        let v = FMServeWire.protocolVersion
        // 同じ実行ファイル
        XCTAssertEqual(FMServeHost.decide(status(executable: "/a/fleetest", stamp: "1"), executable: "/a/fleetest",
                                          buildStamp: "1", serverExecutableStamp: "1"), .reuse)
        XCTAssertEqual(FMServeHost.decide(status(executable: "/a/fleetest", stamp: "1"), executable: "/a/fleetest",
                                          buildStamp: "2", serverExecutableStamp: "2"), .replace, "作り直す前の常駐プロセスは置き換える")
        XCTAssertEqual(FMServeHost.decide(status(version: v + 1, executable: "/a/fleetest", stamp: "2"), executable: "/a/fleetest",
                                          buildStamp: "2", serverExecutableStamp: "2"), .leave,
                       "古いのはこちら(作り直す前から生きているプロセス)= 新しい常駐プロセスを止めない")
        // 別の実行ファイル(別のクローン)
        XCTAssertEqual(FMServeHost.decide(status(executable: "/b/fleetest", stamp: "9"), executable: "/a/fleetest",
                                          buildStamp: "1", serverExecutableStamp: "9"), .reuse)
        XCTAssertEqual(FMServeHost.decide(status(version: v + 1, executable: "/b/fleetest", stamp: "9"), executable: "/a/fleetest",
                                          buildStamp: "1", serverExecutableStamp: "9"), .leave, "版の違う別のクローンを止め合わない")
        XCTAssertEqual(FMServeHost.decide(status(executable: "/b/fleetest", stamp: "8"), executable: "/a/fleetest",
                                          buildStamp: "1", serverExecutableStamp: "9"), .replace, "自分の実行ファイルより古い相手は置き換える")
        // 印が読めない(実行ファイルの属性が取れない = リンクの作り直しの瞬間など)は「古い」の根拠にしない(Codex レビュー 2026-10-15)
        XCTAssertEqual(FMServeHost.decide(status(executable: "/b/fleetest", stamp: "9"), executable: "/a/fleetest",
                                          buildStamp: "1", serverExecutableStamp: ""), .reuse)
        XCTAssertEqual(FMServeHost.decide(status(executable: "/a/fleetest", stamp: "1"), executable: "/a/fleetest",
                                          buildStamp: "", serverExecutableStamp: ""), .reuse)
        XCTAssertEqual(FMServeHost.decide(status(version: v + 1, executable: "/b/fleetest", stamp: "9"), executable: "/a/fleetest",
                                          buildStamp: "1", serverExecutableStamp: ""), .leave)
    }

    /// 常駐プロセスに `FT_PARENT_PID` を渡さない(渡すと親の死で終わり、拡張の孤児掃除にも殺される)
    func testServerEnvironmentDropsTheParentLink() {
        let env = FMServeHost.serverEnvironment([ParentDeathWatch.environmentKey: "123",
                                                 FMServeWire.socketEnvironmentKey: "/x.sock", "KEEP": "1"])
        XCTAssertNil(env[ParentDeathWatch.environmentKey])
        XCTAssertNil(env[FMServeWire.socketEnvironmentKey])
        XCTAssertEqual(env["KEEP"], "1")
    }

    func testServerExecutableIsTheSiblingFleetestOnly() {
        XCTAssertNil(FMServeHost.serverExecutable(current: URL(fileURLWithPath: "/x/xctest")),
                     "テストのプロセスからは起こさない")
        XCTAssertNil(FMServeHost.serverExecutable(current: nil))
    }

    // MARK: - 受け付けループとクライアント(実ソケット)

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// 偽の処理で受け付けループを回す。戻り値の closure で止めて終わりを待つ
    private func startServer(path: String, delayMs: UInt64 = 0,
                             handle: (@Sendable (FMServeWire.Request) -> FMServeWire.Response)? = nil) -> () -> Int32 {
        let stop = Flag()
        let done = DispatchSemaphore(value: 0)
        let code = LockedValue<Int32>(-1)
        Thread {
            let result = FramedUnixSocket.serve(
                socketPath: path, requestDeadlineSeconds: 5, tickMilliseconds: 50,
                shouldStop: { stop.isSet }, onTick: {},
                handle: { payload in
                    if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
                    guard let request = try? JSONDecoder().decode(FMServeWire.Request.self, from: payload) else { return nil }
                    let response = handle?(request)
                        ?? FMServeWire.Response(status: .ok, text: request.expected, executable: "fake", buildStamp: "0")
                    return try? JSONEncoder().encode(response)
                },
                log: { _ in })
            code.withLock { $0 = result }
            done.signal()
        }.start()
        let until = Date().addingTimeInterval(3)
        while !FramedUnixSocket.isServed(path: path), Date() < until { usleep(10_000) }
        return {
            stop.set()
            done.wait()
            return code.withLock { $0 }
        }
    }

    func testClientReachesTheServerAndGetsItsAnswer() async throws {
        let path = temporarySocketPath()
        let stop = startServer(path: path)
        let response = try await FMServeClient(socketPath: path, deadlineSeconds: 5)
            .send(FMServeWire.Request(kind: .screen, expected: "echo me"))
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.text, "echo me")
        XCTAssertEqual(stop(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "終了時にソケットを消す")
    }

    /// 要求は接続ごとに並行に捌く(直列だと 4 件で 4 倍かかる)。並行の度合いは呼び手の枠(FMCallSlots)が決める
    func testRequestsAreServedConcurrently() async throws {
        let path = temporarySocketPath()
        let stop = startServer(path: path, delayMs: 400)
        let started = Date()
        try await withThrowingTaskGroup(of: FMServeWire.Response.self) { group in
            for index in 0..<4 {
                group.addTask {
                    try await FMServeClient(socketPath: path, deadlineSeconds: 5)
                        .send(FMServeWire.Request(kind: .screen, expected: "\(index)"))
                }
            }
            var answers: Set<String> = []
            for try await response in group { answers.insert(response.text ?? "") }
            XCTAssertEqual(answers, ["0", "1", "2", "3"])
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 1.2, "4 件を直列に捌いている(並行なら約 0.4 秒・直列なら 1.6 秒)")
        XCTAssertEqual(stop(), 0)
    }

    func testClientWithoutServerIsUnavailableNotAnFMFailure() async {
        let path = temporarySocketPath()
        do {
            _ = try await FMServeClient(socketPath: path, deadlineSeconds: 1).send(FMServeWire.Request(kind: .status))
            XCTFail("居ないサーバから答えが返った")
        } catch let error as FMServeError {
            guard case .unavailable = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("FMServeError 以外で失敗した: \(error)")
        }
    }

    /// 同じソケットに生きた相手が居れば2つ目は起きない(1 を返す)。死んだ残骸のファイルは消して取る
    func testSecondServerRefusesALiveSocketButReplacesAStaleFile() throws {
        let path = temporarySocketPath()
        let stop = startServer(path: path)
        let second = FramedUnixSocket.serve(socketPath: path, requestDeadlineSeconds: 1, tickMilliseconds: 50,
                                            shouldStop: { true }, onTick: {}, handle: { _ in nil }, log: { _ in })
        XCTAssertEqual(second, 1, "生きた常駐プロセスがあるのに2つ目が起きた")
        XCTAssertEqual(stop(), 0)

        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let replaced = FramedUnixSocket.serve(socketPath: path, requestDeadlineSeconds: 1, tickMilliseconds: 50,
                                              shouldStop: { true }, onTick: {}, handle: { _ in nil }, log: { _ in })
        XCTAssertEqual(replaced, 0, "死んだ残骸のファイルを消して取れなかった")
    }

    /// 生きた持ち主のソケットファイルが(同時に起きた別の起動に)消されても、2つ目は起きない(ロックを握っている)。
    /// 起きると先の持ち主は誰からも届かない孤児になり、常駐プロセスが2つ並ぶ
    func testSecondServerRefusesWhileTheOwnerHoldsTheLockEvenIfTheFileIsGone() throws {
        let path = temporarySocketPath()
        let stop = startServer(path: path)
        unlink(path)
        let second = FramedUnixSocket.serve(socketPath: path, requestDeadlineSeconds: 1, tickMilliseconds: 50,
                                            shouldStop: { true }, onTick: {}, handle: { _ in nil }, log: { _ in })
        XCTAssertEqual(second, 1, "持ち主が生きているのに2つ目が起きた")
        XCTAssertEqual(stop(), 0)
        try? FileManager.default.removeItem(atPath: path + ".lock")
    }

    // MARK: - 配線(ソース走査)

    /// run の2実装が、シナリオを起こす前に・dry-run でなく・FM の機能が有効なときだけ常駐プロセスを用意する
    func testBothRunImplementationsEnsureTheFMProcess() throws {
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let text = try source(path)
            let list = try XCTUnwrap(text.range(of: "let all = try ScenarioHost.listForRun("), path)
            let ensure = try XCTUnwrap(text.range(of: "await FMServeHost.ensureRunning"), "\(path) が FM の常駐プロセスを用意していない")
            XCTAssertLessThan(list.lowerBound, ensure.lowerBound, path)
            XCTAssertTrue(text.contains("if !dryRun, FMServeHost.needed(fmTextVisibilityCheck:"),
                          "\(path) が設定を見ずに(または dry-run でも)常駐プロセスを起こす")
        }
    }

    /// シナリオのプロセスへソケットを渡し、サンドボックスがその接続を許す(どちらかが欠けると FM の検証が黙って skip になる)
    func testScenarioProcessesGetTheSocketAndThePermission() throws {
        XCTAssertTrue(try source("Sources/FTCore/ScenarioHost.swift")
            .contains("env[FMServeWire.socketEnvironmentKey] = FMServeHost.activeSocketPath"))
        XCTAssertTrue(try source("Sources/FTCore/ScenarioHost+Sandbox.swift")
            .contains("FMServeHost.activeSocketPath].compactMap"))
    }

    /// **LanguageModelSession を作ってよいのは決まったファイルだけ**。画像を伴う呼び出し(テキストの可視性検証・
    /// screenLooksLike・死活の確かめ)は常駐プロセスだけが撃つ —— シナリオのプロセスや常駐ヘルパーが各自
    /// セッションを作ると、モデルの載せ直しが絶えず起きて FM が死んだ(docs/maintainer-notes.md §81)
    func testOnlyTheFMProcessAndAuthoringToolsCreateSessions() throws {
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        var owners: Set<String> = []
        for case let path as String in FileManager.default.enumerator(atPath: sources.path)! where path.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            let code = text.components(separatedBy: "\n").map { line -> String in
                guard let comment = line.range(of: "//") else { return line }
                return String(line[..<comment.lowerBound])
            }.joined(separator: "\n")
            if code.contains("LanguageModelSession(") { owners.insert((path as NSString).lastPathComponent) }
        }
        XCTAssertEqual(owners, ["FMServeServer.swift",       // 画像を伴う実呼び出しの唯一の持ち主
                                "ScenarioNamer.swift",       // シナリオ作成時のテキスト(run の中では使わない)
                                "TestbaseDrafter.swift",     // テストベース作成時のテキスト(同上)
                                "FMLoadGenerator.swift"],    // 負荷計測の道具(run の中では使わない)
                       "セッションを作る場所が増えた/減った。画像を伴う呼び出しなら FMServeServer へ頼む形にする")
    }
}
