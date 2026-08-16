// 実機(物理 iPhone)の Safari を WebKit remote inspector で読むための、シミュレータには無い
// 前段(usbmuxd → lockdownd → TLS → webinspectord)。ここから先(4byte BE + plist・
// Target 包み)は `SafariWebInspector.evaluate` が `InspectorTransport` 越しに共通で使う。
//
// **usbmuxd 制御プロトコルは lockdown/webinspector と別形式**: 16byte リトルエンディアン
// ヘッダ(ヘッダ込み全長 / version=1 / message=8 / tag)+ XML plist。ReadPairRecord/
// ListDevices/Connect の3つだけがこの形を話す。Connect が成功すると、その fd は以後
// 実機の指定ポートへの生の中継管になり、そこから先は lockdown の「4byte BE 長 + plist」
// (`SafariWebInspector.encodeFrame`/`extractFrame` を再利用。書式は同じで plist の中身が違うだけ)。
//
// 手順(実測 2026-08-13・iOS 26.6):
//   ReadPairRecord → ListDevices → Connect(port 62078) → lockdown StartSession(TLS 開始)
//   → lockdown StartService(com.apple.webinspector) → 返ってきたポートへ Connect
//   → EnableServiceSSL なら TLS で包み直す → ここから webinspector の RPC

import Foundation
import Darwin
import Security
import FTCore

enum PhysicalSafariInspector {
    private static let lockdownPort: UInt16 = 62078
    private static let webinspectorService = "com.apple.webinspector"

    /// ハードウェア UDID の実機まで、webinspector プロトコルを話せる `InspectorTransport` を
    /// 確立する。**失敗は全段どこでも nil**(未ペアリング・USB 未接続・サービス無効はどれも
    /// 珍しくない)。`InvalidService` だけは stderr へ知らせる(将来の移設の合図)
    static func connect(hardwareUDID: String, deadline: Date) -> InspectorTransport? {
        guard let pair = readPairRecord(udid: hardwareUDID, deadline: deadline) else { return nil }
        guard let identity = PairingIdentityImporter.importIdentity(
            hostCertificate: pair.hostCertificate, hostPrivateKey: pair.hostPrivateKey) else { return nil }
        guard let deviceID = lookupDeviceID(udid: hardwareUDID, deadline: deadline) else { return nil }

        guard let lockdownFD = connectDevicePort(deviceID: deviceID, port: lockdownPort, deadline: deadline)
        else { return nil }

        guard let sessionResponse = exchangeLockdownPlain(
                fd: lockdownFD,
                request: LockdownProtocol.startSessionRequest(hostID: pair.hostID, systemBUID: pair.systemBUID),
                deadline: deadline),
              LockdownProtocol.enableSessionSSL(sessionResponse)
        else { Darwin.close(lockdownFD); return nil }

        guard let lockdownTLS = TLSInspectorConnection(fd: lockdownFD, identity: identity, deadline: deadline)
        else { Darwin.close(lockdownFD); return nil }
        guard let serviceResponse = exchangeLockdown(
            over: lockdownTLS, request: LockdownProtocol.startServiceRequest(webinspectorService), deadline: deadline)
        else { lockdownTLS.close(); return nil }
        lockdownTLS.close() // 診断チャンネルはここで用済み。webinspector は別ポートへの新規トンネル

        if LockdownProtocol.isInvalidService(serviceResponse) {
            FileHandle.standardError.write(Data(
                ("ftester: com.apple.webinspector が実機の lockdown サービス一覧に無い"
                 + "(Apple が別サービスへ移した可能性。ブラウザ DOM 読み取りは a11y のまま続行)\n").utf8))
            return nil
        }
        guard let service = LockdownProtocol.serviceStart(serviceResponse) else { return nil }

        guard let webInspectorFD = connectDevicePort(deviceID: deviceID, port: service.port, deadline: deadline)
        else { return nil }
        guard service.enableSSL else { return SafariInspectorConnection(fd: webInspectorFD) }
        guard let tls = TLSInspectorConnection(fd: webInspectorFD, identity: identity, deadline: deadline) else {
            Darwin.close(webInspectorFD)
            return nil
        }
        return tls
    }

    // MARK: - usbmuxd 制御プロトコル(I/O)

