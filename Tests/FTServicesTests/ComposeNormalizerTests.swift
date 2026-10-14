import XCTest
@testable import FTServices

final class ComposeNormalizerTests: XCTestCase {
    private func normalize(_ yaml: String) throws -> Result<ServiceSpec, ComposeRefusals> {
        ComposeNormalizer.normalize(try ComposeReader.read(yaml: yaml).get())
    }

    private func spec(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) throws -> ServiceSpec {
        switch try normalize(yaml) {
        case .success(let spec): return spec
        case .failure(let errors):
            XCTFail("unexpected refusals: \(errors.map(\.message))", file: file, line: line)
            throw errors[0]
        }
    }

    private func refusals(_ yaml: String) throws -> [ComposeRefusal] {
        if case .failure(let errors) = try normalize(yaml) { return errors.items }
        return []
    }

    /// 最小のサービスを足した compose.yaml を作る(禁止キーの1件ずつのテスト用)。
    private func svc(_ extra: String) -> String {
        "services:\n  app:\n    image: x\n" + extra.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n") + "\n"
    }

    // MARK: 正常系

    func testRepresentativeComposeFile() throws {
        let yaml = """
        version: "3.8"
        x-common: &c
          anything: goes
        services:
          db:
            image: postgres:16
            environment:
              POSTGRES_PASSWORD: pw
              FLAG:
            ports: ["127.0.0.1:5432:5432"]
            volumes:
              - pgdata:/var/lib/postgresql/data
            healthcheck:
              test: ["CMD-SHELL", "pg_isready -U postgres"]
              interval: 5s
              retries: 10
            networks: [backend]
          server:
            build:
              context: ./scripts/server
              target: runtime
              args: {A: "1"}
            command: java -jar "app dir/app.jar"
            environment:
              - DB_URL=jdbc:postgresql://db:5432/app
              - DEBUG
            ports:
              - target: 8080
                published: 8080
                host_ip: 127.0.0.1
                protocol: tcp
            volumes:
              - ./scripts:/scripts:ro
              - type: tmpfs
                target: /tmp
            depends_on:
              db:
                condition: service_healthy
            networks: [backend]
          stub:
            image: wiremock/wiremock
            depends_on: [server]
            ports: ["9090:8080/udp"]
        networks:
          backend:
            internal: true
        volumes:
          pgdata:
        """
        let result = try spec(yaml)
        XCTAssertEqual(result.ignoredTopLevelKeys, ["version", "x-common"])
        XCTAssertEqual(result.networks, [NetworkDef(name: "backend", internal: true)])
        XCTAssertEqual(result.volumes, [VolumeDef(name: "pgdata")])
        XCTAssertEqual(result.services.map(\.name), ["db", "server", "stub"])
        XCTAssertEqual(result.services[0], ServiceDef(
            name: "db", image: "postgres:16",
            environment: [EnvEntry(key: "POSTGRES_PASSWORD", value: "pw"), EnvEntry(key: "FLAG", value: nil)],
            ports: [PortPublish(hostIP: "127.0.0.1", hostPort: 5432, containerPort: 5432, proto: .tcp)],
            mounts: [.volume(name: "pgdata", target: "/var/lib/postgresql/data", readOnly: false)],
            healthcheck: Healthcheck(test: .cmdShell("pg_isready -U postgres"), interval: "5s", retries: 10),
            networks: ["backend"]))
        XCTAssertEqual(result.services[1], ServiceDef(
            name: "server",
            build: BuildDef(context: "./scripts/server", dockerfile: nil, args: ["A": "1"], target: "runtime"),
            command: ["java", "-jar", "app dir/app.jar"],
            environment: [EnvEntry(key: "DB_URL", value: "jdbc:postgresql://db:5432/app"), EnvEntry(key: "DEBUG", value: nil)],
            ports: [PortPublish(hostIP: "127.0.0.1", hostPort: 8080, containerPort: 8080, proto: .tcp)],
            mounts: [.bind(source: "./scripts", target: "/scripts", readOnly: true)],
            tmpfs: ["/tmp"],
            dependsOn: [Dependency(service: "db", condition: .serviceHealthy)],
            networks: ["backend"]))
        XCTAssertEqual(result.services[2], ServiceDef(
            name: "stub", image: "wiremock/wiremock",
            ports: [PortPublish(hostIP: nil, hostPort: 9090, containerPort: 8080, proto: .udp)],
            dependsOn: [Dependency(service: "server", condition: .serviceStarted)]))
    }

