// アプリ内常駐ブリッジ用の極小 HTTP/1.1 サーバ(BSDソケット直書き、依存ゼロ)。
// Runner の BridgeHTTPServer と同じソケット処理だが、dispatchToMain が XCUITest 非依存
// (UIKit はメインスレッド必須なので main.sync で実行するだけ)。ハンドラは1本ずつ順に処理され、
// これにより操作が自然に直列化される(ホストは一度に1リクエストしか送らない前提)。

import Foundation

final class InAppHTTPServer {

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

    private let port: UInt16
    private let handler: (Request) -> Response
    private var serverFD: Int32 = -1
    private(set) var isRunning = false

    init(port: UInt16, handler: @escaping (Request) -> Response) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "InAppBridge", code: Int(errno)) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // シミュレータはホストとネットワークスタックを共有するため、ループバックに bind すれば
        // Mac 側の 127.0.0.1 から直接届く(Runner の BridgeHTTPServer と同じ前提)。
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { close(fd); throw NSError(domain: "InAppBridge.bind", code: Int(errno)) }
        guard listen(fd, 16) == 0 else { close(fd); throw NSError(domain: "InAppBridge.listen", code: Int(errno)) }

        serverFD = fd
        isRunning = true
        Thread.detachNewThread { [self] in acceptLoop() }
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

    // UIKit はメインスレッド必須。ハンドラをメインで同期実行する。
    private func dispatchToMain(_ request: Request) -> Response {
        if Thread.isMainThread { return handler(request) }
        return DispatchQueue.main.sync { handler(request) }
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
              let headerString = String(data: buffer[..<hr.lowerBound], encoding: .utf8) else { return nil }

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
        case 501: return "Not Implemented"
        default: return "Internal Server Error"
        }
    }
}
