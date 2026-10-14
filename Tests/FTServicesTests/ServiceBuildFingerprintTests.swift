import XCTest
@testable import FTServices

final class ServiceBuildFingerprintTests: XCTestCase {
    private func base() -> FingerprintInputs {
        FingerprintInputs(
            files: [
                FileFact(relativePath: "a.txt", size: 10, mtimeNanoseconds: 1_000, mode: 0o644, kind: .file),
                FileFact(relativePath: "src", size: 0, mtimeNanoseconds: 2_000, mode: 0o755, kind: .directory),
            ],
            dockerfileContents: "FROM alpine\n", args: ["A": "1", "B": "2"], target: "prod", platform: "linux/arm64")
    }

    func testSameInputSameValueAnd64Hex() {
        let v = ServiceBuildFingerprint.compute(base())
        XCTAssertEqual(v, ServiceBuildFingerprint.compute(base()))
        XCTAssertEqual(v.count, 64)
        XCTAssertTrue(v.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testFileOrderIrrelevant() {
        var i = base()
        i.files.reverse()
        XCTAssertEqual(ServiceBuildFingerprint.compute(i), ServiceBuildFingerprint.compute(base()))
    }

    private func assertChanges(_ mutate: (inout FingerprintInputs) -> Void, _ msg: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        var i = base()
        mutate(&i)
        XCTAssertNotEqual(ServiceBuildFingerprint.compute(i), ServiceBuildFingerprint.compute(base()), msg, file: file, line: line)
    }

    func testSizeChanges() { assertChanges({ $0.files[0].size = 11 }, "size") }
    func testMtimeChanges() { assertChanges({ $0.files[0].mtimeNanoseconds = 1_001 }, "mtime") }
    func testModeChanges() { assertChanges({ $0.files[0].mode = 0o755 }, "mode") }
    func testKindChanges() { assertChanges({ $0.files[0].kind = .symlink }, "kind") }
    func testPathChanges() { assertChanges({ $0.files[0].relativePath = "b.txt" }, "path") }
    func testFileAddedChanges() {
        assertChanges({ $0.files.append(FileFact(relativePath: "z", size: 1, mtimeNanoseconds: 1, mode: 0o644, kind: .file)) }, "added")
    }
    func testDockerfileChanges() { assertChanges({ $0.dockerfileContents = "FROM alpine:3\n" }, "dockerfile") }
    func testArgValueChanges() { assertChanges({ $0.args["A"] = "9" }, "arg value") }
    func testArgAddedChanges() { assertChanges({ $0.args["C"] = "3" }, "arg added") }
    func testTargetChanges() { assertChanges({ $0.target = "dev" }, "target") }
    func testPlatformChanges() { assertChanges({ $0.platform = "linux/amd64" }, "platform") }
    func testTargetNilVsEmptyDiffer() {
        var a = base(); a.target = nil
        var b = base(); b.target = ""
        XCTAssertNotEqual(ServiceBuildFingerprint.compute(a), ServiceBuildFingerprint.compute(b))
    }
    func testPlatformNilVsEmptyDiffer() {
        var a = base(); a.platform = nil
        var b = base(); b.platform = ""
        XCTAssertNotEqual(ServiceBuildFingerprint.compute(a), ServiceBuildFingerprint.compute(b))
    }

    // MARK: DockerIgnore

    private func ignored(_ path: String, _ text: String) -> Bool {
        DockerIgnore.isIgnored(path, rules: DockerIgnore.parse(text))
    }

    func testParseSkipsBlankAndComments() {
        XCTAssertEqual(DockerIgnore.parse("\n# c\n  \n*.log\n").count, 1)
    }

    func testStarDoesNotCrossSlash() {
        XCTAssertTrue(ignored("a.log", "*.log"))
        XCTAssertFalse(ignored("dir/a.log", "*.log"))
        XCTAssertFalse(ignored("a.txt", "*.log"))
    }

    func testDirectoryPatternCoversContents() {
        XCTAssertTrue(ignored("build/out/x.o", "build/"))
        XCTAssertTrue(ignored("build", "build/"))
        XCTAssertFalse(ignored("rebuild/x", "build/"))
    }

    func testDoubleStarAnyDepth() {
        XCTAssertTrue(ignored("node_modules", "**/node_modules"))
        XCTAssertTrue(ignored("a/b/node_modules/x.js", "**/node_modules"))
        XCTAssertFalse(ignored("a/node_modules2", "**/node_modules"))
    }

    func testNegationReincludes() {
        let t = "*.log\n!keep.log"
        XCTAssertTrue(ignored("a.log", t))
        XCTAssertFalse(ignored("keep.log", t))
    }

    func testNegationBeforeIsOverriddenByLaterRule() {
        XCTAssertTrue(ignored("keep.log", "!keep.log\n*.log"))
    }

    func testLeadingSlashIsRootRelative() {
        XCTAssertTrue(ignored("x.tmp", "/x.tmp"))
        XCTAssertFalse(ignored("dir/x.tmp", "/x.tmp"))
    }

    func testQuestionMarkAndClass() {
        XCTAssertTrue(ignored("a1.c", "a?.c"))
        XCTAssertFalse(ignored("a12.c", "a?.c"))
        XCTAssertTrue(ignored("fb.txt", "f[a-c].txt"))
        XCTAssertFalse(ignored("fd.txt", "f[a-c].txt"))
        XCTAssertTrue(ignored("fd.txt", "f[^a-c].txt"))
    }

    func testDockerfileAndDockerignoreAlwaysSent() {
        XCTAssertFalse(ignored("Dockerfile", "*"))
        XCTAssertFalse(ignored(".dockerignore", "*"))
        XCTAssertTrue(ignored("other", "*"))
    }
}
