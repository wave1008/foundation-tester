// 長寿命の補助プロセスとの通信の土台: Unix ドメインソケット + 長さ前置き(4 バイト big endian)の JSON 1 フレーム。
// 1 接続 = 1 要求 1 応答(使い切り)。使う側は Vision の補助(VisionHelper*.swift)と FM の常駐プロセス(FMServe*.swift)。
// POSIX の薄い包みだけを置く(要求・応答の型と期限は使う側が持つ)。

import Foundation

public enum FramedUnixSocket {
    /// 1 フレームの上限[バイト]。要求は PNG 1 枚(全画面でも数 MB)・応答は特徴量 1 つ(約 10 KB 台)か短い文字列。
    /// 32 MiB はそのどれよりも桁で大きい = 正常な要求は弾かず、壊れた長さ(読み違い)でメモリを食い尽くさない
    public static let maxFrameBytes = 32 * 1024 * 1024

    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        return framed
    }

    /// 先頭 4 バイトの長さ。上限を超える・4 バイトに満たなければ nil
    public static func payloadLength(header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let length = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard Int(length) <= maxFrameBytes else { return nil }
        return Int(length)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= maxFrameBytes else { throw FramedUnixSocketError.frameTooLarge }
        return frame(payload)
    }

    /// `encode` の逆(長さ前置きごと)。長さが実際の本体と食い違えば投げる
    public static func decode<T: Decodable>(_ type: T.Type, fromFrame data: Data) throws -> T {
        guard let length = payloadLength(header: data.prefix(4)), data.count == 4 + length else {
            throw FramedUnixSocketError.malformedFrame
        }
        return try JSONDecoder().decode(type, from: data.dropFirst(4))
    }

    static var sunPathCapacity: Int { MemoryLayout.size(ofValue: sockaddr_un().sun_path) }

    /// sun_path(104 バイト)に収まるか。収まらないパスでは補助を起こさない
    public static func fitsSunPath(_ path: String) -> Bool { path.utf8.count < sunPathCapacity }

    static func withAddress<R>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < sunPathCapacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func setTimeouts(_ fd: Int32, seconds: Double) {
        let whole = Int(seconds)
        var timeout = timeval(tv_sec: whole, tv_usec: Int32((seconds - Double(whole)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// ちょうど `count` バイト読む。EOF・タイムアウト・`deadline` 超過は nil
    static func readExactly(_ fd: Int32, count: Int, deadline: Date) -> Data? {
        var data = Data(count: count)
        var received = 0
        while received < count {
            guard Date() < deadline else { return nil }
            let n = data.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress!.advanced(by: received), count - received)
            }
            if n > 0 { received += n; continue }
            if n < 0, errno == EINTR { continue }
            return nil
        }
        return data
    }

    /// 長さ前置きの 1 フレームの本体を読む。長さが上限を超えれば nil
    static func readPayload(_ fd: Int32, deadline: Date) -> Data? {
        guard let header = readExactly(fd, count: 4, deadline: deadline),
              let length = payloadLength(header: header) else { return nil }
        if length == 0 { return Data() }
        return readExactly(fd, count: length, deadline: deadline)
    }

    static func writeAll(_ fd: Int32, _ data: Data, deadline: Date) -> Bool {
        var sent = 0
        while sent < data.count {
            guard Date() < deadline else { return false }
            let n = data.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: sent), data.count - sent)
            }
            if n > 0 { sent += n; continue }
            if n < 0, errno == EINTR { continue }
            return false
        }
        return true
    }

    /// 繋いで 1 フレーム送り、1 フレーム受け取る(ブロッキング。呼び手が協調スレッドプールの外で呼ぶ)。
    /// 期限は接続・送信・受信の全体に掛かる。失敗は `.unavailable`(繋がらない・答えない・期限切れ)
    static func exchange(path: String, frame: Data, seconds: Double) throws -> Data {
        let deadline = Date().addingTimeInterval(seconds)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FramedUnixSocketError.unavailable("socket: errno \(errno)") }
        defer { close(fd) }
        setTimeouts(fd, seconds: seconds)
        // connect だけは SO_SNDTIMEO が効かないので、非ブロッキングで繋いで poll で期限を置く
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let connected = withAddress(path: path) { address, length in connect(fd, address, length) }
        guard let connected else { throw FramedUnixSocketError.unavailable("socket path too long") }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else {
                throw FramedUnixSocketError.unavailable("connect: errno \(errno)")
            }
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollFD, 1, Int32(seconds * 1000)) == 1 else {
                throw FramedUnixSocketError.unavailable("connect timed out")
            }
            var soError: Int32 = 0
            var soLength = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLength)
            guard soError == 0 else { throw FramedUnixSocketError.unavailable("connect: errno \(soError)") }
        }
        _ = fcntl(fd, F_SETFL, flags)
        guard writeAll(fd, frame, deadline: deadline) else {
            throw FramedUnixSocketError.unavailable("the request could not be written")
        }
        guard let payload = readPayload(fd, deadline: deadline) else {
            throw FramedUnixSocketError.unavailable("no answer within \(seconds) seconds")
        }
        return payload
    }

    /// `exchange` を協調スレッドプールの外(GCD)で回して待つ
    static func exchangeAsync(path: String, frame: Data, seconds: Double) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try exchange(path: path, frame: frame, seconds: seconds) })
            }
        }
    }

    /// 同期スレッドから async を呼んで待つ。`UncheckedTransfer` の根拠: 値は Task の中で作られ、semaphore の後に
    /// 1 度だけ読まれる(同時に触る者は居ない)
    static func blocking<T>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedValue<UncheckedTransfer<T>?>(nil)
        Task.detached {
            let value = await body()
            box.withLock { $0 = UncheckedTransfer(value) }
            semaphore.signal()
        }
        semaphore.wait()
        return box.withLock { $0 }!.value
    }

    /// 1 接続 1 要求の受け付けループ。終わるまで戻らない(戻り値 = 終了コード)。
    /// - 要求は**接続ごとに GCD のスレッドで並行に**捌く(並行の度合いは呼び手の側の枠が決める = FMCallSlots)
    /// - `onTick` は accept 待ちの合間に `tickMilliseconds` ごと呼ぶ(暖機・寿命の判断。accept のスレッドで呼ぶ)
    /// - 同じパスに生きた持ち主が居れば起きない(1 を返す)。死んだ残骸は消して取る。ソケットは 0600・終了時に消す
    public static func serve(socketPath: String, requestDeadlineSeconds: Double, tickMilliseconds: Int32,
                             shouldStop: @escaping @Sendable () -> Bool, onTick: () -> Void,
                             handle: @escaping @Sendable (Data) async -> Data?,
                             log: @escaping @Sendable (String) -> Void) -> Int32 {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // **1 つのパスに持ち主は 1 つ**: 「繋がるか」を見てから消して bind する間に、同時に起きた2つ目が先の持ち主の
        // ソケットファイルを消すと、先の持ち主は誰からも届かない孤児になる。生きている間ずっと flock を握って防ぐ
        // (プロセスが死ねば OS が放す = 残骸のロックは残らない)
        let lockFD = open(socketPath + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }
            log("another process owns \(socketPath)")
            return 1
        }
        defer { close(lockFD) }
        if isServed(path: socketPath) {
            log("a live process already serves \(socketPath)")
            return 1
        }
        unlink(socketPath)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { log("socket: errno \(errno)"); return 1 }
        defer { close(listener); unlink(socketPath) }
        let bound = withAddress(path: socketPath) { bind(listener, $0, $1) } ?? -1
        guard bound == 0 else { log("bind \(socketPath): errno \(errno)"); return 1 }
        chmod(socketPath, 0o600)
        guard listen(listener, 32) == 0 else { log("listen: errno \(errno)"); return 1 }
        while !shouldStop() {
            autoreleasepool { onTick() }
            var pollFD = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, tickMilliseconds) > 0 else { continue }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    defer { close(connection) }
                    // 要求ごとの期限(読めない・遅いクライアントにスレッドを握らせない)
                    setTimeouts(connection, seconds: requestDeadlineSeconds)
                    let deadline = Date().addingTimeInterval(requestDeadlineSeconds)
                    guard let payload = readPayload(connection, deadline: deadline) else { return }
                    guard let answer = blocking({ await handle(payload) }) else { return }
                    // 書き込みの期限は処理の後から数え直す(処理に期限いっぱい使った応答も届ける)
                    _ = writeAll(connection, frame(answer), deadline: Date().addingTimeInterval(5))
                }
            }
        }
        return 0
    }

    /// そのパスに繋がる(= 生きた持ち主が居る)か
    static func isServed(path: String) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        return (withAddress(path: path) { connect(probe, $0, $1) } ?? -1) == 0
    }
}

public enum FramedUnixSocketError: Error, CustomStringConvertible {
    /// 繋がらない・答えない・期限切れ(`detail` に事実)
    case unavailable(String)
    case frameTooLarge
    case malformedFrame

    public var description: String {
        switch self {
        case .unavailable(let detail): return "the helper process is unavailable (\(detail))"
        case .frameTooLarge: return "the helper frame is larger than the limit"
        case .malformedFrame: return "the helper frame is malformed"
        }
    }
}
