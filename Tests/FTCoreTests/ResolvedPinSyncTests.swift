import XCTest
@testable import FTCore

final class ResolvedPinSyncTests: XCTestCase {

    private func resolved(_ pins: [(String, String)], originHash: String = "tool") -> Data {
        let object: [String: Any] = [
            "originHash": originHash,
            "pins": pins.map { identity, version in
                ["identity": identity, "kind": "remoteSourceControl",
                 "location": "https://example.com/\(identity)",
                 "state": ["revision": "r-\(version)", "version": version]] as [String: Any]
            },
            "version": 3,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func versions(_ data: Data?) -> [String: String] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = object["pins"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for pin in pins {
            out[pin["identity"] as! String] = (pin["state"] as! [String: Any])["version"] as? String
        }
        return out
    }

    func testWithoutAConsumerFileTheToolPinsAreTaken() {
        let out = ResolvedPinSync.merged(consumer: nil, tool: resolved([("swift-syntax", "603.0.2")]))
        XCTAssertEqual(versions(out), ["swift-syntax": "603.0.2"])
    }

    func testToolVersionsWinAndConsumerOnlyPinsAreKept() throws {
        let consumer = resolved([("swift-syntax", "604.0.0"), ("my-extra", "1.0.0")], originHash: "consumer")
        let out = ResolvedPinSync.merged(consumer: consumer, tool: resolved([("swift-syntax", "603.0.2")]))
        XCTAssertEqual(versions(out), ["swift-syntax": "603.0.2", "my-extra": "1.0.0"])
        let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(out)) as? [String: Any]
        XCTAssertEqual(object?["originHash"] as? String, "consumer", "受け手の originHash を残す")
    }

    func testAlreadyMatchingReturnsNil() {
        let pins = [("swift-syntax", "603.0.2")]
        XCTAssertNil(ResolvedPinSync.merged(consumer: resolved(pins, originHash: "consumer"), tool: resolved(pins)))
    }

    func testUnreadableConsumerIsLeftAlone() {
        XCTAssertNil(ResolvedPinSync.merged(consumer: Data("not json".utf8), tool: resolved([("a", "1.0.0")])))
    }

    func testSyncCopiesFromThePathDependencyAndIsIdempotent() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResolvedPinSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let tool = base.appendingPathComponent("foundation-tester")
        let work = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: tool, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try resolved([("swift-syntax", "603.0.2")]).write(to: tool.appendingPathComponent("Package.resolved"))
        try #"let package = Package(dependencies: [.package(path: "../foundation-tester"),])"#
            .write(to: work.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        XCTAssertTrue(try ResolvedPinSync.sync(packageRoot: work))
        XCTAssertEqual(versions(try Data(contentsOf: work.appendingPathComponent("Package.resolved"))),
                       ["swift-syntax": "603.0.2"])
        XCTAssertFalse(try ResolvedPinSync.sync(packageRoot: work), "2回目は変わらないので書かない")
    }

    func testSyncDoesNothingWithoutAPathDependency() throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResolvedPinSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try #"let package = Package(dependencies: [.package(url: "https://x", branch: "main"),])"#
            .write(to: work.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        XCTAssertFalse(try ResolvedPinSync.sync(packageRoot: work))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("Package.resolved").path))
    }

    func testPinnedResolveOnlyBeforeTheFirstResolution() throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResolvedPinSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work.appendingPathComponent(".build"),
                                                withIntermediateDirectories: true)
        XCTAssertFalse(ResolvedPinSync.pinnedResolveNeeded(packageRoot: work), "Package.resolved が無い")
        try resolved([("a", "1.0.0")]).write(to: work.appendingPathComponent("Package.resolved"))
        XCTAssertTrue(ResolvedPinSync.pinnedResolveNeeded(packageRoot: work))
        try Data("{}".utf8).write(to: work.appendingPathComponent(".build/workspace-state.json"))
        XCTAssertFalse(ResolvedPinSync.pinnedResolveNeeded(packageRoot: work), "解決済み")
    }
}
