// ProxyDestinationPolicy.swift
// 名前を解決して出てきたアドレスのうち、親が接続してよいものを選ぶ。許可した名前が loopback や自機のアドレスを返す
// (DNS rebinding)と、親の loopback = ブリッジ・adb・TCP で公開した Docker API に届くので、数値アドレスで検めてから繋ぐ。
// 純粋(getifaddrs を読む `currentInterfaceAddresses` だけが例外で、`standard` の既定引数でしか呼ばれない)。
import Foundation

public struct ProxyDestinationPolicy: Sendable, Equatable {
    /// 自機のインターフェースのアドレス(数値)。これへ向く解決結果は断る
    public var ownAddresses: [String]
    /// 断るネットワーク(CIDR。"192.168.64.0/24" や "fd00::/8")= コンテナのゲートウェイとサブネット。
    /// 書けない形が1つでもあれば `pick` は全部断る(安全側。黙って無視すると断るはずの網が穴になる)
    public var deniedNetworks: [String]
    /// loopback(127/8・::1)・未指定(0/8・::)・リンクローカル(169.254/16・fe80::/10)・マルチキャストを断る。
    /// **テストだけ false にする**(本番は常に true)
    public var refuseSpecialAddresses: Bool

    public struct Refusal: Error, Equatable {
        public let reason: String
        public init(reason: String) { self.reason = reason }
    }

    public init(ownAddresses: [String], deniedNetworks: [String], refuseSpecialAddresses: Bool) {
        self.ownAddresses = ownAddresses
        self.deniedNetworks = deniedNetworks
        self.refuseSpecialAddresses = refuseSpecialAddresses
    }

    public static func standard(ownAddresses: [String] = currentInterfaceAddresses(),
                                deniedNetworks: [String] = []) -> ProxyDestinationPolicy {
        ProxyDestinationPolicy(ownAddresses: ownAddresses, deniedNetworks: deniedNetworks,
                               refuseSpecialAddresses: true)
    }

    /// 全部通す(テストの差し替え口。本番で使わない)
    public static let permissive = ProxyDestinationPolicy(
        ownAddresses: [], deniedNetworks: [], refuseSpecialAddresses: false)

    /// 解決順に見て、接続してよい最初の数値アドレスを返す。全部断られたら Refusal(断った理由を並べる)
    public func pick(resolved: [String]) -> Result<String, Refusal> {
        allowed(resolved: resolved).map { $0[0] }
    }

    /// 接続してよい数値アドレスを解決順のまま全部返す(呼び手は順に試す = 先頭の IPv6 に届かない機械で次の IPv4 へ倒れる)。
    /// 1つも残らなければ Refusal(断った理由を並べる)
    public func allowed(resolved: [String]) -> Result<[String], Refusal> {
        guard !resolved.isEmpty else { return .failure(Refusal(reason: "the name resolved to no address")) }
        var networks: [(bytes: [UInt8], prefix: Int)] = []
        for text in deniedNetworks {
            guard let parsed = Self.parseCIDR(text) else {
                return .failure(Refusal(reason: "denied network \(text) is not a valid CIDR"))
            }
            networks.append(parsed)
        }
        let own = ownAddresses.compactMap(Self.parseAddress)
        var reasons: [String] = []
        var passed: [String] = []
        for text in resolved {
            guard let address = Self.parseAddress(text) else {
                reasons.append("\(text) is not a numeric address")
                continue
            }
            if let reason = refusalReason(address, text: text, networks: networks, own: own) {
                reasons.append(reason)
            } else {
                passed.append(text)
            }
        }
        return passed.isEmpty ? .failure(Refusal(reason: reasons.joined(separator: "; "))) : .success(passed)
    }

    private func refusalReason(_ address: [UInt8], text: String, networks: [(bytes: [UInt8], prefix: Int)],
                               own: [[UInt8]]) -> String? {
        if own.contains(address) { return "\(text) is an address of this machine" }
        if networks.contains(where: { Self.contains(network: $0.bytes, prefix: $0.prefix, address: address) }) {
            return "\(text) is in a denied network"
        }
        if refuseSpecialAddresses, let kind = Self.specialKind(address) { return "\(text) is \(kind)" }
        return nil
    }

    // MARK: - 数値アドレス(4 バイト = IPv4 / 16 バイト = IPv6。IPv4-mapped は 4 バイトへ畳む)

    static func parseAddress(_ text: String) -> [UInt8]? {
        var stripped = text
        if let percent = stripped.firstIndex(of: "%") { stripped = String(stripped[..<percent]) }
        var v4 = in_addr()
        if inet_pton(AF_INET, stripped, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, stripped, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes[..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return Array(bytes[12...])
            }
            return bytes
        }
        return nil
    }

    static func parseCIDR(_ text: String) -> (bytes: [UInt8], prefix: Int)? {
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, let address = parseAddress(String(pieces[0])),
              !pieces[1].isEmpty, pieces[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let prefix = Int(pieces[1]) else { return nil }
        // "::ffff:a.b.c.d/N" は畳んだ 4 バイトに対する長さが別物(N-96)になる → 受けない(書けない形として断る側)
        if pieces[0].contains(":"), pieces[0].contains("."), address.count == 4 { return nil }
        guard prefix <= address.count * 8 else { return nil }
        return (address, prefix)
    }

    static func contains(network: [UInt8], prefix: Int, address: [UInt8]) -> Bool {
        guard network.count == address.count else { return false }
        let whole = prefix / 8
        if network[..<whole] != address[..<whole] { return false }
        let rest = prefix % 8
        guard rest > 0 else { return true }
        let mask = UInt8(truncatingIfNeeded: 0xff << (8 - rest))
        return (network[whole] & mask) == (address[whole] & mask)
    }

    static func specialKind(_ address: [UInt8]) -> String? {
        if address.count == 4 {
            if address[0] == 127 { return "a loopback address" }
            if address[0] == 0 { return "an unspecified address" }
            if address[0] == 169, address[1] == 254 { return "a link-local address" }
            if address[0] >= 224, address[0] <= 239 { return "a multicast address" }
            return nil
        }
        if address.dropLast().allSatisfy({ $0 == 0 }) {
            if address[15] == 1 { return "a loopback address" }
            if address[15] == 0 { return "an unspecified address" }
        }
        if address[0] == 0xfe, address[1] & 0xc0 == 0x80 { return "a link-local address" }
        if address[0] == 0xff { return "a multicast address" }
        return nil
    }

    /// getifaddrs の全アドレス(IPv4 / IPv6。スコープ ID は落とす)
    public static func currentInterfaceAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
            if !result.contains(text) { result.append(text) }
        }
        return result
    }
}
