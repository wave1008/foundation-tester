// ServiceGateway.swift
// サンドボックスの中の run-setup.sh / run-teardown.sh が、宣言したサービスでの exec・状態・ログ・公開ポートの照会を
// 親へ頼む口(docs/remote-runner.md §17 スクリプト ④)。`SandboxBroker` の1往復と違い**ストリーム**:
// 標準入力・標準出力・標準エラーを行区切りの JSON フレームで流す(巨大なダンプが 1 MiB の要求に載らないため)。
// 判定は `ServiceGatewayPolicy`(FTServices の `ServicePolicy` が実装)。ここは配管だけで、何を実行するかは決めない。
//
// ワイヤ(UTF-8・1行 = 1 JSON・`\n` 区切り。対向は同じファイルの `ServiceGatewayClient`):
//   client → server 最初の1行 {"v":1,"argv":[…]}
//   server → client 次の1行   {"ok":true} / {"refused":"理由"}
//   以降 server → client {"o":b64} {"e":b64} … 最後に {"status":Int}
//        client → server {"i":b64} … {"i":null}(stdin の EOF)
import Foundation

public enum ServiceGatewayDecision: Sendable, Equatable {
    case refused(String)
    /// `argv` は /usr/bin/env に渡す完全な引数列(先頭に NAME=VALUE が並びうる)。stdin = 要求側の標準入力を子へ流すか
    case run(argv: [String], stdin: Bool)
    /// 親が何も実行せずに答える本文(末尾の改行は server が足す)
    case text(String)
}

public protocol ServiceGatewayPolicy: Sendable {
    func decide(_ request: [String]) -> ServiceGatewayDecision
}

public enum ServiceGatewayWire {
    public static let environmentKey = "FT_SERVICES_GATEWAY"
    /// 中継コマンドの実行ファイル名(= Package.swift の executableTarget 名)。**唯一の定義元** —— 同期相手は
    /// `RemoteSetup.alignRevisionCommand`(ランナー機でビルドする製品の一覧。無いとランナーの run-setup.sh から
    /// `fleetest-services: command not found` = M1Ultra の実測)と `RunHookRunner.gatewayToolDirectory`(隣に居るかの確認)
    public static let relayProductName = "fleetest-services"
    /// 断られたときの終了コード(シェルの「実行できない」と同じ 126)
    public static let refusedStatus: Int32 = 126
    /// 1フレームの生データの上限(バイト)。根拠: パイプの PIPE_BUF を超える書き込みでも1回の write に収まる大きさで、
    /// 1フレームあたりのメモリの上限。尽きたとき = 送り手が分割する
    public static let maxFrameBytes = 64 * 1024
    public static let protocolVersion = 1
    /// 1行の長さの上限(バイト)。base64 で 4/3 に膨らんだ `maxFrameBytes` が余裕で収まる。超えた行は壊れた接続として閉じる
    static let maxLineBytes = 1 << 20
    /// 要求側が死んだ・親が止まるときの SIGTERM から SIGKILL までの猶予(秒)。根拠: 後始末を持たない外部プロセスへの
    /// 時限 SIGKILL の方針(process-lifecycle.md の 2 秒)
    static let killGraceSeconds: Double = 2.0
}

// MARK: - 共通部品

/// 持ち越しのあるバッファ付き行読み。`UnixSocket.readLine` は改行より後ろの読みを捨てるので、
/// 複数行が続くストリームには使えない。**1本のスレッドからしか読まない**(読み手を引き継ぐときは順に渡す)
final class GatewayLineReader: @unchecked Sendable {
    private let fd: Int32
    private var buffer: [UInt8] = []
    private var searched = 0
    private var scratch = [UInt8](repeating: 0, count: 65536)

    init(fd: Int32) { self.fd = fd }

    /// 改行までの1行(改行は含まない)。EOF・読み取りエラー・`limit` 超過は nil(途中の行は捨てる)
    func readLine(limit: Int) -> Data? {
        while true {
            if let newline = buffer[searched...].firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                searched = 0
                return line
            }
            searched = buffer.count
            if buffer.count > limit { return nil }
            let count = scratch.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: scratch[..<count])
        }
    }

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}

