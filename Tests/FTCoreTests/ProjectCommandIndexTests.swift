import XCTest
@testable import FTCore

final class ProjectCommandIndexTests: XCTestCase {

    // MARK: - scan(source:file:)

    func testSingleLine() {
        let result = ProjectCommandIndex.scan(source: """
            @FTCommand("Logs a user in and waits for the home screen")
            func login(user: String, password: String) {
                tap("#login_email")
            }
            """, file: "Helpers.swift")
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.commands.count, 1)
        let entry = result.commands[0]
        XCTAssertEqual(entry.name, "login")
        XCTAssertEqual(entry.signature, "login(user:, password:)")
        XCTAssertEqual(entry.summary, "Logs a user in and waits for the home screen")
        XCTAssertNil(entry.receiver)
        XCTAssertEqual(entry.file, "Helpers.swift")
        XCTAssertEqual(entry.line, 2)
    }

    func testMultiLineParamsWithDefaultsContainingParensAndClosures() {
        let result = ProjectCommandIndex.scan(source: """
            @FTCommand("Logs in and retries once on failure")
            func loginWithRetry(user: String,
                                 password: String,
                                 tags: [String] = ["default", "retry"],
                                 retries: Int = max(1, 3),
                                 onSuccess: @escaping (Bool) -> Void = { _ in }) {
                // body
            }
            """, file: "Helpers.swift")
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.commands.count, 1)
        let entry = result.commands[0]
        XCTAssertEqual(entry.name, "loginWithRetry")
        // 末尾がクロージャ型なので括弧の外へ出る。中身の "," (max(1, 3) / ["default", "retry"]) は
        // トップレベルの区切りと誤認しない
        XCTAssertEqual(entry.signature, "loginWithRetry(user:, password:, tags:, retries:) { }")
        XCTAssertEqual(entry.line, 2)
    }

    func testTrailingClosureOnlyParamOmitsParens() {
        let result = ProjectCommandIndex.scan(source: """
            @FTCommand("Runs a block with the toast dismissed")
            func withToastDismissed(_ body: () -> Void) {
                body()
            }
            """, file: "Helpers.swift")
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.commands.map(\.signature), ["withToastDismissed { }"])
    }

    func testExtensionFTElementMethodGetsReceiver() {
        let result = ProjectCommandIndex.scan(source: """
            extension FTElement {
                @FTCommand("Selects and dismisses a toast anchored to this element")
                func dismissToast(waitSeconds: Double = 3) {
                }
            }
            """, file: "Helpers.swift")
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.commands.count, 1)
        let entry = result.commands[0]
        XCTAssertEqual(entry.name, "dismissToast")
        XCTAssertEqual(entry.signature, "dismissToast(waitSeconds:)")
        XCTAssertEqual(entry.receiver, "FTElement")
    }

    func testTopLevelFunctionHasNoReceiver() {
        let result = ProjectCommandIndex.scan(source: """
            @FTCommand("Top-level helper")
            func topLevelHelper() {
            }
            """, file: "Helpers.swift")
        guard let entry = result.commands.first else {
            return XCTFail("expected one command")
        }
        XCTAssertNil(entry.receiver)
    }

    func testOtherAttributesBetweenMarkerAndFunc() {
        let result = ProjectCommandIndex.scan(source: """
            @FTCommand("Returns the count of unread items")
            @discardableResult
            func unreadCount() -> Int {
                return 0
            }
            """, file: "Helpers.swift")
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.commands.map(\.name), ["unreadCount"])
        XCTAssertEqual(result.commands.map(\.signature), ["unreadCount()"])
    }

    func testCommentedOutMarkerIsIgnored() {
        let result = ProjectCommandIndex.scan(source: """
            // @FTCommand("disabled helper")
            // func disabledHelper() {}

            /*
            @FTCommand("also disabled")
            func alsoDisabled() {}
            */

            @FTCommand("Still enabled")
            func stillEnabled() {}
            """, file: "Helpers.swift")
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.commands.map(\.name), ["stillEnabled"])
    }

    func testMarkerInsideAStringIsIgnored() {
        let result = ProjectCommandIndex.scan(source: #"""
            let note = "Remember: @FTCommand(\"fake\") is not real"

            @FTCommand("Real one")
            func realOne() {}
            """#, file: "Helpers.swift")
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.commands.map(\.name), ["realOne"])
    }

    func testPrivateFunctionBecomesAWarningNotACommand() {
        let result = ProjectCommandIndex.scan(source: """
            @FTCommand("Internal helper, not exposed")
            private func internalHelper() {}
            """, file: "Helpers.swift")
        XCTAssertEqual(result.commands, [])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("internalHelper"), result.warnings[0])
        XCTAssertTrue(result.warnings[0].contains("private"), result.warnings[0])
    }

    func testFileprivateFunctionBecomesAWarningNotACommand() {
        let result = ProjectCommandIndex.scan(source: """
            @FTCommand("Internal helper, not exposed")
            fileprivate func internalHelper() {}
            """, file: "Helpers.swift")
        XCTAssertEqual(result.commands, [])
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testMissingFuncAfterMarkerIsIgnoredWithAWarning() {
        let result = ProjectCommandIndex.scan(source: """
            @FTCommand("Not a function")
            var notAFunction = 1
            """, file: "Helpers.swift")
        XCTAssertEqual(result.commands, [])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("not followed by a func"), result.warnings[0])
    }

    func testEmptySummaryIsIgnoredWithAWarning() {
        let result = ProjectCommandIndex.scan(source: """
            @FTCommand("")
            func x() {}
            """, file: "Helpers.swift")
        XCTAssertEqual(result.commands, [])
        XCTAssertEqual(result.warnings.count, 1)
    }

    // MARK: - scan(project:) — ファイル走査 + 組み込みとの衝突検知

    var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("scenarios"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func write(_ relativePath: String, _ content: String) throws {
        let url = rootURL.appendingPathComponent("scenarios").appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testCollisionWithABuiltinNameWarns() throws {
        try write("Helpers.swift", """
            @FTCommand("Shadows the built-in tap")
            func tap(times: Int) {}
            """)
        let project = TestProject(name: "p", rootURL: rootURL)
        let result = ProjectCommandIndex.scan(project: project)
        XCTAssertEqual(result.commands.map(\.name), ["tap"])
        XCTAssertTrue(result.warnings.contains { $0.contains("tap") && $0.contains("built-in") },
                      result.warnings.description)
    }

    func testScansMultipleFilesAndSkipsDisabled() throws {
        try write("Helpers.swift", """
            @FTCommand("Helper A")
            func helperA() {}
            """)
        try write("Nested/More.swift", """
            @FTCommand("Helper B")
            func helperB() {}
            """)
        try write("_disabled/Old.swift", """
            @FTCommand("Old helper, quarantined")
            func oldHelper() {}
            """)
        let project = TestProject(name: "p", rootURL: rootURL)
        let result = ProjectCommandIndex.scan(project: project)
        XCTAssertEqual(Set(result.commands.map(\.name)), Set(["helperA", "helperB"]))
        XCTAssertEqual(result.warnings, [])
    }

    func testNoFTCommandMarkersProducesEmptyResult() throws {
        try write("Plain.swift", "class NotAHelper {}")
        let project = TestProject(name: "p", rootURL: rootURL)
        let result = ProjectCommandIndex.scan(project: project)
        XCTAssertEqual(result.commands, [])
        XCTAssertEqual(result.warnings, [])
    }
}