    private static func readPairRecord(udid: String, deadline: Date) -> UsbmuxdEnvelope.PairRecord? {
        guard let connection = UsbmuxdControlConnection() else { return nil }
        defer { connection.close() }
        guard let response = connection.request(commonFields(["MessageType": "ReadPairRecord", "PairRecordID": udid]),
                                                 deadline: deadline) else { return nil }
        return UsbmuxdEnvelope.parsePairRecord(response)
    }

    private static func lookupDeviceID(udid: String, deadline: Date) -> Int? {
        guard let connection = UsbmuxdControlConnection() else { return nil }
        defer { connection.close() }
        guard let response = connection.request(commonFields(["MessageType": "ListDevices"]), deadline: deadline)
        else { return nil }
        return UsbmuxdEnvelope.deviceID(forHardwareUDID: udid, in: response)
    }

    /// **返す fd は close しない**(呼び出し側が実機ポートへの中継管として使い続ける契約。
    /// 失敗時だけこの関数の中で閉じる)
    private static func connectDevicePort(deviceID: Int, port: UInt16, deadline: Date) -> Int32? {
        guard let connection = UsbmuxdControlConnection() else { return nil }
        let request = commonFields(["MessageType": "Connect", "DeviceID": deviceID,
                                    "PortNumber": Int(UsbmuxdEnvelope.connectPortValue(port))])
        guard let response = connection.request(request, deadline: deadline),
              UsbmuxdEnvelope.connectSucceeded(response) else {
            connection.close()
            return nil
        }
        let fd = connection.detachFD()
        // 以後この fd は lockdown/webinspector の 4byte BE フレームを話す。**タイムアウト付き**に
        // しておかないと、応答が来ない相手(サービス無効・切断)で `receiveFrame` が無限に待つ
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private static func commonFields(_ extra: [String: Any]) -> [String: Any] {
        var payload: [String: Any] = ["ClientVersionString": "ftester", "ProgName": "ftester", "kLibUSBMuxVersion": 3]
        payload.merge(extra) { _, new in new }
        return payload
    }

    // MARK: - lockdown の1往復(4byte BE + plist。生 fd 版と InspectorTransport 版)

    private static func encodeLockdownFrame(_ request: [String: Any]) -> Data? {
        guard let body = try? PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
        else { return nil }
        return SafariWebInspector.encodeFrame(body)
    }

    private static func decodeLockdownResponse(_ body: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any]
    }

    /// TLS 開始前の StartSession だけがここを通る(`InspectorTransport` を作る前の生 fd)
    private static func exchangeLockdownPlain(fd: Int32, request: [String: Any], deadline: Date) -> [String: Any]? {
        guard let frame = encodeLockdownFrame(request), rawWrite(fd: fd, data: frame) else { return nil }
        let frameBuffer = FrameBuffer()
        guard let body = frameBuffer.receiveFrame(deadline: deadline, readChunk: { _ in rawReadChunk(fd: fd) })
        else { return nil }
        return decodeLockdownResponse(body)
    }

    private static func exchangeLockdown(over connection: InspectorTransport, request: [String: Any],
                                         deadline: Date) -> [String: Any]? {
        guard let frame = encodeLockdownFrame(request), connection.send(frame),
              let body = connection.receiveFrame(deadline: deadline) else { return nil }
        return decodeLockdownResponse(body)
    }