    func testHealthcheckForms() throws {
        let result = try spec(svc("""
        healthcheck:
          test: ["CMD", "curl", "-f", "http://localhost"]
        """))
        XCTAssertEqual(result.services[0].healthcheck?.test, .cmd(["curl", "-f", "http://localhost"]))
        let none = try spec(svc("healthcheck:\n  test: [\"NONE\"]\n"))
        XCTAssertEqual(none.services[0].healthcheck?.test, Healthcheck.Test.none)
        let string = try spec(svc("healthcheck:\n  test: exit 0\n"))
        XCTAssertEqual(string.services[0].healthcheck?.test, .cmdShell("exit 0"))
    }

    func testShortVolumeForms() throws {
        let result = try spec("""
        services:
          app:
            image: x
            volumes: ["./data:/d", "/abs:/a:rw", "named:/n:ro"]
        volumes:
          named:
        """)
        XCTAssertEqual(result.services[0].mounts, [
            .bind(source: "./data", target: "/d", readOnly: false),
            .bind(source: "/abs", target: "/a", readOnly: false),
            .volume(name: "named", target: "/n", readOnly: true),
        ])
    }

    // MARK: 拒否: キー

    func testUnknownKeyIsRefused() throws {
        XCTAssertEqual(try refusals(svc("hostname: h\n")), [.unknownKey(path: ComposePath("services.app.hostname"))])
        XCTAssertEqual(try refusals("services:\n  app:\n    image: x\nconfigs: {}\n"), [.unknownKey(path: ComposePath("configs"))])
    }

