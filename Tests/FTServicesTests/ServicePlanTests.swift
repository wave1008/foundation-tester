import XCTest
@testable import FTServices

final class ServicePlanTests: XCTestCase {
    private func checked() -> ComposePolicy.Checked {
        let db = ServiceDef(
            name: "db", image: "postgres:16", environment: [EnvEntry(key: "POSTGRES_PASSWORD", value: "x")],
            ports: [PortPublish(hostIP: "127.0.0.1", hostPort: 15432, containerPort: 5432, proto: .tcp)],
            mounts: [.volume(name: "pgdata", target: "/var/lib/postgresql/data", readOnly: false)],
            healthcheck: Healthcheck(test: .cmd(["pg_isready"])), labels: ["team": "a"])
        let api = ServiceDef(
            name: "api", build: BuildDef(context: "./api", dockerfile: "Dockerfile"),  // 鍵は ./api/Dockerfile
            envFiles: ["./api.env"],
            mounts: [.bind(source: "./data", target: "/data", readOnly: true)],
            dependsOn: [Dependency(service: "db", condition: .serviceHealthy)], networks: ["back"])
        let stub = ServiceDef(
            name: "stub", image: "stub:1",
            ports: [PortPublish(hostIP: "127.0.0.1", hostPort: 15000, containerPort: 5000, proto: .udp)])
        // 記述順は api, stub, db(依存で db が先頭に来る)
        let spec = ServiceSpec(services: [api, stub, db], networks: [NetworkDef(name: "back")],
                               volumes: [VolumeDef(name: "pgdata")], ignoredTopLevelKeys: [])
        return ComposePolicy.Checked(spec: spec, realpaths: [
            "./api": "/ws/api", "./api/Dockerfile": "/ws/api/Dockerfile", "./api.env": "/ws/api.env",
            "./data": "/ws/data",
        ])
    }

    private func options(_ rt: ServiceRuntime, physical: Bool = false, lan: String? = nil,
                         proxy: Int? = nil, check: CheckPorts? = CheckPorts(tcp: 16001, udp: 16002)) -> PlanOptions {
        PlanOptions(runtime: rt, workspaceRealpath: "/ws", generation: "g1", physicalLanes: physical,
                    lanAddress: lan, proxyPort: proxy, checkPorts: check, relayImageID: "sha256:abc")
    }

    private func plan(_ rt: ServiceRuntime, physical: Bool = false, lan: String? = nil, proxy: Int? = nil,
                      check: CheckPorts? = CheckPorts(tcp: 16001, udp: 16002)) throws -> ServicePlan {
        try ServicePlanner.make(checked(), options: options(rt, physical: physical, lan: lan, proxy: proxy, check: check)).get()
    }

    func testPrefixDeterministicAndShape() throws {
        let p = try plan(.apple)
        XCTAssertEqual(p.prefix, try plan(.apple).prefix)
        XCTAssertTrue(p.prefix.hasPrefix("fleetest-"))
        XCTAssertEqual(p.prefix.count, "fleetest-".count + 12)
        var o = options(.apple); o.workspaceRealpath = "/wt"
        let q = try ServicePlanner.make(checked(), options: o).get()
        XCTAssertNotEqual(p.prefix, q.prefix)
        // SHA-256("/ws") の先頭12桁
        XCTAssertEqual(p.prefix, "fleetest-0c65a812b078")
    }

    func testNamesAndPublicNames() throws {
        let p = try plan(.docker)
        let x = p.prefix
        XCTAssertEqual(p.internalNetwork, x)
        XCTAssertEqual(p.containers.map(\.name), ["\(x)-db", "\(x)-api", "\(x)-stub"])
        XCTAssertEqual(p.relay?.name, "\(x)-relay")
        XCTAssertEqual(p.relay?.egressNetwork, "\(x)-egress")
        XCTAssertEqual(p.udpCheck?.echoName, "\(x)-udpcheck")
        XCTAssertEqual(p.userNetworks, ["back": "\(x)-back"])
        XCTAssertEqual(p.volumes, ["pgdata": "\(x)-pgdata"])
        let expected: Set<String> = ["\(x)-db", "\(x)-api", "\(x)-stub", "\(x)-relay", "\(x)-udpcheck",
                                     x, "\(x)-egress", "\(x)-back", "\(x)-pgdata"]
        XCTAssertEqual(Set(p.publicNames), expected)
        XCTAssertEqual(p.publicNames.count, expected.count)
    }

    func testTopologicalOrderStable() throws {
        let p = try plan(.apple)
        XCTAssertEqual(p.containers.map(\.service), ["db", "api", "stub"])
        XCTAssertEqual(p.hostsFileOrder, p.containers.map(\.name))
    }

    func testApplePublishes() throws {
        let p = try plan(.apple)
        let db = p.containers.first { $0.service == "db" }!
        XCTAssertEqual(db.publishes, [HostBinding(hostIP: "127.0.0.1", hostPort: 15432, containerPort: 5432, proto: .tcp)])
        XCTAssertTrue(db.aliases.isEmpty)
        XCTAssertNil(p.relay)
        XCTAssertEqual(p.udpCheck?.hostIP, "127.0.0.1")
    }