    private static func rawWrite(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(fd, base.advanced(by: sent), data.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private static func rawReadChunk(fd: Int32) -> FrameBuffer.ChunkResult {
        var chunk = [UInt8](repeating: 0, count: 8192)
        let n = chunk.withUnsafeMutableBytes { raw in Darwin.read(fd, raw.baseAddress, raw.count) }
        if n > 0 { return .data(Data(chunk[0..<n])) }
        if n == 0 { return .closed }
        return .timeout // SO_RCVTIMEO 到達。呼び出し側の deadline ループが再試行するか諦めるか決める
    }
}

// MARK: - usbmuxd フレーミング・応答パース(純粋)

/// usbmuxd(`/var/run/usbmuxd`)への制御要求。lockdown/webinspector の4byte BE 形式とは
/// **別のヘッダ形式**(16byte リトルエンディアン: 全長/version/message/tag)
enum UsbmuxdEnvelope {
    static let headerSize = 16
    static let version: UInt32 = 1
    static let plistMessageType: UInt32 = 8

    struct Header: Equatable {
        let length: UInt32
        let version: UInt32
        let message: UInt32
        let tag: UInt32
    }

    struct PairRecord: Equatable {
        let hostID: String
        let systemBUID: String
        let hostCertificate: Data
        let hostPrivateKey: Data
    }

    static func encode(_ payload: [String: Any], tag: UInt32) -> Data? {
        guard let body = try? PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        else { return nil }
        var out = Data()
        out.append(littleEndian(UInt32(headerSize + body.count)))
        out.append(littleEndian(version))
        out.append(littleEndian(plistMessageType))
        out.append(littleEndian(tag))
        out.append(body)
        return out
    }

    static func parseHeader(_ data: Data) -> Header? {
        guard data.count >= headerSize else { return nil }
        let bytes = Array(data.prefix(headerSize))
        return Header(length: littleEndianUInt32(bytes, 0), version: littleEndianUInt32(bytes, 4),
                     message: littleEndianUInt32(bytes, 8), tag: littleEndianUInt32(bytes, 12))
    }

    static func decodePayload(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }

    /// ReadPairRecord 応答の `PairRecordData`(埋め込まれた別 plist)から必要な鍵だけ取り出す
    static func parsePairRecord(_ response: [String: Any]) -> PairRecord? {
        guard let data = response["PairRecordData"] as? Data,
              let record = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any],
              let hostID = record["HostID"] as? String,
              let systemBUID = record["SystemBUID"] as? String,
              let hostCertificate = record["HostCertificate"] as? Data,
              let hostPrivateKey = record["HostPrivateKey"] as? Data
        else { return nil }
        return PairRecord(hostID: hostID, systemBUID: systemBUID,
                          hostCertificate: hostCertificate, hostPrivateKey: hostPrivateKey)
    }

    /// ListDevices 応答から対象ハードウェア UDID(`Properties.SerialNumber`)の DeviceID を引く
    static func deviceID(forHardwareUDID udid: String, in response: [String: Any]) -> Int? {
        guard let list = response["DeviceList"] as? [[String: Any]] else { return nil }
        for entry in list {
            guard let properties = entry["Properties"] as? [String: Any],
                  (properties["SerialNumber"] as? String) == udid,
                  let id = entry["DeviceID"] as? Int else { continue }
            return id
        }
        return nil
    }

    /// Connect 応答の成否。**`Number == 0` だけが成功**(実測)
    static func connectSucceeded(_ response: [String: Any]) -> Bool {
        (response["Number"] as? Int) == 0
    }

    /// PortNumber は**ネットワークバイト順**で積む(usbmuxd はホストのエンディアンで解釈しない)。
    /// 16bit のバイト入替は `byteSwapped` と同値(実測: 62078 → 32498)
    static func connectPortValue(_ port: UInt16) -> UInt16 { port.byteSwapped }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}

/// lockdown の plist メッセージ組み立て・応答判定(純粋)
enum LockdownProtocol {
    static func startSessionRequest(hostID: String, systemBUID: String) -> [String: Any] {
        ["Request": "StartSession", "Label": "ftester", "HostID": hostID, "SystemBUID": systemBUID]
    }

    static func startServiceRequest(_ service: String) -> [String: Any] {
        ["Request": "StartService", "Label": "ftester", "Service": service]
    }

    static func enableSessionSSL(_ response: [String: Any]) -> Bool {
        (response["EnableSessionSSL"] as? Bool) == true
    }

    struct ServiceStart: Equatable {
        let port: UInt16
        let enableSSL: Bool
    }

    /// StartService 応答から接続先ポートを取り出す。**Port は 1...65535 でなければ拒否**
    static func serviceStart(_ response: [String: Any]) -> ServiceStart? {
        guard let port = response["Port"] as? Int, (1...65535).contains(port) else { return nil }
        return ServiceStart(port: UInt16(port), enableSSL: (response["EnableServiceSSL"] as? Bool) == true)
    }

