import XCTest
@testable import FTServices

final class ComposePolicyTests: XCTestCase {
    // MARK: 土台

    private func fact(_ real: String, symlink: Bool = false, dir: Bool = true) -> PathFact {
        PathFact(exists: true, realpath: real, isSymlink: symlink, isDirectory: dir)
    }

    private func baseSpec() -> ServiceSpec {
        ServiceSpec(
            services: [
                ServiceDef(
                    name: "db", image: "postgres:16",
                    ports: [PortPublish(hostIP: "127.0.0.1", hostPort: 15432, containerPort: 5432, proto: .tcp)],
                    mounts: [.volume(name: "pgdata", target: "/var/lib/postgresql/data", readOnly: false)],
                    healthcheck: Healthcheck(test: .cmdShell("pg_isready"), interval: "5s", timeout: "1m30s", retries: 10, startPeriod: "500ms")),
                ServiceDef(
                    name: "api", build: BuildDef(context: "./server"),
                    envFiles: ["./api.env"],
                    dependsOn: [Dependency(service: "db", condition: .serviceHealthy)]),
                ServiceDef(
                    name: "stub", image: "wiremock/wiremock",
                    ports: [PortPublish(hostIP: "127.0.0.1", hostPort: 19090, containerPort: 9090, proto: .udp)]),
            ],
            networks: [], volumes: [VolumeDef(name: "pgdata")], ignoredTopLevelKeys: [])
    }

    private func baseContext(runtime: ServiceRuntime = .docker) -> ComposePolicy.Context {
        ComposePolicy.Context(
            runtime: runtime, scriptsRoot: "/ws/scripts", dataRoot: "/ws/data",
            buildSources: ["/src/ext"],
            pathFacts: [
                "./server": fact("/ws/scripts/server"),
                "./server/Dockerfile": fact("/ws/scripts/server/Dockerfile", dir: false),
                "./api.env": fact("/ws/scripts/api.env", dir: false),
            ],
            reservedHostPorts: [8123...8130, 5037...5037])
    }

    private func mutated(_ change: (inout ServiceSpec) -> Void) -> ServiceSpec {
        var s = baseSpec()
        change(&s)
        return s
    }

    private func refusals(_ spec: ServiceSpec, _ ctx: ComposePolicy.Context) -> [ComposeRefusal] {
        if case .failure(let r) = ComposePolicy.check(spec, context: ctx) { return r.items }
        return []
    }

    private func bindSpec(_ source: String, readOnly: Bool) -> ServiceSpec {
        mutated { $0.services[2].mounts = [.bind(source: source, target: "/m", readOnly: readOnly)] }
    }

    private func bindContext(_ source: String, _ f: PathFact?) -> ComposePolicy.Context {
        var c = baseContext()
        c.pathFacts[source] = f
        return c
    }

    private let sp = ComposePath("services.stub.volumes[0]")

    // MARK: 正常系

    func testBaselinePassesWithRealpaths() {
        switch ComposePolicy.check(baseSpec(), context: baseContext()) {
        case .success(let checked):
            XCTAssertEqual(checked.spec, baseSpec())
            XCTAssertEqual(checked.realpaths, [
                "./server": "/ws/scripts/server",
                "./server/Dockerfile": "/ws/scripts/server/Dockerfile",
                "./api.env": "/ws/scripts/api.env",
            ])
        case .failure(let r):
            XCTFail("unexpected: \(r.map(\.message))")
        }
    }

    func testBuildContextUnderBuildSourcesPasses() {
        let spec = mutated { $0.services[1].build = BuildDef(context: "/src/ext/app") }
        var ctx = baseContext()
        ctx.pathFacts["/src/ext/app"] = fact("/src/ext/app")
        ctx.pathFacts["/src/ext/app/Dockerfile"] = fact("/src/ext/app/Dockerfile", dir: false)
        XCTAssertEqual(refusals(spec, ctx), [])
    }

    func testExplicitDockerfileKeyIsContextJoined() {
        let spec = mutated { $0.services[1].build = BuildDef(context: "./server", dockerfile: "docker/Prod.df") }
        var ctx = baseContext()
        ctx.pathFacts["./server/docker/Prod.df"] = fact("/ws/scripts/server/docker/Prod.df", dir: false)
        XCTAssertEqual(refusals(spec, ctx), [])
    }

    // MARK: 1 根の symlink

    func testScriptsRootSymlinkRefused() {
        var ctx = baseContext()
        ctx.scriptsRootIsSymlink = true
        XCTAssertEqual(refusals(baseSpec(), ctx),
                       [.invalidValue(path: ComposePath("<workspace>"), reason: "scripts/ or data/ is a symlink")])
    }

