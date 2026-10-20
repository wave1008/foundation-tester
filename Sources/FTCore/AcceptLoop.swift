// AcceptLoop.swift
// 待ち受けの fd と、それを accept する受付のスレッド。**待ち受けの fd を閉じるのは受付のスレッドだけ**。
// 別のスレッドが閉じると番号がすぐ再利用され、受付のスレッドの次の accept が無関係の待ち受けへの接続を奪う
// (BridgeRelay を並列で立て直すと 1600 回中 353 回、止めた中継が直後に立てた中継の接続を奪って閉じた)。
// stop() は起こして(wake の pipe)閉じ終わるのを待つ = 戻った時点で同じ番号・同じパスへ立て直せる。
// 待ち受けを持つ型(BridgeRelay・SandboxBroker・ServiceGatewayServer・ServicesGatewayForwarder)はここを通す
// (`AcceptLoopTests` が生の accept の再混入を落とす)

import Foundation

public final class AcceptLoop: Sendable {
    /// 受付のスレッドを起こす pipe の書き口(requestStop が閉じる = 読み口が EOF になる)。読み口は受付のスレッドが持つ
    private let wakeWrite: Int32
    /// 受付のスレッドが待ち受けを閉じ終えた印(stop() が待つ)
    private let closed = DispatchSemaphore(value: 0)
    private let stopRequested = LockedValue(false)

    /// `listener`: listen 済みの fd。**所有権を受け取る**(閉じるのは受付のスレッド。init が投げたときは呼び手が閉じる)。
    /// `onAccept`: 受けた接続ごとに受付のスレッドで呼ぶ。接続の所有権は渡る(閉じるのは onAccept 側)。false で受付をやめる
    public init(listener: Int32, name: String, onAccept: @escaping @Sendable (Int32) -> Bool) throws {
        var wake: [Int32] = [0, 0]
        guard pipe(&wake) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE) }
        // 非ブロッキング: poll の後に相手が消えても accept で止まり続けない(止まると stop() の待ちが返らない)
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        wakeWrite = wake[1]
        let wakeRead = wake[0]
        let closed = self.closed
        let thread = Thread { Self.run(listener: listener, wake: wakeRead, closed: closed, onAccept: onAccept) }
        thread.name = name
        thread.start()
    }

    /// 受付を止め、待ち受けが閉じ終わるまで待つ(何度呼んでもよい)。**受付・接続のスレッドの上からは呼ばない**
    /// (自分を待って詰まる。そこからは `requestStop`)
    public func stop() {
        requestStop()
        closed.wait()
        closed.signal()  // 2回目以降の stop() も返る
    }

    /// 起こすだけで待たない(deinit 等、受付・接続のスレッドの上で走りうる経路)
    public func requestStop() {
        stopRequested.withLock { requested in
            guard !requested else { return }
            requested = true
            close(wakeWrite)
        }
    }

    private static func run(listener: Int32, wake: Int32, closed: DispatchSemaphore,
                            onAccept: @Sendable (Int32) -> Bool) {
        defer {
            close(listener)
            close(wake)
            closed.signal()
        }
        var polls = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                     pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
        while true {
            polls[0].revents = 0
            polls[1].revents = 0
            guard poll(&polls, 2, -1) >= 0 else {
                if errno == EINTR { continue }
                return
            }
            if polls[1].revents != 0 { return }
            guard polls[0].revents != 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                // 受け付ける前に相手が切った接続(ECONNABORTED)で受付をやめない = 黙って止まる
                if errno == EINTR || errno == ECONNABORTED || errno == EAGAIN { continue }
                return
            }
            // 受けた接続は待ち受けの O_NONBLOCK を継ぐ(macOS)。受け手は止まって待つ読み書きなので外す
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            guard onAccept(client) else { return }
        }
    }
}