    /// 将来 Apple が `com.apple.webinspector` を撤去/移設した合図。**このときだけ stderr へ知らせる**
    /// (それ以外の失敗——未ペアリング・USB 未接続等——は普通に起きるので黙る)
    static func isInvalidService(_ response: [String: Any]) -> Bool {
        (response["Error"] as? String) == "InvalidService"
    }
}

// MARK: - 4byte BE フレームの受信バッファリング(生ソケット/TLS 共通)

/// **境界判定は `SafariWebInspector.extractFrame` の1箇所だけ**(ここでは呼ぶだけ)。
/// 下位の1回読みだけ差し替え可能にして、生ソケット(`read`)と TLS(`SSLRead`)の両方で使い回す
final class FrameBuffer {
    enum ChunkResult { case data(Data); case timeout; case closed }
    private var buffer = Data()

    func receiveFrame(deadline: Date, readChunk: (Date) -> ChunkResult) -> Data? {
        while Date() < deadline {
            if let (body, rest) = SafariWebInspector.extractFrame(from: buffer) {
                buffer = rest
                return body
            }
            switch readChunk(deadline) {
            case .data(let chunk): buffer.append(chunk)
            case .timeout: continue
            case .closed: return nil
            }
        }
        return nil
    }
}

// MARK: - usbmuxd 制御接続(I/O)

/// `/var/run/usbmuxd` への1回線。ReadPairRecord/ListDevices は要求ごとに新規接続し使い切る。
/// Connect だけは成功後に `detachFD()` で fd の所有権を呼び出し側へ渡す
/// (**その場合 `close()` を呼んではいけない** —— 中継管として生き続ける必要があるため)
final class UsbmuxdControlConnection {
    let fd: Int32
    private var buffer = Data()

    init?() {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = "/var/run/usbmuxd"
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { Darwin.close(sock); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { Darwin.close(sock); return nil }
        self.fd = sock
    }

    func request(_ payload: [String: Any], tag: UInt32 = 1, deadline: Date) -> [String: Any]? {
        guard let frame = UsbmuxdEnvelope.encode(payload, tag: tag), write(frame) else { return nil }
        return receive(deadline: deadline)
    }

    /// **fd を close せずに手放す**(Connect 成功後、以後は生の中継管として使い続けるため)
    func detachFD() -> Int32 { fd }

    func close() { Darwin.close(fd) }

    private func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(fd, base.advanced(by: sent), data.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// usbmuxd のヘッダ(16byte 固定)を先に確定させてから残りを読む
    /// (境界が「フレーム全体長」1本しか無いので、ヘッダが揃うまでは長さが分からない)
    private func receive(deadline: Date) -> [String: Any]? {
        while buffer.count < UsbmuxdEnvelope.headerSize, Date() < deadline {
            guard readChunk(deadline: deadline) else { return nil }
        }
        guard let header = UsbmuxdEnvelope.parseHeader(buffer), header.length >= UInt32(UsbmuxdEnvelope.headerSize)
        else { return nil }
        while buffer.count < Int(header.length), Date() < deadline {
            guard readChunk(deadline: deadline) else { return nil }
        }
        guard buffer.count >= Int(header.length) else { return nil }
        let body = buffer.subdata(in: UsbmuxdEnvelope.headerSize..<Int(header.length))
        buffer = buffer.subdata(in: Int(header.length)..<buffer.count)
        return UsbmuxdEnvelope.decodePayload(body)
    }

    /// true = 続行可(読めた、またはタイムアウトでまだ時間がある)。false = EOF(諦める)
    private func readChunk(deadline: Date) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 8192)
        let n = chunk.withUnsafeMutableBytes { raw in Darwin.read(fd, raw.baseAddress, raw.count) }
        if n > 0 { buffer.append(contentsOf: chunk[0..<n]); return true }
        if n == 0 { return false }
        return Date() < deadline
    }
}

// MARK: - PKCS#12 経由の SecIdentity 生成

enum PairingIdentityImporter {

