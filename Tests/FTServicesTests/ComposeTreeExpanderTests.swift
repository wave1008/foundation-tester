import XCTest
@testable import FTServices

final class ComposeTreeExpanderTests: XCTestCase {
    private let dictionaries = ExpansionDictionaries(
        secrets: ["TOKEN": "tok", "DB_PASSWORD": "pw"], plain: ["TAG": "1.2", "PORT": "8080"])

    private func tree(_ yaml: String) throws -> ComposeValue { try ComposeReader.read(yaml: yaml).get() }

    func testEnvironmentExpandsSecretsAndRecordsUsage() throws {
        let yaml = """
        services:
          db:
            image: postgres:${TAG}
            environment:
              POSTGRES_PASSWORD: ${DB_PASSWORD}
              PLAIN: ${TAG}
          server:
            image: x
            environment:
              - API=Bearer ${TOKEN}
              - UNUSED=1
        """
        let expanded = try ComposeTreeExpander.expand(try tree(yaml), dictionaries: dictionaries).get()
        XCTAssertEqual(expanded.usedSecretsByService, ["db": ["DB_PASSWORD"], "server": ["TOKEN"]])
        let spec = try ComposeNormalizer.normalize(expanded.value).get()
        XCTAssertEqual(spec.services[0].image, "postgres:1.2")
        XCTAssertEqual(spec.services[0].environment, [
            EnvEntry(key: "POSTGRES_PASSWORD", value: "pw"), EnvEntry(key: "PLAIN", value: "1.2"),
        ])
        XCTAssertEqual(spec.services[1].environment[0], EnvEntry(key: "API", value: "Bearer tok"))
    }

    private func assertForbiddenSecret(_ body: String, path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let yaml = "services:\n  app:\n" + body
        guard case .failure(let errors) = ComposeTreeExpander.expand(try tree(yaml), dictionaries: dictionaries) else {
            return XCTFail("expected refusal", file: file, line: line)
        }
        XCTAssertEqual(errors.items, [.secretInForbiddenField(path: ComposePath(path), name: "TOKEN")], file: file, line: line)
    }

    func testSecretInImageIsRefused() throws {
        try assertForbiddenSecret("    image: evil.example/${TOKEN}\n", path: "services.app.image")
    }

    func testSecretInBuildArgsIsRefused() throws {
        try assertForbiddenSecret(
            "    build:\n      context: ./scripts\n      args:\n        T: ${TOKEN}\n", path: "services.app.build.args.T")
    }

    func testSecretInPortsIsRefused() throws {
        try assertForbiddenSecret("    image: x\n    ports: [\"127.0.0.1:${TOKEN}:80\"]\n", path: "services.app.ports[0]")
    }

    func testSecretInCommandIsRefused() throws {
        try assertForbiddenSecret("    image: x\n    command: run ${TOKEN}\n", path: "services.app.command")
    }

    func testPlainVariableInPortsExpandsBeforeNormalizing() throws {
        let yaml = "services:\n  app:\n    image: x\n    ports: [\"127.0.0.1:${PORT}:80\"]\n"
        let expanded = try ComposeTreeExpander.expand(try tree(yaml), dictionaries: dictionaries).get()
        let spec = try ComposeNormalizer.normalize(expanded.value).get()
        XCTAssertEqual(spec.services[0].ports, [PortPublish(hostIP: "127.0.0.1", hostPort: 8080, containerPort: 80, proto: .tcp)])
    }

    func testIgnoredTopLevelKeysAreNotExpanded() throws {
        let yaml = "x-note: ${UNDEFINED}\nversion: \"3\"\nservices:\n  app:\n    image: x\n"
        XCTAssertNoThrow(try ComposeTreeExpander.expand(try tree(yaml), dictionaries: dictionaries).get())
    }

    func testIndirectReferenceViaDotEnvIsRefusedAtTheDotEnvStage() throws {
        guard case .failure(let refusal) = DotEnvFile.parse("TAG=${TOKEN}\n", dictionaries: dictionaries) else {
            return XCTFail("expected refusal")
        }
        XCTAssertEqual(refusal, .secretReferencedFromDotEnv(name: "TOKEN"))
    }
}
