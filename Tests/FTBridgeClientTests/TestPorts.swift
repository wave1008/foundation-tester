// ポートは**ホスト全体の共有資源**で、テストの外(別セッション・手で立てたブリッジ・
// 無関係な常駐プロセス)とも衝突する。「この番号は空いているはず」と固定値で書くと、
// たまたま誰かが掴んだ日にそのテストだけが落ちる(実際に 59999 を Gradle デーモンが掴んだ)。
// **空きは OS に選ばせる**。読み手は AssignPortTests / ForeignBridgeErrorTests。

import XCTest

enum TestPorts {
    /// OS に空きポートを1つ選ばせて即座に閉じ、その番号を「誰も居ない港」として返す。
    /// 返した瞬間に誰かが掴む可能性はゼロではないが、固定番号(= 実際に使われている番号)より
    /// はるかに安全。ソケットを開けない環境ではテストを skip する(赤にしない)
    static func withNoListener() throws -> UInt16 {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw XCTSkip("socket を開けない") }
        defer { close(listener) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0            // 0 = OS が空きを選ぶ
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var bound = addr
        let ok = withUnsafePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok else { throw XCTSkip("bind できない") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listener, $0, &length) == 0
            }
        }
        guard got else { throw XCTSkip("getsockname できない") }
        return UInt16(bigEndian: actual.sin_port)
    }
}