/// ソケットへの書き込み口。**書き込みは lock で直列化**(stdout / stderr / 状態の各スレッドが同じ fd へ書く)。
/// `shutdown()` は lock を取らない —— 書き込みが相手の読み待ちでブロックしている間に起こすため
// @unchecked: sealed / closed は lock の下でだけ触る・fd は不変
final class GatewayChannel: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var sealed = false
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    }

    /// false = 書けなかった(封印後・閉じた後・相手が居ない)
    @discardableResult
    func send(_ object: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if sealed || closed { return false }
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// 以後の書き込みを全部断る(最後の `status` の後に遅れて来た出力が流れないように)
    func seal() { lock.lock(); sealed = true; lock.unlock() }

    func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }

    /// **この fd を読むスレッドが全部抜けてから呼ぶ**(閉じた番号は再利用され、読み手が無関係な fd を読む)
    func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed { closed = true; Darwin.close(fd) }
    }
}

// MARK: - 親側

// @unchecked: 格納プロパティは不変(`policy` / `log` は Sendable)。可変状態は `state` の LockedValue の中だけ
public final class ServiceGatewayServer: @unchecked Sendable {
    public let socketPath: String
    private let policy: any ServiceGatewayPolicy
    private let log: @Sendable (String) -> Void
    private let descriptor: Int32

    private struct State {
        var children: Set<pid_t> = []
        var clients: Set<Int32> = []
        var stopped = false
    }
    private let state = LockedValue(State())

    /// ソケットは `directory/ftg-<uuid 先頭8桁>.sock`(0600 = `UnixSocket.listen`)。`log` は拒否と異常を親のログへ出す
    public init(policy: any ServiceGatewayPolicy, directory: String,
                log: @escaping @Sendable (String) -> Void) throws {
        self.policy = policy
        self.log = log
        socketPath = (directory as NSString).appendingPathComponent("ftg-\(UUID().uuidString.prefix(8)).sock")
        descriptor = try UnixSocket.listen(path: socketPath)
        let thread = Thread { [descriptor, weak self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                guard let self else { close(client); return }
                let accepted = self.state.withLock { state -> Bool in
                    if state.stopped { return false }
                    state.clients.insert(client)
                    return true
                }
                guard accepted else { close(client); continue }
                Thread.detachNewThread { self.serve(client) }
            }
        }
        thread.name = "fleetest-services-gateway"
        thread.start()
    }

    /// テスト用: いま動いている子の数
    public var activeChildCount: Int { state.withLock { $0.children.count } }

    /// 待受を閉じ、動いている子を止める(SIGTERM → 猶予後 SIGKILL)。2回目以降は何もしない
    public func stop() {
        let first = state.withLock { state -> Bool in
            if state.stopped { return false }
            state.stopped = true
            // 要求を待っているだけの接続も起こす(読み手が EOF で抜ける)
            for client in state.clients { shutdown(client, SHUT_RDWR) }
            return true
        }
        guard first else { return }
        // shutdown で accept を起こしてから閉じる(close だけでは待っているスレッドが戻らない)
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(socketPath)
        signalChildren(SIGTERM)
        let deadline = Date().addingTimeInterval(ServiceGatewayWire.killGraceSeconds)
        while activeChildCount > 0, Date() < deadline { usleep(20_000) }
        if activeChildCount > 0 { signalChildren(SIGKILL) }
    }

    private func signalChildren(_ signal: Int32) {
        state.withLock { for pid in $0.children { killpg(pid, signal) } }
    }

    private func serve(_ client: Int32) {
        let channel = GatewayChannel(fd: client)
        defer {
            state.withLock { _ = $0.clients.remove(client) }
            channel.close()
        }
        let reader = GatewayLineReader(fd: client)
        guard let line = reader.readLine(limit: ServiceGatewayWire.maxLineBytes),
              let object = GatewayLineReader.object(line),
              let version = object["v"] as? Int,
              let argv = object["argv"] as? [String] else {
            channel.send(["refused": "malformed request"])
            return
        }
        guard version == ServiceGatewayWire.protocolVersion else {
            channel.send(["refused": "protocol version \(version) is not supported"])
            return
        }
        switch policy.decide(argv) {
        case let .refused(reason):
            log("services gateway: refused \(argv.joined(separator: " ")) — \(reason)")
            channel.send(["refused": reason])
        case let .text(body):
            channel.send(["ok": true])
            channel.send(["o": Data((body + "\n").utf8).base64EncodedString()])
            channel.send(["status": 0])
        case let .run(command, stdin):
            channel.send(["ok": true])
            execute(command, stdin: stdin, channel: channel, reader: reader)
        }
    }

