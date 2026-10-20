// buildAndroidWorkers/buildIOSWorkers/buildWorkers(供給。Wipe Data・古いブリッジ停止・凍結デバイスの
// 再起動などの破壊的操作を含み数十秒かかりうる)は必ず
// `ProfileRunner.buildWorkersWithFrontLoadedLease` 経由で呼ぶことをソース走査で固定する。
//
// この砦が要る理由(負荷テスト実測。maintainer-notes §51.3): `api run` は build → reject → hold の
// 順で lease を後付けしていたため、供給中は run-lease が無く、並行の `api stop-device` が
// 供給中のシミュレータを止めて run を落とした(bridge start-up timed out … BUILD INTERRUPTED)。
// `fleetest run` 側は既に前倒し(reject→hold→build→reject/hold→release)だったので、
// **CLAUDE.md「run と api run は別配線の2実装」どおり片方だけが穴を持っていた**。
// 共通ヘルパへ寄せたことで2経路が同じ実装を通るが、将来どちらかが直呼びへ戻っても
// swift test は落ちない(型で守れない継ぎ目)ため、ここで固定する。

import XCTest

final class DeviceLeaseFrontLoadWiringTests: XCTestCase {

    /// 供給を呼ぶファイル。手順は ProfileSupplyLanes に集まっているが、呼び手に直呼びが戻ったときも落とすため3つとも見る
    private static let sources = ["Sources/fleetest/ProfileSupplyLanes.swift", "Sources/fleetest/ProfileRunner.swift",
                                  "Sources/fleetest/ApiRunCommand.swift"]

    private static func codeLines(_ path: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("//") ? "" : trimmed
        }
    }

    /// 供給の実体呼び出し(buildAndroidWorkers/buildIOSWorkers/buildWorkers)の本数と、
    /// 前倒しヘルパの呼び出し本数が一致し、**ヘルパの呼び出しが必ず同じ行以前に現れる**こと
    /// (`helper(...) { ...build(...)... }` の形なので、ヘルパの呼び出し開始行は build 呼び出しの
    /// 行と同じか、それより前になる)。本数が食い違えば、どこかの供給呼び出しがヘルパを
    /// 経由していない(= lease の前倒しが無い)
    func testEverySupplyBuildCallGoesThroughTheFrontLoadedLeaseHelper() throws {
        var buildCallsSeen = 0
        defer {
            // 0 本どうしの一致で緑にしない(供給の置き場が移ったら sources を追う)
            XCTAssertGreaterThan(buildCallsSeen, 0, "走査が供給の呼び出しに届いていない")
        }
        for path in Self.sources {
            let lines = try Self.codeLines(path)
            let helperCallIndices = lines.indices.filter { idx in
                let line = lines[idx]
                return line.contains("buildWorkersWithFrontLoadedLease(")
                    && !line.contains("static func buildWorkersWithFrontLoadedLease")
            }
            let buildCallIndices = lines.indices.filter { idx in
                let line = lines[idx]
                return line.contains("ProfileWorkerFactory.buildAndroidWorkers(")
                    || line.contains("ProfileWorkerFactory.buildIOSWorkers(")
                    || line.contains("ProfileWorkerFactory.buildWorkers(")
            }
            buildCallsSeen += buildCallIndices.count
            XCTAssertEqual(helperCallIndices.count, buildCallIndices.count,
                           "\(path): 供給呼び出しと前倒しヘルパの呼び出し本数が一致しない" +
                           " (helper=\(helperCallIndices.count) build=\(buildCallIndices.count))")
            for (helper, build) in zip(helperCallIndices, buildCallIndices) {
                XCTAssertLessThanOrEqual(helper, build,
                                         "\(path): 供給呼び出しが前倒しヘルパの外に出ている" +
                                         " (build call at line \(build), helper at line \(helper))")
            }
        }
    }

    /// 定義は `ProfileRunner` の1箇所だけ(2つ目の実装を作らない。作ると2経路がまた別々の
    /// 前倒し規則を持ちうる)
    func testHelperHasExactlyOneDefinition() throws {
        let text = try Self.codeLines("Sources/fleetest/ProfileRunner.swift").joined(separator: "\n")
        let count = text.components(separatedBy: "static func buildWorkersWithFrontLoadedLease(").count - 1
        XCTAssertEqual(count, 1, "buildWorkersWithFrontLoadedLease の定義が ProfileRunner に1箇所ではない")
    }

    /// 供給のレーン(ProfileSupplyLanes)は定義を持たず、`ProfileRunner` のものを Android・iOS で1本ずつ呼ぶ。
    /// `ApiRunCommand` は定義を持たない(供給はレーン経由 = ProfileSupplyLanesWiringTests)
    func testSupplyLanesHaveNoSecondImplementationAndCallTheSharedOne() throws {
        let lanes = try Self.codeLines("Sources/fleetest/ProfileSupplyLanes.swift").joined(separator: "\n")
        XCTAssertFalse(lanes.contains("static func buildWorkersWithFrontLoadedLease"),
                       "ProfileSupplyLanes.swift に2つ目の実装がある")
        let callCount = lanes.components(separatedBy: "ProfileRunner.buildWorkersWithFrontLoadedLease(").count - 1
        XCTAssertEqual(callCount, 2, "レーンの共有ヘルパ呼び出し本数が想定と違う(Android / iOS の2箇所のはず。いま \(callCount) 箇所)")
        let api = try Self.codeLines("Sources/fleetest/ApiRunCommand.swift").joined(separator: "\n")
        XCTAssertFalse(api.contains("static func buildWorkersWithFrontLoadedLease"),
                       "ApiRunCommand.swift に2つ目の実装がある")
    }
}
