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
            // **警告の密度**: ref でその要素を叩いたとき警告が付くか。多すぎれば検知ではなく雑音で、
            // 読み手は全部読み飛ばす(2026-08-07 に検知を4種足したので自分で採点する)
            var warned = 0, tappable = 0, warnedTappable = 0, disabled = 0
            for e in els {
                let hits = RefGuard.isUntappableGhost(e, in: els, screen: snap.screen)
                    || RefGuard.overlayCovering(e, in: els, screen: snap.screen) != nil
                    || stacked.contains(e.ref)
                    || RefGuard.missesItsOwnContent(e, in: els, screen: snap.screen) != nil
                    || !e.enabled
                if !e.enabled { disabled += 1 }
                if hits { warned += 1 }
                if RefGuard.interactiveTypes.contains(e.type) {
                    tappable += 1
                    if hits {
                        warnedTappable += 1
                        let why = RefGuard.isUntappableGhost(e, in: els, screen: snap.screen) ? "ghost"
                            : RefGuard.overlayCovering(e, in: els, screen: snap.screen) != nil ? "overlay"
                            : stacked.contains(e.ref) ? "stacked"
                            : RefGuard.missesItsOwnContent(e, in: els, screen: snap.screen) != nil ? "misses"
                            : "disabled"
                        print("DENSITY   warned-tappable: \(e.identifier ?? e.label ?? "ref\(e.ref)")"
                            + " [\(e.type)] ← \(why)")
                    }
                }
            }
            let pct = tappable == 0 ? 0 : warnedTappable * 100 / tappable
            print("DENSITY \(f) elements=\(els.count) warned=\(warned)"
                + " | tappable=\(tappable) warnedTappable=\(warnedTappable) (\(pct)%)"
                + " | disabled=\(disabled)")
            print("SWEEP \(f) elements=\(els.count) z=\(els.contains { $0.z != nil })"
                + " ghost=\(ghosts.count) overlay=\(overlays.count) stacked=\(stacked.count)"
                + " missesContent=\(misses.count)")
            for m in misses.prefix(8) { print("SWEEP   misses: \(m)") }
            for g in ghosts.prefix(6) { print("SWEEP   ghost: \(g)") }
            for o in overlays.prefix(8) { print("SWEEP   overlay: \(o)") }
        }
    }
}
