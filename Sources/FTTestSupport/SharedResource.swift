// テスト専用の資源ロック(production からは import しない。Package.swift の products に
// 出していない = 受け手のパッケージへは公開されない)。
//
// 対象は「隔離できないホストの実体」(simctl / adb / 起動中の Simulator・Emulator / 固定パス)。
// 隔離できる資源(例: FMBreaker の状態ファイル)は差し替え口でテストごとの一時パスへ逃がすのが
// 上位の手段 —— それができないときの最終手段としてここへ来る(CLAUDE.md の方針の階層)。
//
// flock(2) を選ぶ理由: プロセス死で OS がロックを自動解放する。存在チェック方式の
// ロックファイル(作る/消す/exists で見る)だと、テストが panic/crash した回にファイルが
// 残留し、以降の全実行が無期限に止まる。flock は fd を握るプロセスが死ねばカーネルが片付ける。

import Foundation

public struct SharedResource: Sendable {
    public let key: String

    /// simctl / CoreSimulator / 起動中のシミュレータ
    public static let iosSimulatorHost = SharedResource(key: "ios-simulator-host")
    /// adb / emulator gRPC
    public static let androidEmulatorHost = SharedResource(key: "android-emulator-host")
    /// ~/Library/Caches/ftester 配下(隔離できないときの受け皿)
    public static let hostCaches = SharedResource(key: "host-caches")

    private init(key: String) {
        self.key = key
    }

    public struct LockError: Error, CustomStringConvertible {
        public let description: String
    }

    private static let timeoutSeconds: TimeInterval = 120
    private static let pollIntervalMicroseconds: useconds_t = 50_000  // 同期待ち(usleep)
    private static let pollIntervalNanoseconds: UInt64 = 50_000_000   // 非同期待ち(Task.sleep)

    private static let lockDirectory: URL =
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ftester-test-locks", isDirectory: true)

    private var lockFileURL: URL {
        Self.lockDirectory.appendingPathComponent("\(key).lock")
    }

    // MARK: - 再入検出(プロセス内・スレッド単位)
    //
    // flock は open file description 単位の排他なので、同一スレッドが同じキーを入れ子で
    // locked{} すると、外側が fd1 で握ったまま内側が fd2 で LOCK_EX を試みて**自分自身と
    // デッドロック**する(OS はこれを検出しない。放置すると 120 秒待って謎のタイムアウトになる)。
    // ここで先回りして落とす。「別スレッドが既に保持中」は正常系(flock の待ち行列に普通に
    // 並ばせる)なので、保持者をキーごとにスレッド識別子で覚えて区別する
    // (単なる「保持中キーの集合」だと別スレッドからの正当な待ちまで再入扱いしてしまう)。
    //
    // **異なるキーの入れ子は禁止**(順序次第で相互デッドロックする)。ここでは検出せず、
    // 呼び出し側の規律として守ること。

    private static let stateLock = NSLock()
    private static var heldBy: [String: ObjectIdentifier] = [:]

    private static func checkNotReentrant(key: String) throws {
        stateLock.lock()
        let holder = heldBy[key]
        stateLock.unlock()
        guard holder != ObjectIdentifier(Thread.current) else {
            throw LockError(description:
                "SharedResource(\(key)): 同一スレッドでの再入。同じキーを入れ子で locked{} すると" +
                "自分自身とデッドロックする(異なるキーの入れ子も禁止)")
        }
    }

    private static func markHeld(key: String) {
        stateLock.lock()
        heldBy[key] = ObjectIdentifier(Thread.current)
        stateLock.unlock()
    }

    /// **保持者と一致するかを見ずに消す**。async の body は acquire と別スレッドで再開しうるので、
    /// スレッド一致を条件にすると解放時に消し損ね、以降そのスレッドからの正当な取得が
    /// 「再入」と誤判定される。flock がキーごとに1保持者を保証する(同一プロセスでも fd が
    /// 別なら排他される)ので、ここに来た時点の保持者は必ず自分 = 無条件に消してよい
    private static func clearHeld(key: String) {
        stateLock.lock()
        heldBy[key] = nil
        stateLock.unlock()
    }

    // MARK: - fd の開閉

    private func openLockFile() throws -> Int32 {
        try FileManager.default.createDirectory(
            at: Self.lockDirectory, withIntermediateDirectories: true)
        while true {
            let fd = open(lockFileURL.path, O_CREAT | O_RDWR, 0o644)
            if fd >= 0 { return fd }
            if errno == EINTR { continue }
            throw LockError(description:
                "SharedResource(\(key)): ロックファイルを開けない(\(lockFileURL.path), errno=\(errno))")
        }
    }

    /// 1 回だけ試す。取れたら true、他プロセス/スレッドが保持中(EWOULDBLOCK)なら false。
    /// EINTR は(待ち行列に並んだことにせず)即座に再試行する
    private static func tryFlock(_ fd: Int32) throws -> Bool {
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            switch errno {
            case EINTR: continue
            case EWOULDBLOCK: return false
            default:
                throw LockError(description: "SharedResource: flock 失敗(errno=\(errno))")
            }
        }
    }

    private func release(fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
        Self.clearHeld(key: key)
    }

    private func timeoutError() -> LockError {
        LockError(description:
            "SharedResource(\(key)): \(Int(Self.timeoutSeconds))秒待って諦めた(他プロセス/スレッドが保持中)")
    }

    // MARK: - 取得

    private func acquireSync() throws -> Int32 {
        try Self.checkNotReentrant(key: key)
        let fd = try openLockFile()
        do {
            let deadline = Date().addingTimeInterval(Self.timeoutSeconds)
            while try !Self.tryFlock(fd) {
                guard Date() < deadline else { throw timeoutError() }
                usleep(Self.pollIntervalMicroseconds)
            }
        } catch {
            close(fd)
            throw error
        }
        Self.markHeld(key: key)
        return fd
    }

    private func acquireAsync() async throws -> Int32 {
        try Self.checkNotReentrant(key: key)
        let fd = try openLockFile()
        do {
            let deadline = Date().addingTimeInterval(Self.timeoutSeconds)
            while try !Self.tryFlock(fd) {
                guard Date() < deadline else { throw timeoutError() }
                // ブロッキング flock の代わりにポーリング(協調スレッドを塞がない。Sources/FTCore/FMLock.swift と同じ作法)
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        } catch {
            close(fd)
            throw error
        }
        Self.markHeld(key: key)
        return fd
    }

    // MARK: - 公開 API
    //
    // `rethrows` にはできない。ロック取得は body と無関係にタイムアウト・再入で throw するので、
    // コンパイラが弾く("a function declared 'rethrows' may only throw if its parameter does"。
    // 2026-08-10 に実際にコンパイルして確認)。結果として body が非 throwing でも `try` が要る

    public func locked<T>(_ body: () throws -> T) throws -> T {
        let fd = try acquireSync()
        defer { release(fd: fd) }
        return try body()
    }

    public func locked<T>(_ body: () async throws -> T) async throws -> T {
        let fd = try await acquireAsync()
        defer { release(fd: fd) }
        return try await body()
    }
}