    private func execute(_ command: [String], stdin wantsStdin: Bool,
                         channel: GatewayChannel, reader: GatewayLineReader) {
        // スクリプトの要求から届く引数(起こすと gateway を抱える親の run ごと abort する)
        if let index = ProcessArguments.firstNULIndex(command) {
            channel.send(["e": Data("refused: \(ProcessArguments.nulRefusal(index: index))\n".utf8).base64EncodedString()])
            channel.send(["status": Int(ServiceGatewayWire.refusedStatus)])
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        let stdinPipe = wantsStdin ? Pipe() : nil
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let waitExit = ProcessExitWait.prepareTimed(process)  // 契約: run() より前に設定
        do {
            try process.run()
        } catch {
            log("services gateway: could not start \(command.joined(separator: " ")): \(error.localizedDescription)")
            channel.send(["e": Data("could not start \(command.first ?? "the command"): \(error.localizedDescription)\n".utf8).base64EncodedString()])
            channel.send(["status": 127])
            channel.shutdown()
            return
        }
        let pid = process.processIdentifier
        let alreadyStopped = state.withLock { state -> Bool in
            state.children.insert(pid)
            return state.stopped
        }
        let terminatedAt = LockedValue<Date?>(nil)
        let finished = LockedValue(false)
        /// 子ごと止める。登録が残っている間だけ撃つ(回収済みの pgid へは撃たない)
        let terminate: @Sendable () -> Void = { [state] in
            terminatedAt.withLock { if $0 == nil { $0 = Date() } }
            state.withLock { if $0.children.contains(pid) { killpg(pid, SIGTERM) } }
        }
        if alreadyStopped { terminate() }

        // stdin ポンプ。EOF を過ぎてもソケットを読み続ける(要求側の死を EOF で知る)
        let stdinHandle = stdinPipe?.fileHandleForWriting
        if let stdinHandle { _ = fcntl(stdinHandle.fileDescriptor, F_SETNOSIGPIPE, 1) }
        let pumpDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var stdinOpen = stdinHandle != nil
            func closeStdin() {
                guard stdinOpen else { return }
                stdinOpen = false
                try? stdinHandle?.close()
            }
            defer { closeStdin(); pumpDone.signal() }
            while true {
                guard let line = reader.readLine(limit: ServiceGatewayWire.maxLineBytes),
                      let frame = GatewayLineReader.object(line), frame.keys.contains("i") else {
                    // EOF か壊れた行: 完了前なら要求側が死んだ = スクリプトが止められたので、子を残さない
                    if !finished.value { terminate() }
                    return
                }
                if frame["i"] is NSNull {
                    closeStdin()
                } else if let encoded = frame["i"] as? String, let data = Data(base64Encoded: encoded) {
                    // 子が読まないと block する = 背圧。子が先に死んでいれば EPIPE で書けなくなるだけ
                    guard stdinOpen, let fd = stdinHandle?.fileDescriptor else { continue }
                    data.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                            if written < 0, errno == EINTR { continue }
                            guard written > 0 else { return }
                            offset += written
                        }
                    }
                } else {
                    if !finished.value { terminate() }
                    return
                }
            }
        }

        let outDone = streamOutput(outPipe.fileHandleForReading, key: "o", channel: channel, terminate: terminate)
        let errDone = streamOutput(errPipe.fileHandleForReading, key: "e", channel: channel, terminate: terminate)

        // 終了は終了通知で待つ(出力の EOF とは独立)。止める要求から猶予を過ぎたら SIGKILL
        while waitExit(.now() + 0.2) == .timedOut {
            if let at = terminatedAt.value, Date().timeIntervalSince(at) >= ServiceGatewayWire.killGraceSeconds {
                state.withLock { if $0.children.contains(pid) { killpg(pid, SIGKILL) } }
            }
        }
        // 孫が書込端を握っていても EOF を待ち切らない。尽きたら残りを SIGKILL して、もう一度だけ待つ
        var deadline: DispatchTime = .now() + Shell.outputDrainGraceSeconds
        var drained = outDone.wait(timeout: deadline) == .success
        drained = (errDone.wait(timeout: deadline) == .success) && drained
        if !drained {
            killpg(pid, SIGKILL)
            deadline = .now() + Shell.outputDrainGraceSeconds
            _ = outDone.wait(timeout: deadline)
            _ = errDone.wait(timeout: deadline)
        }
        // 残った子孫を残さない(空のグループへは ESRCH で何も起きない)
        killpg(pid, SIGKILL)
        state.withLock { _ = $0.children.remove(pid) }

        let status = process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus : process.terminationStatus
        finished.value = true
        channel.send(["status": Int(status)])
        channel.seal()
        // ポンプを起こして抜けさせてから閉じる(`serve` の defer)
        channel.shutdown()
        pumpDone.wait()
    }

    /// パイプを読み切るまでフレームにして流す。EOF で signal する
    private func streamOutput(_ handle: FileHandle, key: String, channel: GatewayChannel,
                              terminate: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var peerGone = false
            while true {
                // availableData は届いた分だけ返す。1回ごとに解放の区切り(自動解放の NSData が抜けないループで溜まる)
                let eof: Bool = autoreleasepool {
                    let chunk = handle.availableData
                    if chunk.isEmpty { return true }
                    var offset = chunk.startIndex
                    while offset < chunk.endIndex {
                        let end = min(offset + ServiceGatewayWire.maxFrameBytes, chunk.endIndex)
                        if !channel.send([key: chunk[offset..<end].base64EncodedString()]), !peerGone {
                            // 書けない = 要求側が居ない。子は止めるが、パイプは読み切って子を詰まらせない
                            peerGone = true
                            terminate()
                        }
                        offset = end
                    }
                    return false
                }
                if eof { break }
            }
            done.signal()
        }
        return done
    }
}

