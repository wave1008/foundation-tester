// xcodegen は廃止した(Xcode 27.2+ の JSON プロジェクト形式 project.xcproj をコミットする)。
// 再混入(呼び出し・project.yml・旧 pbxproj)をソース走査で落とす。

import XCTest

final class XcodegenRemovedTests: XCTestCase {
    private static var repo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let xcodeprojDirs = [
        "Runner/FleetestRunner.xcodeproj", "E2EAppIOS/FTE2EIOS.xcodeproj", "E2EXAppIOS/FTE2EXIOS.xcodeproj",
        "E2EYAppIOS/FTE2EYIOS.xcodeproj", "E2EAppCMP/iosApp/iosApp.xcodeproj",
        "E2EXAppCMP/iosApp/iosApp.xcodeproj", "E2EYAppCMP/iosApp/iosApp.xcodeproj",
    ]

    private func files(under relative: String) -> [URL] {
        let dir = Self.repo.appendingPathComponent(relative)
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    func testNoXcodegenMentionRemainsInSourcesScriptsAndSUTScripts() throws {
        let sutScripts = try FileManager.default.contentsOfDirectory(atPath: Self.repo.path)
            .filter { $0.hasPrefix("E2E") && $0.contains("App") }
            .map { "\($0)/scripts" }
        var scanned = 0
        var hits: [String] = []
        for root in ["Sources", "Scripts"] + sutScripts {
            for url in files(under: root) {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                if text.range(of: "xcodegen", options: .caseInsensitive) != nil {
                    hits.append(url.path.replacingOccurrences(of: Self.repo.path + "/", with: ""))
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "走査がファイルに届いていない")
        XCTAssertEqual(hits, [], "xcodegen が戻っている(プロジェクトは project.xcproj をコミットする)")
    }

    func testNoProjectYmlRemains() {
        let paths = ["Runner/project.yml", "E2EAppIOS/project.yml", "E2EXAppIOS/project.yml",
                     "E2EYAppIOS/project.yml", "E2EAppCMP/iosApp/project.yml",
                     "E2EXAppCMP/iosApp/project.yml", "E2EYAppCMP/iosApp/project.yml"]
        for path in paths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: Self.repo.appendingPathComponent(path).path),
                           "\(path) が戻っている")
        }
    }

    func testEveryXcodeprojUsesTheJSONFormatOnly() {
        for dir in Self.xcodeprojDirs {
            let base = Self.repo.appendingPathComponent(dir)
            XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("project.xcproj").path),
                          "\(dir)/project.xcproj が無い")
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("project.pbxproj").path),
                           "\(dir)/project.pbxproj が残っている(旧形式と並ぶと xcodebuild が読めずに落ちる)")
        }
    }
}
