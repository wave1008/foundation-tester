// xcodegen の場所(XcodegenLocator)。非対話の ssh の PATH(Homebrew も ~/.local/bin も無い)で、ランナーの作り直しが
// `env: xcodegen: No such file or directory` で全デバイスの供給を落とした形の再発防止

import XCTest
@testable import FTCore

final class XcodegenLocatorTests: XCTestCase {
    private let bare = "/usr/bin:/bin:/usr/sbin:/sbin"

    func testPathIsSearchedFirst() {
        let found = XcodegenLocator.find(environment: ["PATH": "/tools/bin:" + bare, "HOME": "/Users/u"],
                                         isExecutable: { $0 == "/tools/bin/xcodegen" || $0 == "/opt/homebrew/bin/xcodegen" })
        XCTAssertEqual(found, "/tools/bin/xcodegen")
    }

    /// M1Ultra の形: 非対話の PATH には無く、~/.local/bin に置いてある
    func testUserLocalBinIsFoundWhenThePathIsBare() {
        let found = XcodegenLocator.find(environment: ["PATH": bare, "HOME": "/Users/u"],
                                         isExecutable: { $0 == "/Users/u/.local/bin/xcodegen" })
        XCTAssertEqual(found, "/Users/u/.local/bin/xcodegen")
    }

    func testMissingEverywhereIsNilAndTheMessageNamesWhereItLooked() {
        XCTAssertNil(XcodegenLocator.find(environment: ["PATH": bare, "HOME": "/Users/u"], isExecutable: { _ in false }))
        let message = XcodegenLocator.notFoundMessage(environment: ["PATH": bare, "HOME": "/Users/u"])
        XCTAssertTrue(message.contains(bare), message)
        XCTAssertTrue(message.contains("/Users/u/.local/bin"), message)
        XCTAssertTrue(message.contains("/opt/homebrew/bin"), message)
    }

    /// 素の "xcodegen" を PATH 任せで撃つ・`which xcodegen` で確かめる書き方を Sources に戻さない(探し方は XcodegenLocator の1箇所)
    func testNoSourceRunsXcodegenThroughThePathDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 100, "走査が Sources に届いていない")
        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(#"["xcodegen""#) || text.contains(#""which", "xcodegen""#) {
                hits.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(hits, [])
    }
}
