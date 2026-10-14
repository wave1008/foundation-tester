import XCTest
@testable import FTServices

final class VariableExpansionTests: XCTestCase {
    private let path = ComposePath("services.s.environment.K")

    private func expand(
        _ text: String, secrets: [String: String] = [:], plain: [String: String] = [:], allow: Bool = true
    ) -> Result<Expanded, ComposeRefusal> {
        VariableExpansion.expand(
            text, dictionaries: ExpansionDictionaries(secrets: secrets, plain: plain), allowSecrets: allow, path: path)
    }

    private func value(_ text: String, secrets: [String: String] = [:], plain: [String: String] = [:]) throws -> String {
        try expand(text, secrets: secrets, plain: plain).get().value
    }

    func testPlainSyntaxes() throws {
        let plain = ["A": "x", "EMPTY": ""]
        XCTAssertEqual(try value("$A", plain: plain), "x")
        XCTAssertEqual(try value("${A}-$A", plain: plain), "x-x")
        XCTAssertEqual(try value("${MISSING:-d}", plain: plain), "d")
        XCTAssertEqual(try value("${EMPTY:-d}", plain: plain), "d")
        XCTAssertEqual(try value("${EMPTY-d}", plain: plain), "")
        XCTAssertEqual(try value("${MISSING-d}", plain: plain), "d")
        XCTAssertEqual(try value("${A:-d}", plain: plain), "x")
        XCTAssertEqual(try value("${MISSING:-${A}}", plain: plain), "x")
    }

    func testDoubleDollarIsLiteral() throws {
        XCTAssertEqual(try value("a$$b"), "a$b")
        XCTAssertEqual(try value("$${A}", plain: ["A": "x"]), "${A}")
    }

    func testUnsetVariableIsRefused() {
        XCTAssertEqual(
            { () -> ComposeRefusal? in if case .failure(let r) = expand("$NOPE") { return r } else { return nil } }(),
            .unsetVariable(path: path, name: "NOPE"))
        guard case .failure(.unsetVariable(_, "NOPE")) = expand("${NOPE}") else { return XCTFail("braced form") }
    }

    func testRequiredOperators() {
        guard case .failure(.badSubstitution(_, let detail)) = expand("${NOPE:?needs it}") else {
            return XCTFail("expected badSubstitution")
        }
        XCTAssertTrue(detail.contains("needs it"))
        guard case .failure(.badSubstitution) = expand("${NOPE?}") else { return XCTFail("expected badSubstitution") }
        XCTAssertEqual(try? expand("${A:?e}", plain: ["A": "1"]).get().value, "1")
    }

    func testMalformedSubstitutions() {
        for text in ["$", "a$-", "${", "${A", "${:-x}", "${A+x}", "${A:x}"] {
            guard case .failure(.badSubstitution) = expand(text, plain: ["A": "1"]) else {
                return XCTFail("expected badSubstitution for \(text)")
            }
        }
    }

    func testTwoLevelNestedDefaultIsRefused() {
        guard case .failure(.badSubstitution) = expand("${A:-${B:-${C}}}", plain: ["C": "1"]) else {
            return XCTFail("expected badSubstitution")
        }
    }

    func testSecretsWinOverPlain() throws {
        let expanded = try expand("$K", secrets: ["K": "secret"], plain: ["K": "plain"]).get()
        XCTAssertEqual(expanded.value, "secret")
        XCTAssertEqual(expanded.usedSecrets, ["K"])
    }

    func testSecretInForbiddenFieldIsRefused() {
        guard case .failure(let r) = expand("x/${TOKEN}", secrets: ["TOKEN": "t"], allow: false) else {
            return XCTFail("expected refusal")
        }
        XCTAssertEqual(r, .secretInForbiddenField(path: path, name: "TOKEN"))
    }

    func testPlainVariablesAreFineWhenSecretsAreForbidden() throws {
        let expanded = try expand("v$A", secrets: ["TOKEN": "t"], plain: ["A": "1"], allow: false).get()
        XCTAssertEqual(expanded.value, "v1")
        XCTAssertTrue(expanded.usedSecrets.isEmpty)
    }

    func testUsedSecretsListsOnlyExpandedNames() throws {
        let expanded = try expand(
            "a=${S1} b=$PLAIN c=${NOT_USED:-d}", secrets: ["S1": "x", "S2": "y", "NOT_USED": "z"], plain: ["PLAIN": "p"])
            .get()
        XCTAssertEqual(expanded.value, "a=x b=p c=z")
        XCTAssertEqual(expanded.usedSecrets, ["S1", "NOT_USED"])
    }

    /// 秘密の値に `${OTHER}` が含まれていても OTHER を拾わない(展開後の文字列を走査していない証明)。
    func testSecretValueContainingReferenceIsNotRescanned() throws {
        let expanded = try expand("$S", secrets: ["S": "has ${OTHER} inside", "OTHER": "o"]).get()
        XCTAssertEqual(expanded.value, "has ${OTHER} inside")
        XCTAssertEqual(expanded.usedSecrets, ["S"])
    }
}