    private func assertForbidden(_ extra: String, path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try refusals(svc(extra))
        guard case .forbiddenKey(let p, _)? = result.first, result.count == 1 else {
            return XCTFail("expected exactly one forbiddenKey, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(p, ComposePath(path), file: file, line: line)
    }

    func testPrivilegedIsForbidden() throws { try assertForbidden("privileged: true\n", path: "services.app.privileged") }
    func testContainerNameIsForbidden() throws { try assertForbidden("container_name: x\n", path: "services.app.container_name") }
    func testRestartIsForbidden() throws { try assertForbidden("restart: always\n", path: "services.app.restart") }
    func testExtraHostsIsForbidden() throws { try assertForbidden("extra_hosts: [\"a:1.2.3.4\"]\n", path: "services.app.extra_hosts") }

    func testExternalNetworkIsForbidden() throws {
        let result = try refusals("""
        services:
          app:
            image: x
        networks:
          other:
            external: true
        """)
        guard case .forbiddenKey(let p, _)? = result.first, result.count == 1 else {
            return XCTFail("expected exactly one forbiddenKey, got \(result)")
        }
        XCTAssertEqual(p, ComposePath("networks.other.external"))
    }

    func testVolumeDriverOptsIsForbidden() throws {
        let result = try refusals("""
        services:
          app:
            image: x
        volumes:
          v:
            driver_opts:
              type: none
              o: bind
              device: /Users/x
        """)
        guard case .forbiddenKey(let p, _)? = result.first, result.count == 1 else {
            return XCTFail("expected exactly one forbiddenKey, got \(result)")
        }
        XCTAssertEqual(p, ComposePath("volumes.v.driver_opts"))
    }

    func testBuildSshIsForbidden() throws {
        let result = try refusals("services:\n  app:\n    build:\n      context: ./scripts\n      ssh: [default]\n")
        guard case .forbiddenKey(let p, _)? = result.first, result.count == 1 else {
            return XCTFail("expected exactly one forbiddenKey, got \(result)")
        }
        XCTAssertEqual(p, ComposePath("services.app.build.ssh"))
    }

    func testServiceSecretsIsForbidden() throws { try assertForbidden("secrets: [s]\n", path: "services.app.secrets") }

    func testBuildNetworkHostIsForbidden() throws {
        let result = try refusals("services:\n  app:\n    build:\n      context: ./scripts\n      network: host\n")
        guard case .forbiddenKey(let p, _)? = result.first, result.count == 1 else {
            return XCTFail("expected exactly one forbiddenKey, got \(result)")
        }
        XCTAssertEqual(p, ComposePath("services.app.build.network"))
        XCTAssertNil(try refusals("services:\n  app:\n    build:\n      context: ./scripts\n      network: none\n").first)
    }

    func testInternalFalseIsInvalid() throws {
        let result = try refusals("services:\n  app:\n    image: x\nnetworks:\n  n:\n    internal: false\n")
        guard case .invalidValue(let p, _)? = result.first else { return XCTFail("expected invalidValue") }
        XCTAssertEqual(p, ComposePath("networks.n.internal"))
    }

    // MARK: 拒否: 集約・名前・型

    func testRefusalsAreCollected() throws {
        let result = try refusals("""
        services:
          app:
            image: x
            privileged: true
            hostname: h
            ports: ["8000-8010:8000-8010"]
        """)
        XCTAssertEqual(result.count, 3)
    }

    func testServiceNameGrammarAndReservedNames() throws {
        XCTAssertEqual(try refusals("services:\n  Bad_Name:\n    image: x\n"), [.invalidServiceName(name: "Bad_Name")])
        XCTAssertEqual(try refusals("services:\n  localhost:\n    image: x\n"),
                       [.reservedName(path: ComposePath("services.localhost"), name: "localhost")])
        XCTAssertEqual(try refusals("services:\n  host.docker.internal:\n    image: x\n"),
                       [.reservedName(path: ComposePath("services.host.docker.internal"), name: "host.docker.internal")])
        XCTAssertEqual(try refusals("services:\n  fleetest-db:\n    image: x\n"),
                       [.reservedName(path: ComposePath("services.fleetest-db"), name: "fleetest-db")])
        XCTAssertEqual(try refusals(svc("labels:\n  fleetest.owner: me\n")),
                       [.reservedName(path: ComposePath("services.app.labels.fleetest.owner"), name: "fleetest.owner")])
    }

    func testPortRangesAreRefused() throws {
        for port in ["8000-8010:8000-8010", "8000-8010:80", "127.0.0.1:80:90-95"] {
            let result = try refusals(svc("ports: [\"\(port)\"]\n"))
            guard case .invalidValue(let p, _)? = result.first, result.count == 1 else {
                return XCTFail("expected invalidValue for \(port), got \(result)")
            }
            XCTAssertEqual(p, ComposePath("services.app.ports[0]"))
        }
        let long = try refusals(svc("ports:\n  - target: 80\n    published: \"8000-8010\"\n"))
        guard case .invalidValue? = long.first else { return XCTFail("expected invalidValue for long form") }
    }

    func testUndeclaredNetworkAndVolume() throws {
        XCTAssertEqual(try refusals(svc("networks: [nope]\n")),
                       [.undeclaredNetwork(path: ComposePath("services.app.networks[0]"), name: "nope")])
        XCTAssertEqual(try refusals(svc("volumes: [\"nope:/x\"]\n")),
                       [.undeclaredVolume(path: ComposePath("services.app.volumes[0]"), name: "nope")])
    }

    func testDependsOnUnknownServiceAndCycle() throws {
        XCTAssertEqual(try refusals(svc("depends_on: [ghost]\n")),
                       [.unknownService(path: ComposePath("services.app.depends_on[0]"), name: "ghost")])
        let cycle = try refusals("""
        services:
          a:
            image: x
            depends_on: [b]
          b:
            image: x
            depends_on: [a]
        """)
        XCTAssertEqual(cycle, [.dependencyCycle(services: ["a", "b", "a"])])
    }

    func testWrongTypes() throws {
        XCTAssertEqual(try refusals("services: []\n"), [.wrongType(path: ComposePath("services"), expected: "mapping")])
        XCTAssertEqual(try refusals(svc("ports: 80\n")), [.wrongType(path: ComposePath("services.app.ports"), expected: "list")])
        XCTAssertEqual(try refusals(svc("init: yes please\n")), [.wrongType(path: ComposePath("services.app.init"), expected: "boolean")])
        XCTAssertEqual(try refusals("- a\n"), [.wrongType(path: ComposePath(), expected: "mapping")])
    }

    func testServicesAreRequired() throws {
        XCTAssertEqual(try refusals("networks: {}\n"), [.invalidValue(path: ComposePath("services"), reason: "required")])
    }
}