    /// ペアリング記録の HostCertificate/HostPrivateKey(いずれも PEM)から `SecIdentity` を作る。
    ///
    /// **難所**: `SecIdentityCreateWithCertificate` は秘密鍵が事前にキーチェーンへ登録済みで
    /// あることを要求するが、ペアリング記録の鍵は plist から来た生の PEM で未登録。
    /// **選択**: PKCS#12 へ包んで `SecPKCS12Import` する。`kSecImportToMemoryOnly`
    /// (macOS 15+。本パッケージの deployment target は 26.0 なので常に使える)を渡すと
    /// **キーチェーンへ一切書かない** —— 一時キーチェーンの作成/削除を自前で管理しなくて済む分、
    /// 一時キーチェーン方式より単純なのでこちらを選んだ。
    /// **一時ファイルは1つだけ**(cert+key を1本の PEM に連結。openssl は `-in`/`-inkey` に
    /// 同じパスを渡せば中の該当ブロックをそれぞれ拾える)。p12 本体はバイナリなので
    /// `Shell.runData`(stdout のみ・非テキスト安全)で受け、テキスト変換を経由しない。
    /// **秘密鍵を含む一時ファイルは `defer` で必ず削除する**
    static func importIdentity(hostCertificate: Data, hostPrivateKey: Data) -> SecIdentity? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftester-lockdown-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
        else { return nil }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var combined = hostCertificate
        combined.append(Data("\n".utf8))
        combined.append(hostPrivateKey)
        let combinedPath = tempDir.appendingPathComponent("host.pem")
        guard (try? combined.write(to: combinedPath, options: [.completeFileProtectionUntilFirstUserAuthentication]))
            != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: combinedPath.path)

        let passphrase = UUID().uuidString
        // **絶対パスで固定**(2026-08-13 のレビュー指摘)。PATH 次第で macOS 同梱の LibreSSL と
        // Homebrew の OpenSSL 3 が入れ替わり、p12 の既定暗号が変わって `SecPKCS12Import` の
        // 可否が受け手の環境で割れ得る。**締切も必ず付ける** —— ここだけ無期限だと、
        // `connect(deadline:)` という契約の内側に締切の効かない子プロセス待ちが残る
        guard let result = try? Shell.runData(["/usr/bin/openssl", "pkcs12", "-export",
                                               "-in", combinedPath.path, "-inkey", combinedPath.path,
                                               "-passout", "pass:\(passphrase)", "-out", "/dev/stdout"],
                                              timeout: 10),
              result.status == 0, !result.data.isEmpty else { return nil }

        let options: [String: Any] = [kSecImportExportPassphrase as String: passphrase,
                                      kSecImportToMemoryOnly as String: true]
        var items: CFArray?
        let status = SecPKCS12Import(result.data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first,
              let identity = first[kSecImportItemIdentity as String] else { return nil }
        return (identity as! SecIdentity) // swiftlint:disable:this force_cast — kSecImportItemIdentity は必ず SecIdentity
    }
}

// MARK: - TLS(SecureTransport 越しの生 fd)

/// SSLReadFunc/SSLWriteFunc へ渡す不透明ポインタの中身。**`@convention(c)` は非キャプチャ関数
/// しか渡せない**ため、fd と締切をここへ積んで `SSLConnectionRef` 経由で受け渡す
private final class TLSIOState {
    let fd: Int32
    var deadline: Date
    init(fd: Int32, deadline: Date) { self.fd = fd; self.deadline = deadline }
}

private func tlsPollReady(fd: Int32, forWrite: Bool, deadline: Date) -> Bool {
    let remainingMs = Int32(max(0, min(Double(Int32.max), deadline.timeIntervalSinceNow * 1000)))
    guard remainingMs > 0 else { return false }
    let requested = Int16(forWrite ? POLLOUT : POLLIN)
    var pfd = pollfd(fd: fd, events: requested, revents: 0)
    return poll(&pfd, 1, remainingMs) > 0 && (pfd.revents & requested) != 0
}

/// `SSLReadFunc`。**非ブロッキングではなく `poll` で締切まで待ってから読む** —— SecureTransport
/// は内部で必要なだけ何度もこの関数を呼ぶので、1呼びごとに「読めるまで待つ or 諦める」を
/// 決めれば SSLHandshake/SSLRead は結果として同期的に振る舞う
private func tlsReadFunc(_ connection: SSLConnectionRef,
                         _ data: UnsafeMutableRawPointer, _ dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let state = Unmanaged<TLSIOState>.fromOpaque(connection).takeUnretainedValue()
    let requested = dataLength.pointee
    guard requested > 0 else { dataLength.pointee = 0; return errSecSuccess }
    guard tlsPollReady(fd: state.fd, forWrite: false, deadline: state.deadline) else {
        dataLength.pointee = 0
        return errSSLWouldBlock
    }
    let n = Darwin.read(state.fd, data, requested)
    if n > 0 { dataLength.pointee = n; return errSecSuccess }
    dataLength.pointee = 0
    return n == 0 ? errSSLClosedGraceful : errSSLWouldBlock
}

