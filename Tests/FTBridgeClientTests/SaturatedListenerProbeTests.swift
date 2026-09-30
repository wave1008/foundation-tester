// 生死の判定が connect の「分からない」(`.unknown` = 時間切れ・溢れた待受の reset)を「誰も居ない」と
// 読まないこと(maintainer-notes §62.1: .notBound と答えると、ライブ操作の自動起動が生きたランナーを
// 片付けうる)。溢れた待受への connect は reset が混ざるが毎回ではない(実測)ので、実ソケットでは
// 決定的に作れない —— 入口の判定を純粋関数で3値とも固定する。

import XCTest
@testable import FTBridgeClient

final class SaturatedListenerProbeTests: XCTestCase {

    func testOnlyRefusedIsReadAsNobodyThere() {
        XCTAssertEqual(BridgeDiscovery.entryVerdict(.refused), .notBound)
        XCTAssertNil(BridgeDiscovery.entryVerdict(.unknown),
                     "a connect that could not tell must go on to the HTTP probe, not be read as nobody listening")
        XCTAssertNil(BridgeDiscovery.entryVerdict(.connected))
    }

    func testNobodyListeningIsStillNotBound() async throws {
        let port = try TestPorts.withNoListener()
        XCTAssertFalse(BridgeDiscovery.mayBeListening(port: port, repoRoot: nil))
        let probe = await BridgeDiscovery.probeStatus(port: port, repoRoot: nil, timeoutSeconds: 1)
        XCTAssertEqual(probe, .notBound)
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `probeStatus` の入口は `entryVerdict` を通る(`isBound` で門を掛け直すと `.unknown` がまた畳まれる)
    func testProbeStatusEntryGoesThroughEntryVerdict() throws {
        let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "Sources/FTBridgeClient/BridgeDiscovery.swift"), encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "public static func probeStatus("))
        let body = String(text[start.upperBound...].prefix(600))
        XCTAssertTrue(body.contains("entryVerdict(connectProbe("), body)
        XCTAssertFalse(body.contains("isBound("), body)
    }

    /// `isBound`(connected だけ true)を使ってよいのは「不明なら触らない」前段フィルタだけ。
    /// 生死・持ち主を決める呼び手が増えたら `mayBeListening` を使わせる(等号で固定)
    func testIsBoundCallersAreOnlyNonDestructivePrefilters() throws {
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        var callers: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            if code.contains(where: { $0.contains("BridgeDiscovery.isBound(") }) {
                callers.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(Set(callers), ["BridgeProvisioner.swift", "DoctorCommand.swift"],
                       "isBound folds 'cannot tell' into 'nobody there' — use mayBeListening for liveness/ownership")
    }
}