    func testDataRootSymlinkRefused() {
        var ctx = baseContext()
        ctx.dataRootIsSymlink = true
        XCTAssertEqual(refusals(baseSpec(), ctx).count, 1)
    }

    // MARK: 2 bind

    func testBindWithoutFactRefused() {
        XCTAssertEqual(refusals(bindSpec("./nofact", readOnly: true), baseContext()),
                       [.bindSourceOutsideAllowedRoots(path: sp, source: "./nofact")])
    }

    func testBindNonexistentRefused() {
        let f = PathFact(exists: false, realpath: "/ws/scripts/x", isSymlink: false, isDirectory: false)
        XCTAssertEqual(refusals(bindSpec("./x", readOnly: true), bindContext("./x", f)),
                       [.bindSourceOutsideAllowedRoots(path: sp, source: "./x")])
    }

    func testBindWithoutRealpathRefused() {
        let f = PathFact(exists: true, realpath: nil, isSymlink: false, isDirectory: true)
        XCTAssertEqual(refusals(bindSpec("./x", readOnly: true), bindContext("./x", f)),
                       [.bindSourceOutsideAllowedRoots(path: sp, source: "./x")])
    }

    func testBindSymlinkRefused() {
        XCTAssertEqual(refusals(bindSpec("./l", readOnly: true), bindContext("./l", fact("/ws/scripts/l", symlink: true))),
                       [.bindSourceIsSymlink(path: sp, source: "./l")])
    }

    func testBindScriptsReadOnlyPasses() {
        XCTAssertEqual(refusals(bindSpec("./s", readOnly: true), bindContext("./s", fact("/ws/scripts/sub"))), [])
    }

    func testBindScriptsRootItselfPasses() {
        XCTAssertEqual(refusals(bindSpec("./s", readOnly: true), bindContext("./s", fact("/ws/scripts"))), [])
    }

    func testBindScriptsWritableRefused() {
        XCTAssertEqual(refusals(bindSpec("./s", readOnly: false), bindContext("./s", fact("/ws/scripts/sub"))),
                       [.scriptsMountMustBeReadOnly(path: sp)])
    }

    func testBindDataRootWritablePasses() {
        XCTAssertEqual(refusals(bindSpec("./d", readOnly: false), bindContext("./d", fact("/ws/data"))), [])
    }

    func testBindUnderDataRootRefused() {
        XCTAssertEqual(refusals(bindSpec("./d/x", readOnly: false), bindContext("./d/x", fact("/ws/data/x"))),
                       [.bindSourceUnderWritableRoot(path: sp, source: "./d/x")])
    }

    func testBindOutsideRootsRefused() {
        XCTAssertEqual(refusals(bindSpec("~/.ssh", readOnly: true), bindContext("~/.ssh", fact("/Users/u/.ssh"))),
                       [.bindSourceOutsideAllowedRoots(path: sp, source: "~/.ssh")])
    }

    func testSiblingPrefixIsNotUnderDataRoot() {
        // /ws/data2 は /ws/data の配下でも同一でもない = 範囲外
        XCTAssertEqual(refusals(bindSpec("./d2", readOnly: false), bindContext("./d2", fact("/ws/data2"))),
                       [.bindSourceOutsideAllowedRoots(path: sp, source: "./d2")])
    }

    func testSiblingPrefixIsNotUnderScriptsRoot() {
        XCTAssertEqual(refusals(bindSpec("./s2", readOnly: true), bindContext("./s2", fact("/ws/scripts-evil"))),
                       [.bindSourceOutsideAllowedRoots(path: sp, source: "./s2")])
    }

    func testPassedBindIsInRealpaths() {
        if case .success(let c) = ComposePolicy.check(bindSpec("./d", readOnly: false), context: bindContext("./d", fact("/ws/data"))) {
            XCTAssertEqual(c.realpaths["./d"], "/ws/data")
        } else {
            XCTFail("expected success")
        }
    }

    // MARK: 3 env_file

    func testEnvFileOutsideScriptsRefused() {
        var ctx = baseContext()
        ctx.pathFacts["./api.env"] = fact("/ws/data/api.env", dir: false)
        XCTAssertEqual(refusals(baseSpec(), ctx),
                       [.envFileOutsideScripts(path: ComposePath("services.api.env_file[0]"))])
    }

    // MARK: 4 build

