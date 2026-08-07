// 実アプリのスナップショットへ検知を全数で当てるハーネス(誤検知の勘定用・普段は環境変数が
// 無いので何もしない)。自前 SUT は遮蔽・積み重なりの形を代表しないため、実アプリで1回当てる。
//   FT_SWEEP_DIR=<*.json のディレクトリ> swift test --filter SweepHarnessTests
import XCTest
import FTCore
@testable import ftester_mcp

final class SweepHarnessTests: XCTestCase {
    func testSweep() throws {
        guard let dir = ProcessInfo.processInfo.environment["FT_SWEEP_DIR"] else { return }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".json") }.sorted()
        for f in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(f))
            let snap = try JSONDecoder().decode(SnapshotResponse.self, from: data)
            let els = snap.elements
            var ghosts: [String] = [], overlays: [String] = []
            for e in els {
                if RefGuard.isUntappableGhost(e, in: els, screen: snap.screen) {
                    ghosts.append(e.identifier ?? e.label ?? "ref\(e.ref)")
                }
                if let o = RefGuard.overlayCovering(e, in: els, screen: snap.screen) {
                    overlays.append("\(e.identifier ?? e.label ?? "ref\(e.ref)")<-\(o.identifier ?? o.label ?? "ref\(o.ref)")")
                }
            }
            var misses: [String] = []
            for e in els {
                if let inner = RefGuard.missesItsOwnContent(e, in: els, screen: snap.screen) {
                    misses.append("\(e.identifier ?? "ref\(e.ref)")→\(inner.identifier ?? "ref\(inner.ref)")")
                }
            }
            let stacked = RefGuard.stackedRefs(els)
            print("SWEEP \(f) elements=\(els.count) z=\(els.contains { $0.z != nil })"
                + " ghost=\(ghosts.count) overlay=\(overlays.count) stacked=\(stacked.count)"
                + " missesContent=\(misses.count)")
            for m in misses.prefix(8) { print("SWEEP   misses: \(m)") }
            for g in ghosts.prefix(6) { print("SWEEP   ghost: \(g)") }
            for o in overlays.prefix(8) { print("SWEEP   overlay: \(o)") }
        }
    }
}
