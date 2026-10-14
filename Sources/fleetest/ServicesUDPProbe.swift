// UDP の経路の確認の I/O(docs/remote-runner.md §17「UDP の経路の確認」)。判定・回数・文言は FTServices.UDPReachability。
// 親が 127.0.0.1 の公開ポートへ毎回変わるトークンを送り、エコーが同じ値を返すかを見る。

import Darwin
import FTServices
import Foundation

enum ServicesUDPProbe {
    /// 127.0.0.1:<port>/udp へ `attempts` 回まで送る。各回 `timeoutSeconds` 待ち、同じトークンが返れば届いた
    static func probeUDP(hostPort: Int, attempts: Int = UDPReachability.attempts,
                         timeoutSeconds: Double = UDPReachability.attemptTimeoutSeconds) -> UDPReachability.Outcome {
        for attempt in 1...max(attempts, 1) {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            setReceiveTimeout(fd, seconds: timeoutSeconds)
            var address = loopback(port: hostPort)
            let token = UUID().uuidString
            let sent = token.withCString { text in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, text, strlen(text), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = recvfrom(fd, &buffer, buffer.count, 0, nil, nil)
            if count > 0, UDPReachability.matches(sent: token, received: Data(buffer[..<count])) {
                return .reached(attempt: attempt)
            }
        }
        return .unreached(attempts: attempts)
    }

    /// 同じ経路の TCP(エコーの TCP 側)へ 1 回送って返事を見る。文言に「TCP は届いた」と書くための事実
    static func probeTCP(hostPort: Int, timeoutSeconds: Double = UDPReachability.attemptTimeoutSeconds) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        setReceiveTimeout(fd, seconds: timeoutSeconds)
        var sendTimeout = timeval(tv_sec: Int(timeoutSeconds), tv_usec: Int32((timeoutSeconds - Double(Int(timeoutSeconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        var address = loopback(port: hostPort)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return false }
        let token = UUID().uuidString + "\n"
        let sent = token.withCString { write(fd, $0, strlen($0)) }
        guard sent > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        return count > 0 && UDPReachability.matches(sent: token, received: Data(buffer[..<count]))
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(clamping: port).bigEndian
        return address
    }

    private static func setReceiveTimeout(_ fd: Int32, seconds: Double) {
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}