private func tlsWriteFunc(_ connection: SSLConnectionRef,
                          _ data: UnsafeRawPointer, _ dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let state = Unmanaged<TLSIOState>.fromOpaque(connection).takeUnretainedValue()
    let requested = dataLength.pointee
    guard requested > 0 else { dataLength.pointee = 0; return errSecSuccess }
    guard tlsPollReady(fd: state.fd, forWrite: true, deadline: state.deadline) else {
        dataLength.pointee = 0
        return errSSLWouldBlock
    }
    let n = Darwin.write(state.fd, data, requested)
    if n > 0 { dataLength.pointee = n; return errSecSuccess }
    dataLength.pointee = 0
    return errSSLWouldBlock
}

/// lockdown/webinspector を包む TLS(SecureTransport)。macOS 10.15 で非推奨だが、
/// **「usbmuxd が中継する既に確立済みの fd へ後付けで TLS を被せる」ができる唯一の公開 API**
/// (Network.framework の `NWConnection` は自前で接続を張る前提で、既存 fd を渡す口が無い)。
/// **サーバ証明書は検証しない**(lockdownd は自己署名。ペアリング成立自体が信頼の根拠。
/// Python 実装でも `CERT_NONE` — `.breakOnServerAuth` で検証ステップを素通りする)
final class TLSInspectorConnection: InspectorTransport {
    private let context: SSLContext
    private let ioState: TLSIOState
    private let ioStatePointer: UnsafeMutableRawPointer
    private let fd: Int32
    private let frameBuffer = FrameBuffer()
    private var closed = false

    init?(fd: Int32, identity: SecIdentity, deadline: Date) {
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else { return nil }
        let state = TLSIOState(fd: fd, deadline: deadline)
        let pointer = Unmanaged.passRetained(state).toOpaque()
        guard SSLSetIOFuncs(ctx, tlsReadFunc, tlsWriteFunc) == errSecSuccess,
              SSLSetConnection(ctx, pointer) == errSecSuccess,
              SSLSetSessionOption(ctx, .breakOnServerAuth, true) == errSecSuccess,
              SSLSetCertificate(ctx, [identity] as CFArray) == errSecSuccess else {
            Unmanaged<TLSIOState>.fromOpaque(pointer).release()
            return nil
        }

        var status: OSStatus = errSSLWouldBlock
        handshake: while Date() < deadline {
            status = SSLHandshake(ctx)
            switch status {
            case errSecSuccess: break handshake
            case errSSLPeerAuthCompleted, errSSLWouldBlock: continue handshake // 検証せず続行 / 締切まで再試行
            default: break handshake
            }
        }
        guard status == errSecSuccess else {
            Unmanaged<TLSIOState>.fromOpaque(pointer).release()
            return nil
        }

        self.context = ctx
        self.ioState = state
        self.ioStatePointer = pointer
        self.fd = fd
    }

    func send(_ frame: Data) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        ioState.deadline = deadline
        var written = 0
        frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while written < frame.count, Date() < deadline {
                var processed = 0
                let status = SSLWrite(context, base.advanced(by: written), frame.count - written, &processed)
                written += processed
                if status != errSecSuccess, status != errSSLWouldBlock { break }
            }
        }
        return written == frame.count
    }

    func receiveFrame(deadline: Date) -> Data? {
        frameBuffer.receiveFrame(deadline: deadline) { chunkDeadline in
            self.ioState.deadline = chunkDeadline
            var buf = [UInt8](repeating: 0, count: 8192)
            var processed = 0
            let status = buf.withUnsafeMutableBytes { raw -> OSStatus in
                SSLRead(self.context, raw.baseAddress!, raw.count, &processed)
            }
            if status == errSecSuccess, processed > 0 { return .data(Data(buf[0..<processed])) }
            if status == errSSLWouldBlock { return .timeout }
            if status == errSSLClosedGraceful || status == errSSLClosedAbort { return .closed }
            return status == errSecSuccess ? .timeout : .closed
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        SSLClose(context)
        Unmanaged<TLSIOState>.fromOpaque(ioStatePointer).release()
        Darwin.close(fd)
    }

    deinit {
        guard !closed else { return }
        Unmanaged<TLSIOState>.fromOpaque(ioStatePointer).release()
        Darwin.close(fd)
    }
}
