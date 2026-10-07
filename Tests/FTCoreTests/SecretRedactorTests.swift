// account() の値の伏せ字化。最小長・JSON エスケープ形・長い値の優先・ConsoleOut の最後の網。

import XCTest
@testable import FTCore

final class SecretRedactorTests: XCTestCase {

    func testRegisteredValueIsMasked() {
        let redactor = SecretRedactor()
        redactor.register("p@ssw0rd")
        XCTAssertEqual(redactor.redact("type \"p@ssw0rd\" into #pw"), "type \"***\" into #pw")
        XCTAssertEqual(redactor.redact("nothing here"), "nothing here")
    }

    /// 4 文字未満は登録しない(無関係な文字列を壊す)。境界の 3 / 4 文字で確かめる
    func testShortValuesAreNotRegistered() {
        let redactor = SecretRedactor()
        redactor.register(["abc", "", "ab"])
        XCTAssertEqual(redactor.redact("abc ab is fine"), "abc ab is fine")
        redactor.register("abcd")
        XCTAssertEqual(redactor.redact("xabcdx"), "x***x")
        XCTAssertEqual(SecretRedactor.minimumLength, 4)
    }

    /// NDJSON の行では引用符・バックスラッシュが `\"` `\\` になる。両方の形で伏せる
    func testJSONEscapedFormIsMaskedInAJSONLine() throws {
        let secret = #"pa"ss\word"#
        let redactor = SecretRedactor()
        redactor.register(secret)
        var event = ScenarioEvent(kind: "step")
        event.description = "type \(secret)"
        let line = event.encodedLine()
        XCTAssertFalse(line.contains(secret), "前提: エンコード後は生の形では現れない")
        XCTAssertTrue(line.contains(#"pa\"ss\\word"#), line)
        let masked = redactor.redact(line)
        XCTAssertFalse(masked.contains(#"pa\"ss\\word"#), masked)
        XCTAssertNotNil(ScenarioEvent.decode(line: masked), "伏せた後も有効な JSON の1行")
        XCTAssertEqual(ScenarioEvent.decode(line: masked)?.description, "type ***")
    }

    /// ある値が別の値の一部でも、長い値を先に伏せて断片を残さない
    func testLongerValueIsMaskedBeforeItsSubstring() {
        let redactor = SecretRedactor()
        redactor.register("pass")
        redactor.register("password123")
        XCTAssertEqual(redactor.redact("password123"), "***")
    }

    func testStatusReasonsAreMappedAndOthersKept() {
        let status = StepResult.Status.failed("bad secretvalue")
        guard case .failed(let reason) = status.mappingReasons({ $0.replacingOccurrences(of: "secretvalue", with: "***") })
        else { return XCTFail() }
        XCTAssertEqual(reason, "bad ***")
        guard case .passed = StepResult.Status.passed.mappingReasons({ _ in "x" }) else { return XCTFail() }
    }

    /// 子の標準出力・標準エラーへの文字列の出力は全部 ConsoleOut を通る = 最後の網
    func testConsoleOutMasksRegisteredValues() throws {
        SecretRedactor.shared.register("console-secret")
        defer { SecretRedactor.shared.removeAll() }
        let pipe = Pipe()
        ConsoleOut.emit("line with console-secret inside", fd: pipe.fileHandleForWriting.fileDescriptor)
        try pipe.fileHandleForWriting.close()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(text, "line with *** inside\n")
    }
}