    /// Apple は同じホストポートを 2 つのアドレスへは束縛できない(実測 "host ports … may not overlap")ので、
    /// 実機のレーンがあるときは Docker と同じく 0.0.0.0 に 1 つだけ。エコーの確認は loopback のまま
    func testApplePhysicalPublishesOnAllInterfacesOnce() throws {
        let p = try plan(.apple, physical: true, lan: "192.168.0.5")
        let db = p.containers.first { $0.service == "db" }!
        XCTAssertEqual(db.publishes, [HostBinding(hostIP: "0.0.0.0", hostPort: 15432, containerPort: 5432, proto: .tcp)])
        XCTAssertEqual(p.udpCheck?.hostIP, "127.0.0.1")
    }

    func testPhysicalWithoutLANFails() {
        XCTAssertEqual(ServicePlanner.make(checked(), options: options(.apple, physical: true)),
                       .failure(.physicalLanesNeedLANAddress))
        XCTAssertEqual(ServicePlanner.make(checked(), options: options(.docker, physical: true)),
                       .failure(.physicalLanesNeedLANAddress))
    }

    func testDockerRelayForwards() throws {
        let p = try plan(.docker)
        XCTAssertTrue(p.containers.allSatisfy { $0.publishes.isEmpty })
        XCTAssertTrue(p.hostsFileOrder.isEmpty)
        XCTAssertEqual(p.containers.map(\.aliases), [["db"], ["api"], ["stub"]])
        let f = p.relay!.forwards
        XCTAssertTrue(f.contains(RelayForward(hostIP: "127.0.0.1", hostPort: 15432, targetService: "db", targetPort: 5432, proto: .tcp)))
        XCTAssertTrue(f.contains(RelayForward(hostIP: "127.0.0.1", hostPort: 15000, targetService: "stub", targetPort: 5000, proto: .udp)))
    }

    func testDockerPhysicalUses0000ButCheckPortsStayLoopback() throws {
        let p = try plan(.docker, physical: true, lan: "192.168.0.5")
        let f = p.relay!.forwards
        let decl = f.filter { $0.targetService != "\(p.prefix)-udpcheck" }
        XCTAssertEqual(decl.count, 2)
        XCTAssertTrue(decl.allSatisfy { $0.hostIP == "0.0.0.0" })
        let chk = f.filter { $0.targetService == "\(p.prefix)-udpcheck" }
        XCTAssertEqual(chk.count, 2)
        XCTAssertTrue(chk.allSatisfy { $0.hostIP == "127.0.0.1" })
        XCTAssertEqual(Set(chk.map(\.hostPort)), [16001, 16002])
        XCTAssertEqual(Set(chk.map(\.proto)), [.tcp, .udp])
    }

    func testUDPCheckPresenceAndFailure() throws {
        XCTAssertNotNil(try plan(.apple).udpCheck)
        XCTAssertEqual(ServicePlanner.make(checked(), options: options(.apple, check: nil)),
                       .failure(.udpPublishedWithoutCheckPorts))
        var spec = checked().spec
        spec.services[1].ports = [PortPublish(hostIP: "127.0.0.1", hostPort: 15000, containerPort: 5000, proto: .tcp)]
        let c = ComposePolicy.Checked(spec: spec, realpaths: checked().realpaths)
        let p = try ServicePlanner.make(c, options: options(.apple, check: nil)).get()
        XCTAssertNil(p.udpCheck)
    }

    func testProxyEnvironment() throws {
        let none = try plan(.apple)
        XCTAssertTrue(none.containers[0].proxyEnvironment.isEmpty)
        XCTAssertEqual(none.containers[0].noProxy, ["api", "stub", "db", "localhost", "127.0.0.1", "::1"])

        let a = try plan(.apple, proxy: 8899).containers[0]
        let keys = a.proxyEnvironment.map(\.key)
        XCTAssertEqual(keys, ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "NO_PROXY", "no_proxy"])
        XCTAssertEqual(a.proxyEnvironment[0].value, "http://<gateway>:8899")
        XCTAssertEqual(a.proxyEnvironment[4].value, "api,stub,db,localhost,127.0.0.1,::1")

        let d = try plan(.docker, proxy: 8899)
        XCTAssertEqual(d.containers[0].proxyEnvironment[0].value, "http://\(d.prefix)-relay:8899")
        XCTAssertEqual(d.relay?.proxyListenPort, 8899)
        XCTAssertNil(try plan(.docker).relay?.proxyListenPort)
    }

    func testLabelsAndResolution() throws {
        let p = try plan(.apple)
        let db = p.containers.first { $0.service == "db" }!
        XCTAssertEqual(db.labels, ["team": "a", "fleetest-generation": "g1",
                                   "fleetest-prefix": p.prefix, "fleetest-service": "db"])
        XCTAssertEqual(db.mounts, [ResolvedMount(source: "\(p.prefix)-pgdata", target: "/var/lib/postgresql/data",
                                                 readOnly: false, isVolume: true)])
        XCTAssertEqual(db.networks, [p.prefix])
        let api = p.containers.first { $0.service == "api" }!
        XCTAssertEqual(api.networks, [p.prefix, "\(p.prefix)-back"])
        XCTAssertEqual(api.mounts, [ResolvedMount(source: "/ws/data", target: "/data", readOnly: true, isVolume: false)])
        XCTAssertEqual(api.envFiles, ["/ws/api.env"])
        XCTAssertEqual(api.build?.context, "/ws/api")
        XCTAssertNil(api.image)
    }

    func testUnresolvedRealpath() {
        var rp = checked().realpaths
        rp.removeValue(forKey: "./data")
        let c = ComposePolicy.Checked(spec: checked().spec, realpaths: rp)
        XCTAssertEqual(ServicePlanner.make(c, options: options(.apple)), .failure(.unresolvedRealpath("./data")))
    }
}
