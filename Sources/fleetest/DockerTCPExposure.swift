// Docker API の TCP 公開(2375 / 2376)が非ループバックで LISTEN していないか(docs/remote-runner.md §17「実行基盤の管理口」)。
// Apple のコンテナはゲートウェイ経由でホストの待ち受けに届くので、そこに Docker の管理口があるとホストのファイルをマウントできる。
// **既知の危険な設定の検知であって、管理口に届かないことの証明ではない**(別の番号で公開していれば拾えない)。
// 使うのは `doctor`(警告)とサービスの起動(`ServicesSession.up` = 断る)。判定は純粋関数で、lsof の実行だけ差し替え口。

import FTCore
import Foundation

enum DockerTCPExposure {
    static let ports = [2375, 2376]

    struct Listener: Equatable {
        let port: Int
        /// lsof の NAME のアドレス部("*"・"0.0.0.0"・"192.168.1.5"・"[::]" 等)
        let address: String
        let command: String
    }

    enum Scan: Equatable {
        case clear
        case exposed([Listener])
        /// lsof が異常終了した(見られなかった = 「無い」と言わない)
        case unknown(detail: String)
    }

    static func lsofArguments(port: Int) -> [String] {
        ["/usr/sbin/lsof", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
    }

    /// "127.0.0.1" / "[::1]" / "localhost" だけがループバック。"*" と "0.0.0.0" と "[::]" は全インターフェース。
    static func isLoopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "[::1]" || address == "localhost" || address.hasPrefix("127.")
    }

    /// `lsof -nP -iTCP:<port> -sTCP:LISTEN` の出力(ヘッダ行つき)から非ループバックの待ち受けを拾う。
    /// NAME は "<addr>:<port> (LISTEN)" の形(-nP なので名前解決も service 名も無い)。
    static func nonLoopbackListeners(lsofOutput: String, port: Int) -> [Listener] {
        var found: [Listener] = []
        for rawLine in lsofOutput.split(separator: "\n") {
            let fields = rawLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 9, fields[0] != "COMMAND" else { continue }
            let name = fields[8]
            guard let cut = name.lastIndex(of: ":"), String(name[name.index(after: cut)...]) == String(port) else { continue }
            let address = String(name[..<cut])
            guard !isLoopback(address) else { continue }
            let listener = Listener(port: port, address: address, command: fields[0])
            if !found.contains(listener) { found.append(listener) }
        }
        return found
    }

    /// lsof は該当が無いと exit 1 で何も出さない(= clear)。それ以外の非0は「見られなかった」。
    static func scan(run: ([String]) -> (status: Int32, output: String)? = { argv in
        (try? Shell.run(argv)).map { ($0.status, $0.output) }
    }) -> Scan {
        var listeners: [Listener] = []
        for port in ports {
            guard let result = run(lsofArguments(port: port)) else { return .unknown(detail: "lsof could not be started") }
            switch result.status {
            case 0: listeners += nonLoopbackListeners(lsofOutput: result.output, port: port)
            case 1 where result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: continue
            default: return .unknown(detail: "lsof exit \(result.status)")
            }
        }
        return listeners.isEmpty ? .clear : .exposed(listeners)
    }

    /// 文言は呼び手が付ける(doctor は警告・サービスの起動は拒否)。ここは事実の部分だけ
    static func describe(_ listeners: [Listener]) -> String {
        listeners.map { "\($0.address):\($0.port) (\($0.command))" }.joined(separator: ", ")
    }

    static let remedy = "bind it to 127.0.0.1 or turn TCP publishing off (fleetest's sandbox already keeps scenarios and scripts away from 2375/2376)"
}
