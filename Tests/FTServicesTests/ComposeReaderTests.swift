import XCTest
@testable import FTServices

final class ComposeReaderTests: XCTestCase {
    private func read(_ yaml: String, _ limits: ComposeLimits = .standard) -> Result<ComposeValue, ComposeRefusal> {
        ComposeReader.read(yaml: yaml, limits: limits)
    }

    private func refusal(_ yaml: String, _ limits: ComposeLimits = .standard) -> ComposeRefusal? {
        if case .failure(let r) = read(yaml, limits) { return r }
        return nil
    }

    func testMapKeepsOrderAndTypes() throws {
        let yaml = """
        z: 1
        a: "8080"
        m:
          - true
          - 1.5
          - ~
          - plain
        """
        let value = try read(yaml).get()
        XCTAssertEqual(value, .map([
            ComposeMapEntry(key: "z", value: .int(1)),
            ComposeMapEntry(key: "a", value: .string("8080")),
            ComposeMapEntry(key: "m", value: .list([.bool(true), .double(1.5), .null, .string("plain")])),
        ]))
    }

    func testDuplicateKeyIsRefused() {
        // 重複は Yams が構文解析で断る = path はキー名だけ(親の "b." は付かない)
        XCTAssertEqual(refusal("a: 1\nb:\n  c: 1\n  c: 2\n"), .duplicateKey(path: ComposePath("c")))
    }

    func testMergeKeyIsRefused() {
        let yaml = "base: &b\n  x: 1\nother:\n  <<: *b\n"
        XCTAssertEqual(refusal(yaml), .unsupportedMergeKey(path: ComposePath("other")))
    }

    func testNonStringKeyIsRefused() {
        guard case .nonStringKey = refusal("1: a\n") else { return XCTFail("expected nonStringKey") }
    }

    func testMalformedYAML() {
        guard case .malformedYAML = refusal("a: [1, 2\n") else { return XCTFail("expected malformedYAML") }
    }

    func testByteLimit() {
        let limits = ComposeLimits(maxBytes: 10, maxNodes: 1000, maxDepth: 10)
        XCTAssertEqual(refusal("abcdefghijklmnop: 1\n", limits), .documentTooLarge(bytes: 20, limit: 10))
    }

    func testNodeLimit() {
        let limits = ComposeLimits(maxBytes: 1000, maxNodes: 3, maxDepth: 10)
        XCTAssertEqual(refusal("a: 1\nb: 2\nc: 3\n", limits), .tooManyNodes(limit: 3))
    }

    func testDepthLimit() {
        let limits = ComposeLimits(maxBytes: 1000, maxNodes: 1000, maxDepth: 2)
        XCTAssertEqual(refusal("a:\n  b:\n    c: 1\n", limits), .tooDeep(limit: 2))
    }

    /// 陽性対照: 小さな文書でもエイリアスの展開後の数で上限に当たる。
    func testAliasExpansionCountsTowardNodeLimit() {
        let refs = (0..<20).map { _ in "  - *a" }.joined(separator: "\n")
        let yaml = "a: &a [1, 2, 3, 4, 5]\nlist:\n" + refs + "\n"
        let limits = ComposeLimits(maxBytes: 100_000, maxNodes: 60, maxDepth: 10)
        XCTAssertEqual(refusal(yaml, limits), .tooManyNodes(limit: 60))
        XCTAssertNil(refusal(yaml, ComposeLimits(maxBytes: 100_000, maxNodes: 500, maxDepth: 10)))
    }
}