    func testBuildContextOutsideRefused() {
        var ctx = baseContext()
        ctx.pathFacts["./server"] = fact("/elsewhere/server")
        XCTAssertEqual(refusals(baseSpec(), ctx),
                       [.buildContextOutsideAllowedRoots(path: ComposePath("services.api.build.context"))])
    }

    func testBuildContextUnderDataRefused() {
        var ctx = baseContext()
        ctx.pathFacts["./server"] = fact("/ws/data/server")
        ctx.pathFacts["./server/Dockerfile"] = fact("/ws/data/server/Dockerfile", dir: false)
        XCTAssertEqual(refusals(baseSpec(), ctx),
                       [.buildContextOutsideAllowedRoots(path: ComposePath("services.api.build.context"))])
    }

    func testDockerfileOutsideContextRefused() {
        var ctx = baseContext()
        ctx.pathFacts["./server/Dockerfile"] = fact("/ws/scripts/other/Dockerfile", dir: false)
        XCTAssertEqual(refusals(baseSpec(), ctx),
                       [.buildDockerfileOutsideContext(path: ComposePath("services.api.build.dockerfile"))])
    }

    func testPrivateContextRefusedOnApple() {
        let spec = mutated { $0.services[1].build = BuildDef(context: "/private/tmp/ws/scripts/server") }
        var ctx = baseContext(runtime: .apple)
        ctx.pathFacts["/private/tmp/ws/scripts/server"] = fact("/ws/scripts/server")
        ctx.pathFacts["/private/tmp/ws/scripts/server/Dockerfile"] = fact("/ws/scripts/server/Dockerfile", dir: false)
        XCTAssertEqual(refusals(spec, ctx),
                       [.buildContextUnderPrivate(path: ComposePath("services.api.build.context"))])
    }

    func testPrivateContextPassesOnDocker() {
        let spec = mutated { $0.services[1].build = BuildDef(context: "/private/tmp/ws/scripts/server") }
        var ctx = baseContext(runtime: .docker)
        ctx.pathFacts["/private/tmp/ws/scripts/server"] = fact("/ws/scripts/server")
        ctx.pathFacts["/private/tmp/ws/scripts/server/Dockerfile"] = fact("/ws/scripts/server/Dockerfile", dir: false)
        XCTAssertEqual(refusals(spec, ctx), [])
    }

    // MARK: 5 ports

    private func portRefusals(_ ports: [PortPublish]) -> [ComposeRefusal] {
        refusals(mutated { $0.services[2].ports = ports }, baseContext())
    }

    private let pp = ComposePath("services.stub.ports[0]")

    func testHostIPNilRefused() {
        XCTAssertEqual(portRefusals([PortPublish(hostIP: nil, hostPort: 19090, containerPort: 1, proto: .tcp)]),
                       [.hostIPNotLoopback(path: pp)])
    }

    func testHostIPAnyRefused() {
        XCTAssertEqual(portRefusals([PortPublish(hostIP: "0.0.0.0", hostPort: 19090, containerPort: 1, proto: .tcp)]),
                       [.hostIPNotLoopback(path: pp)])
    }

    func testReservedHostPortRefused() {
        XCTAssertEqual(portRefusals([PortPublish(hostIP: "127.0.0.1", hostPort: 8125, containerPort: 1, proto: .tcp)]),
                       [.hostPortReserved(path: pp, port: 8125)])
    }

    func testReservedRangeBoundaryIsInclusive() {
        XCTAssertEqual(portRefusals([PortPublish(hostIP: "127.0.0.1", hostPort: 8130, containerPort: 1, proto: .tcp)]).count, 1)
        XCTAssertEqual(portRefusals([PortPublish(hostIP: "127.0.0.1", hostPort: 8131, containerPort: 1, proto: .tcp)]), [])
    }

    func testDuplicateHostPortRefused() {
        let dup = PortPublish(hostIP: "127.0.0.1", hostPort: 15432, containerPort: 5432, proto: .tcp)
        XCTAssertEqual(portRefusals([dup]),
                       [.invalidValue(path: pp, reason: "host port is published twice")])
    }

    func testSameHostPortDifferentProtoPasses() {
        let udp = PortPublish(hostIP: "127.0.0.1", hostPort: 15432, containerPort: 5432, proto: .udp)
        XCTAssertEqual(portRefusals([udp]), [])
    }

    func testHostPortOutOfRangeRefused() {
        XCTAssertEqual(portRefusals([PortPublish(hostIP: "127.0.0.1", hostPort: 70000, containerPort: 1, proto: .tcp)]),
                       [.invalidValue(path: pp, reason: "host port is out of range 1-65535")])
    }