// MARK: - 要求側

/// 中継コマンド(`fleetest-services`)の本体
public enum ServiceGatewayClient {
    /// 終了コードを返す(0〜255、断られたら 126)。`out` / `err` は fd 1 / 2 へ書く差し替え口(呼ばれるのは呼び出しスレッドだけ)。
    /// `stdin` はハンドルの fd を `read(2)` で読む(`availableData` は通常ファイルを一度に全部返す)
    public static func run(arguments: [String], environment: [String: String],
                           stdin: FileHandle = .standardInput, stdinIsTerminal: Bool = isatty(0) != 0,
                           out: (Data) -> Void, err: (Data) -> Void) -> Int32 {
        let refused = ServiceGatewayWire.refusedStatus
        func fail(_ message: String) -> Int32 {
            err(Data("fleetest-services: \(message)\n".utf8))
            return refused
        }
        guard let path = environment[ServiceGatewayWire.environmentKey], !path.isEmpty else {
            return fail("no services gateway is available — either this run declares no services"
                + " (scripts/compose.yaml is absent) or the command is running outside a fleetest setup/teardown script")
        }
        guard let fd = try? UnixSocket.connect(path: path) else {
            return fail("cannot reach the fleetest gateway at \(path)")
        }
        let channel = GatewayChannel(fd: fd)
        defer { channel.shutdown(); channel.close() }
        let reader = GatewayLineReader(fd: fd)
        let closedMessage = "the fleetest gateway closed the connection"

        guard channel.send(["v": ServiceGatewayWire.protocolVersion, "argv": arguments]) else {
            return fail(closedMessage)
        }
        guard let first = reader.readLine(limit: ServiceGatewayWire.maxLineBytes),
              let answer = GatewayLineReader.object(first) else {
            return fail(closedMessage)
        }
        if let reason = answer["refused"] as? String { return fail("refused — \(reason)") }
        guard answer["ok"] as? Bool == true else { return fail("unexpected response from the fleetest gateway") }

        if stdinIsTerminal {
            channel.send(["i": NSNull()])
        } else {
            let source = stdin.fileDescriptor
            Thread.detachNewThread { [stdin] in
                withExtendedLifetime(stdin) {
                    var buffer = [UInt8](repeating: 0, count: ServiceGatewayWire.maxFrameBytes)
                    while true {
                        let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
                        if count < 0, errno == EINTR { continue }
                        if count <= 0 { break }
                        if !channel.send(["i": Data(buffer[..<count]).base64EncodedString()]) { return }
                    }
                    channel.send(["i": NSNull()])
                }
            }
        }

        while let line = reader.readLine(limit: ServiceGatewayWire.maxLineBytes) {
            guard let frame = GatewayLineReader.object(line) else { break }
            if let encoded = frame["o"] as? String, let data = Data(base64Encoded: encoded) {
                out(data)
            } else if let encoded = frame["e"] as? String, let data = Data(base64Encoded: encoded) {
                err(data)
            } else if let status = frame["status"] as? Int {
                return Int32(max(0, min(255, status)))
            }
        }
        return fail(closedMessage)
    }
}
