// BridgeHTTPServer.swift
// テストバンドル内で動く極小 HTTP/1.1 サーバ(BSDソケット直書き、依存ゼロ)。
// 接続は1本ずつ順番に処理する。これにより XCUITest 操作が自然に直列化される
// (CLI/エージェントは一度に1リクエストしか送らない前提)。

import Foundation

final class BridgeHTTPServer {

    struct Request {
        let method: String
        let path: String
        let body: Data
    }

    struct Response {
        let status: Int
        let contentType: String
        let body: Data

        static func json<T: Encodable>(_ value: T, status: Int = 200) -> Response {
            let data = (try? JSONEncoder().encode(value)) ?? Data()
            return Response(status: status, contentType: "application/json", body: data)
        }

        static func error(_ message: String, status: Int = 500) -> Response {
            .json(ErrorResponse(error: message), status: status)
        }

        static func png(_ data: Data) -> Response {
            Response(status: 200, contentType: "image/png", body: data)
        }
    }

    enum ServerError: Error {
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
    }

    /// main queue の async クロージャが書き込み、セマフォ signal 後に accept スレッドが読む
    /// (happens-before で安全)。タイムアウト時は書き込まれないため読まない。
    private final class ResponseBox {
        var response: Response = .error("unhandled", status: 500)
    }

    private let port: UInt16
    private let handler: (Request) -> Response
    private var serverFD: Int32 = -1
    private(set) var isRunning = false

    /// 1リクエストの handler(main スレッド上の XCUITest 操作)の壁時計上限(秒)。超過は
    /// "Wait for app to idle" 等で main が恒久ブロックした状態で、main は復帰不能。クライアントの
    /// per-endpoint 上限(interaction 20s / session 45s)より長く、シナリオ watchdog(90s)より短く
    /// 取り、504 を返してプロセス自死→ポート解放→device-up 再起動に委ねる。
    static let handlerTimeout: TimeInterval = 60

    init(port: UInt16, handler: @escaping (Request) -> Response) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // シミュレータはホストとネットワークスタックを共有するため、
        // ループバックに bind すれば Mac 側の 127.0.0.1 から直接届く。
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ServerError.bindFailed(errno)
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw ServerError.listenFailed(errno)
        }

        serverFD = fd
        isRunning = true
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func stop() {
        isRunning = false
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
    }

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(serverFD, &clientAddr, &len)
            guard clientFD >= 0 else {
                if isRunning { usleep(10_000) }
                continue
            }
            // 応答途中でホストが切断した際の write() の SIGPIPE(既定でランナープロセス終了)を防ぐ。
            // InAppHTTPServer と同じ防御(あちらは対象アプリ、こちらは XCUITest ランナーがクラッシュする)。
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            autoreleasepool {
                if let request = readRequest(clientFD) {
                    writeResponse(clientFD, dispatchToMain(request))
                } else {
                    writeResponse(clientFD, .error("bad request", status: 400))
                }
            }
            close(clientFD)
        }
    }

    /// XCUITest API はメインスレッド必須(launch 等)。テストメソッド側が RunLoop を回し続けて
    /// いるので main queue に投げて実行する。NSException(launch 失敗等)は捕捉して 500 で返す。
    /// handlerTimeout を超えたら main が恒久ブロックしたとみなし、504 を返して自死する(main は
    /// 復帰不能なので待ち続けても無意味。接続直列処理のため放置すると /status も含む全接続が固まる)。
    private func dispatchToMain(_ request: Request) -> Response {
        let done = DispatchSemaphore(value: 0)
        // async 実行前に確定させておく既定値。タイムアウト時はこの箱を読まない(未書き込みのため)。
        let box = ResponseBox()
        DispatchQueue.main.async {
            if let exceptionMessage = FTCatchObjCException({
                box.response = self.handler(request)
            }) {
                box.response = .error("XCUITest exception: \(exceptionMessage)", status: 500)
            }
            done.signal()
        }
        if done.wait(timeout: .now() + Self.handlerTimeout) == .timedOut {
            // 504 をクライアントへ書き終える猶予を与えてから exit。main はブロック済みなので
            // global キューで自死をスケジュールする(このメソッドは accept スレッド上で動く)。
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exit(70) }
            return .error("handler timed out after \(Int(Self.handlerTimeout))s; bridge self-terminating",
                          status: 504)
        }
        return box.response
    }

    private func readRequest(_ fd: Int32) -> Request? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        let headerEnd = Data("\r\n\r\n".utf8)
        var headerRange: Range<Data.Index>?

        while headerRange == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            headerRange = buffer.range(of: headerEnd)
            if buffer.count > 4_000_000 { return nil }
        }
        guard let hr = headerRange,
              let headerString = String(data: buffer[..<hr.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        var body = Data(buffer[hr.upperBound...])
        while body.count < contentLength {
            let n = read(fd, &chunk, min(chunk.count, contentLength - body.count))
            if n <= 0 { break }
            body.append(contentsOf: chunk[0..<n])
        }
        return Request(method: String(parts[0]), path: String(parts[1]), body: body)
    }

    private func writeResponse(_ fd: Int32, _ response: Response) {
        var header = "HTTP/1.1 \(response.status) \(Self.statusText(response.status))\r\n"
        header += "Content-Type: \(response.contentType)\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(response.body)

        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = write(fd, base.advanced(by: offset), data.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 409: return "Conflict"
        default: return "Internal Server Error"
        }
    }
}
