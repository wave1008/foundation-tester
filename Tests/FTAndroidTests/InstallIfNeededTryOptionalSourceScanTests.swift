// ProfileWorkerFactory.installIfNeeded は、1台でも install に失敗すればそのワーカーを離脱させ、
// **全滅したときだけ** throw する(CLAUDE.md「インストール失敗ワーカーは離脱し残りが続行する」)。
// 呼び出し側が `try?` で受けると、この全滅の throw も握りつぶされて**失敗前(= 古いアプリの
// まま)のワーカー一覧へ静かに戻る**(F5 実害: 実機 SE3 で devicectl install が失敗したのに、
// 端末に残っていた古いアプリで run が走った)。
//
// 呼び出し側は必ず do/catch(または `try` で外側の catch へ伝播)で受け、失敗したレーンは
// 空(nil)として扱うこと —— 古いアプリのまま実行を続けてはいけない。

import Foundation
import XCTest

final class InstallIfNeededTryOptionalSourceScanTests: XCTestCase {

    private static let needles = [
        "try? await ProfileWorkerFactory.installIfNeeded",
        "try? await installIfNeeded",
    ]

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FTAndroidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Sources")
    }

    func testNoCallerSilentlyDiscardsAnInstallFailure() throws {
        let root = Self.sourcesRoot
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("Sources を走査できない")
        }
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let relative = "Sources" + url.path.dropFirst(root.path.count)
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//")[0]
                for needle in Self.needles where code.contains(needle) {
                    offenders.append("\(relative):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], """
            installIfNeeded を try? で受けている —— 全滅の throw が握りつぶされ、失敗前の \
            (古いアプリのままの)ワーカー一覧へ静かに戻る。do/catch で受け、失敗したレーンは \
            空(nil)として扱うこと。
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// 走査が Sources に届いていることの sanity check(0件で素通りする変異と区別する)
    func testTheScanActuallyReadsSources() {
        let root = Self.sourcesRoot
        var swiftFiles = 0
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" { swiftFiles += 1 }
        }
        XCTAssertGreaterThan(swiftFiles, 100, "Sources 配下を走査できていない")
    }
}