    func testContainerPortOutOfRangeRefused() {
        XCTAssertEqual(portRefusals([PortPublish(hostIP: "127.0.0.1", hostPort: 19090, containerPort: 0, proto: .tcp)]),
                       [.invalidValue(path: pp, reason: "container port is out of range 1-65535")])
    }

    // MARK: 6 healthcheck

    private func hcRefusals(_ hc: Healthcheck) -> [ComposeRefusal] {
        refusals(mutated { $0.services[0].healthcheck = hc }, baseContext())
    }

    func testHealthcheckNegativeRetriesRefused() {
        XCTAssertEqual(hcRefusals(Healthcheck(test: .cmdShell("x"), retries: -1)),
                       [.healthcheckUnsupported(path: ComposePath("services.db.healthcheck.retries"), reason: "must not be negative")])
    }

    func testHealthcheckBadIntervalRefused() {
        XCTAssertEqual(hcRefusals(Healthcheck(test: .cmdShell("x"), interval: "5 seconds")).count, 1)
    }

    func testHealthcheckBadTimeoutRefused() {
        XCTAssertEqual(hcRefusals(Healthcheck(test: .cmdShell("x"), timeout: "abc")).count, 1)
    }

    func testHealthcheckBadStartPeriodRefused() {
        XCTAssertEqual(hcRefusals(Healthcheck(test: .cmdShell("x"), startPeriod: "10")).count, 1)
    }

    func testHealthcheckEmptyCmdRefused() {
        XCTAssertEqual(hcRefusals(Healthcheck(test: .cmd([]))).count, 1)
    }

    func testHealthcheckDurationGrammar() {
        for ok in ["1s", "500ms", "1m30s", "2h", "1.5s", "1h2m3s", "10us"] {
            XCTAssertEqual(hcRefusals(Healthcheck(test: .cmdShell("x"), interval: ok)), [], ok)
        }
        for bad in ["", "s", "1", "1d", "1..5s", "1s ", "1s2"] {
            XCTAssertEqual(hcRefusals(Healthcheck(test: .cmdShell("x"), interval: bad)).count, 1, bad)
        }
    }

    // MARK: 7 資源

    private func memRefusals(_ mem: String) -> [ComposeRefusal] {
        refusals(mutated { $0.services[0].memLimit = mem }, baseContext())
    }

    func testMemLimitGrammar() {
        for ok in ["512m", "2g", "1024k", "100000000", "64B", "1G", "7M"] {
            XCTAssertEqual(memRefusals(ok), [], ok)
        }
        for bad in ["", "m", "1.5g", "2gb", "-1m", "abc", "1 g"] {
            XCTAssertEqual(memRefusals(bad), [.resourceLimitInvalid(path: ComposePath("services.db.mem_limit"),
                                                                     reason: "expected a byte size such as 512m or 2g")], bad)
        }
    }

    func testCpusMustBePositiveFinite() {
        for bad in [0.0, -1.0, Double.infinity, Double.nan] {
            let r = refusals(mutated { $0.services[0].cpus = bad }, baseContext())
            XCTAssertEqual(r.count, 1, "\(bad)")
        }
        XCTAssertEqual(refusals(mutated { $0.services[0].cpus = 0.5 }, baseContext()), [])
    }

    // MARK: 8 depends_on

    func testAllDependsOnConditionsPass() {
        for cond in [Dependency.Condition.serviceStarted, .serviceHealthy, .serviceCompletedSuccessfully] {
            let spec = mutated { $0.services[1].dependsOn = [Dependency(service: "db", condition: cond)] }
            XCTAssertEqual(refusals(spec, baseContext()), [], cond.rawValue)
        }
    }

    // MARK: 9 services 空

    func testEmptyServicesRefused() {
        let spec = ServiceSpec(services: [], networks: [], volumes: [], ignoredTopLevelKeys: [])
        XCTAssertEqual(refusals(spec, baseContext()),
                       [.invalidValue(path: ComposePath("services"), reason: "at least one service is required")])
    }

    // MARK: 集約

    func testRefusalsAreCollected() {
        let spec = mutated {
            $0.services[2].ports = [PortPublish(hostIP: nil, hostPort: 19090, containerPort: 1, proto: .tcp)]
            $0.services[0].memLimit = "lots"
        }
        let r = refusals(spec, baseContext())
        XCTAssertEqual(r.count, 2)
        XCTAssertTrue(r.contains(.hostIPNotLoopback(path: pp)))
        XCTAssertTrue(r.contains(.resourceLimitInvalid(path: ComposePath("services.db.mem_limit"),
                                                        reason: "expected a byte size such as 512m or 2g")))
    }
}
