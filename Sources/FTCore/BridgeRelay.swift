// LAN の先にあるブリッジ(Wi-Fi で繋いだ iOS 実機)への、親が立てる TCP の中継。
// シナリオの子は Seatbelt の中で `localhost` にしか出られない。Seatbelt のアドレス条件はホストに `*` か `localhost`
// しか書けないので、実機の IP へ直接出すにはポート番号で `*:<port>` を開けるしかなく、そのポートなら任意のホストへ
// 出られた(docs/spec-defects.md の 4)。中継は `127.0.0.1:<実機と同じポート>` で待ち受け、届いた接続を
// **決めた1つの宛先にだけ**つなぐ。子からは USB トンネル(iproxy)と同じ形に見える ——
// **待ち受けのポートを実機と同じ番号にする理由**: 子の BridgeClient は実機の認証トークンを
// `.fleetest/bridge-<port>.endpoint` からポート番号で引く(`BridgeClient.inferredToken`)。別の番号にすると 401 になる。
// 寿命はシナリオ1本(ScenarioHost.run が子の起動前に立て、子の終了後に止める)。

import Foundation

public final class BridgeRelay: @unchecked Sendable {
    // 不変条件: `sockets` と `stopped` は lock の内側でだけ読み書きする。stop() の後は新しい接続を受けない。
    // `acceptor` は init の中で1回だけ書き、以後は読むだけ。
    // **fd を閉じるのは、その fd で待っているスレッドだけ**(待ち受け = AcceptLoop の受付のスレッド・中継中の接続 =
    // 2本のポンプの後に終わった方)。別のスレッドが閉じると番号がすぐ再利用され、待っていた側が次の read / write で
    // 無関係のソケットを掴む。中継中の接続について stop() は shutdown で起こすだけ(待ち受けは AcceptLoop.stop が閉じ終わるまで待つ)
    private let lock = NSLock()
    private var sockets: Set<Int32> = []
    private var stopped = false
    private var acceptor: AcceptLoop?
    private let target: sockaddr_storage
    private let targetLength: socklen_t
    /// 待ち受けているポート(listenPort に 0 を渡したときは割り当てられた番号)
    public let port: UInt16

    /// `targetHost` は数値の IP か名前(親が1回だけ解決する)。待ち受けは 127.0.0.1 だけ(外から繋がせない)。
    /// 取れなければ投げる(呼び手は子を起こさずに断る = 中継なしで黙って走らせない)
    public init(listenPort: UInt16, targetHost: String, targetPort: UInt16) throws {
        (target, targetLength) = try Self.resolve(host: targetHost, port: targetPort)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // シナリオごとに同じ番号で立て直すので、前の中継が残した TIME_WAIT で bind を落とさない。
        // SO_REUSEPORT は付けない(付けると別の待ち受けと同じ番号を共有できてしまう)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = listenPort.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE
            close(fd)
            throw POSIXError(code)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: actual.sin_port)
        // 受付は中継を弱く持つ(強く持つと stop() を呼ばない限り解放されず、deinit の後始末が走らない)。
        // 中継が居ない回(手放した後)は接続を閉じて受付を続ける = 起こすのは deinit の requestStop
        do {
            acceptor = try AcceptLoop(listener: fd, name: "fleetest.bridge-relay.\(port)") { [weak self] client in
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                guard let self else { close(client); return true }
                guard self.track(client) else { close(client); return false }
                // 宛先への接続は受付の外で(届かない実機への connect は待ちが長く、その間ほかの接続を受けられなくなる)
                Thread { [weak self] in
                    if let self { self.relay(client) } else { close(client) }
                }.start()
                return true
            }
        } catch {
            close(fd)
            throw error
        }
    }

    /// **待たない** —— 最後の参照が受付・中継のスレッドの一時的な参照なら deinit はそのスレッドの上で走り、待つと自分を待って詰まる
    deinit {
        stopRelaying()
        acceptor?.requestStop()
    }

    /// 待ち受けと中継中の接続を止め、待ち受けが閉じ終わるまで待つ(何度呼んでもよい。戻った時点で同じ番号へ立て直せる)
    public func stop() {
        stopRelaying()
        acceptor?.stop()
    }

    private func stopRelaying() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        // lock の内側で shutdown する = ポンプが閉じた(sockets から外した)番号には触らない
        for socket in sockets { shutdown(socket, SHUT_RDWR) }
    }

    /// 中継中の1本の接続の、2本のポンプが両方終わったか(後に終わった方が閉じる)
    private final class PumpPair: Sendable {
        private let finished = LockedValue(0)
        /// true = 自分が後に終わった
        func finishOne() -> Bool { finished.withLock { $0 += 1; return $0 == 2 } }
    }

    private func relay(_ client: Int32) {
        let upstream = connectUpstream()
        guard upstream >= 0, track(upstream) else {
            if upstream >= 0 { close(upstream) }
            forget(client)
            close(client)
            return
        }
        // 片方向ずつ1本のスレッド。片方が終われば両方を shutdown して相手の読みを起こし、両方終わってから閉じる
        let pair = PumpPair()
        for (from, to) in [(client, upstream), (upstream, client)] {
            let pump = Thread { [weak self] in
                Self.pump(from: from, to: to)
                shutdown(client, SHUT_RDWR)
                shutdown(upstream, SHUT_RDWR)
                guard pair.finishOne() else { return }
                self?.forget(client)
                self?.forget(upstream)
                close(client)
                close(upstream)
            }
            pump.start()
        }
    }

    private func connectUpstream() -> Int32 {
        var storage = target
        let fd = socket(Int32(storage.ss_family), SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, targetLength) }
        }
        guard result == 0 else { close(fd); return -1 }
        return fd
    }

    /// false = 止めた後なので受け付けない
    private func track(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        sockets.insert(fd)
        return true
    }

    /// 閉じる直前に一覧から外す(外した後は stop() が触らない = 閉じた番号が再利用されても shutdown しない)
    private func forget(_ fd: Int32) {
        lock.lock()
        sockets.remove(fd)
        lock.unlock()
    }

    private static func pump(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { write(to, $0.baseAddress! + offset, count - offset) }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    static func resolve(host: String, port: UInt16) throws -> (sockaddr_storage, socklen_t) {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
            throw POSIXError(.EHOSTUNREACH)
        }
        defer { freeaddrinfo(result) }
        var storage = sockaddr_storage()
        let length = first.pointee.ai_addrlen
        withUnsafeMutableBytes(of: &storage) { raw in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: first.pointee.ai_addr, count: Int(length)))
        }
        return (storage, length)
    }
}
