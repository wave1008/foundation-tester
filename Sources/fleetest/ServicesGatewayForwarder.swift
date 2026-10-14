// Apple Container のコンテナ → 親のプロキシの道(docs/remote-runner.md §17「ネットワーク」)。
// 内部ネットワークのゲートウェイの IP で待ち受け、127.0.0.1 の run 専用プロキシへそのまま流す TCP の転送器。
// **BSD ソケットで待ち受ける**: Network.framework の NWListener は vmnet のブリッジ(bridge1xx)上のアドレスに bind できない
// (`Can't assign requested address` が続く。実測)が、BSD の bind は通り、コンテナから届く(実測)。
// 方針の判定(allowedDomains・解決した IP の検め)は転送先のプロキシが行う。ここは配管だけ。

import Darwin
import FTCore
import Foundation

// @unchecked: 格納プロパティは不変。可変は `stopped` の LockedValue だけ
final class ServicesGatewayForwarder: @unchecked Sendable {
    let listenAddress: String
    let listenPort: UInt16
    private let targetPort: UInt16
    private let descriptor: Int32
    private let stopped = LockedValue(false)
    /// 中継中の接続(client の fd)。`stop()` が全部 shutdown する(待ち受けだけ閉じても中継中の pump は残る)
    private let active = LockedValue<Set<Int32>>([])

    /// 1 回の read の上限(バイト)。根拠: ソケットの既定のバッファと同じ桁で、プロキシ経由の応答(数十 KB)を数回で運ぶ
    private static let chunkBytes = 64 * 1024

    /// `listenAddress:listenPort` で待ち受け、受けた接続を `127.0.0.1:targetPort` へつなぐ。bind できなければ throw
    /// (ゲートウェイの IP は最初のコンテナが付くまで無い = 呼び手が試し続ける)
    init(listenAddress: String, listenPort: UInt16, targetPort: UInt16) throws {
        self.listenAddress = listenAddress
        self.listenPort = listenPort
        self.targetPort = targetPort
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = listenPort.bigEndian
        guard inet_pton(AF_INET, listenAddress, &address.sin_addr) == 1 else {
            close(fd)
            throw POSIXError(.EINVAL)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        descriptor = fd
        let stoppedBox = stopped
        let activeBox = active
        let target = targetPort
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                let accepted = stoppedBox.withLock { isStopped -> Bool in
                    if isStopped { return false }
                    activeBox.withLock { _ = $0.insert(client) }
                    return true
                }
                guard accepted else { close(client); return }
                Thread.detachNewThread {
                    Self.serve(client, targetPort: target)
                    activeBox.withLock { _ = $0.remove(client) }
                }
            }
        }
    }

    func stop() {
        let clients = stopped.withLock { isStopped -> Set<Int32> in
            isStopped = true
            return active.value
        }
        // shutdown で accept を起こしてから閉じる(close だけでは待っているスレッドが戻らない)。中継中の接続も起こす
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        for client in clients { shutdown(client, SHUT_RDWR) }
    }

    /// 両方向の pump が終わるまで閉じない(片方の EOF は相手へ half-close で伝える = リクエストの後に書き側を閉じる
    /// クライアントでも応答が届く)。閉じるのは最後に1回
    private static func serve(_ client: Int32, targetPort: UInt16) {
        var noSigpipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        let upstream = socket(AF_INET, SOCK_STREAM, 0)
        guard upstream >= 0 else { close(client); return }
        setsockopt(upstream, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = targetPort.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { close(upstream); close(client); return }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { pump(from: client, to: upstream); done.signal() }
        Thread.detachNewThread { pump(from: upstream, to: client); done.signal() }
        done.wait()
        done.wait()
        close(client); close(upstream)
    }

    private static func pump(from source: Int32, to sink: Int32) {
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { shutdown(sink, SHUT_WR); return }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { write(sink, $0.baseAddress! + offset, count - offset) }
                if written < 0, errno == EINTR { continue }
                // 書けない(相手が閉じた)= 読む側も要らない。source を shutdown してもう片方の pump も終わらせる
                guard written > 0 else { shutdown(source, SHUT_RDWR); return }
                offset += written
            }
        }
    }
}
