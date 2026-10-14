import XCTest
@testable import FTServices

final class DotEnvFileTests: XCTestCase {
    private func parse(_ text: String, secrets: [String: String] = [:], plain: [String: String] = [:])
        -> Result<[(key: String, value: String)], ComposeRefusal> {
        DotEnvFile.parse(text, dictionaries: ExpansionDictionaries(secrets: secrets, plain: plain))
    }

    private func pairs(_ text: String) throws -> [String] {
        try parse(text).get().map { "\($0.key)=\($0.value)" }
    }

    func testThreeQuotingForms() throws {
        let text = """
        A=plain value  # trailing comment
        B='single ${X} \\n literal'
        C="double \\"q\\" \\n tab\\t"
        """
        XCTAssertEqual(try pairs(text), [
            "A=plain value",
            "B=single ${X} \\n literal",
            "C=double \"q\" \n tab\t",
        ])
    }

    func testCommentsBlankLinesAndExport() throws {
        XCTAssertEqual(try pairs("# comment\n\nexport A=1\n  B = 2\n"), ["A=1", "B=2"])
    }

    func testReferenceToEarlierLine() throws {
        XCTAssertEqual(try pairs("A=1\nB=${A}-x\nC=\"$B!\"\n"), ["A=1", "B=1-x", "C=1-x!"])
    }

    func testMultiLineDoubleQuote() throws {
        XCTAssertEqual(try pairs("A=\"one\ntwo\"\nB=3\n"), ["A=one\ntwo", "B=3"])
    }

    func testSecretReferenceIsRefused() {
        guard case .failure(let r) = parse("TAG=${TOKEN}\n", secrets: ["TOKEN": "t"]) else {
            return XCTFail("expected refusal")
        }
        XCTAssertEqual(r, .secretReferencedFromDotEnv(name: "TOKEN"))
    }

    func testSecretReferenceInsideDoubleQuotesIsRefused() {
        guard case .failure(.secretReferencedFromDotEnv("TOKEN")) = parse("TAG=\"x-$TOKEN\"\n", secrets: ["TOKEN": "t"]) else {
            return XCTFail("expected refusal")
        }
    }

    func testSingleQuotedSecretReferenceIsLiteral() throws {
        let result = try parse("TAG='${TOKEN}'\n", secrets: ["TOKEN": "t"]).get()
        XCTAssertEqual(result.first?.value, "${TOKEN}")
    }

    func testMalformedLines() {
        guard case .failure(.invalidValue) = parse("no equals here\n") else { return XCTFail("no equals") }
        guard case .failure(.invalidValue) = parse("A='open\n") else { return XCTFail("unterminated") }
        guard case .failure(.invalidValue) = parse("bad key=1\n") else { return XCTFail("bad key") }
    }
}
