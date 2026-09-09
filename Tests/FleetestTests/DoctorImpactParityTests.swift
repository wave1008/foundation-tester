// FM が使えないときに「何が止まるか」を出す経路は2つ(CLI の `fleetest doctor` と MCP の
// `ft_doctor`)で、共有できるのは文言の定義元 `FMDoctor.unavailableImpact` だけ —— 出すか出さないかは
// それぞれの表示コードが決めるので、型では守れない。受け手向けドキュメントは FM の可否を
// `fleetest doctor` で確かめろと案内しているため、CLI 側が黙ると「使えない」しか分からなくなる。

import XCTest

final class DoctorImpactParityTests: XCTestCase {

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    func testBothDoctorsPrintTheUnavailableImpact() throws {
        for file in ["fleetest/Fleetest.swift", "fleetest-mcp/MCPServer+Dispatch.swift"] {
            let source = try String(contentsOf: sourcesRoot.appendingPathComponent(file),
                                    encoding: .utf8)
            XCTAssertTrue(source.contains("FMDoctor.unavailableImpact"),
                          "\(file) が FM 停止時の影響一覧を出していない")
        }
    }

    /// **陽性対照**: 走査が実ファイルへ届いていること(常に true を返す検査と区別する)。
    /// 綴りを変えただけの偽の合格を落とす
    func testScanReachesTheSources() throws {
        let source = try String(
            contentsOf: sourcesRoot.appendingPathComponent("fleetest/Fleetest.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.isEmpty)
        XCTAssertFalse(source.contains("FMDoctor.unavailableImpactZZZ"))
    }
}
