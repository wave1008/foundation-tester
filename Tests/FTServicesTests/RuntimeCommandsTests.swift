import XCTest
@testable import FTServices

final class RuntimeCommandsTests: XCTestCase {
    private func launch() -> ContainerLaunch {
        ContainerLaunch(
            name: "p-api", service: "api", image: nil, build: nil, command: ["serve", "--x"],
            entrypoint: ["/bin/app", "--e"], environment: [], envFiles: [],
            mounts: [ResolvedMount(source: "/real", target: "/m", readOnly: true, isVolume: false),
                     ResolvedMount(source: "p-data", target: "/d", readOnly: false, isVolume: true)],
            publishes: [HostBinding(hostIP: "127.0.0.1", hostPort: 18080, containerPort: 80, proto: .tcp),
                        HostBinding(hostIP: "127.0.0.1", hostPort: 19090, containerPort: 90, proto: .udp)],
            networks: ["p", "p-back"], aliases: ["api"], labels: ["b": "2", "a": "1"], healthcheck: nil,
            dependsOn: [], workingDir: "/w", user: "1000", platform: "linux/arm64", initProcess: true,
            stopGracePeriod: "5s", memLimit: "512m", cpus: 0.5, tmpfs: ["/tmp"], noProxy: [], proxyEnvironment: [])
    }

    private func relay() -> RelayPlan {
        RelayPlan(
            name: "p-relay", imageID: "sha256:abc", internalNetwork: "p", egressNetwork: "p-egress",
            forwards: [RelayForward(hostIP: "127.0.0.1", hostPort: 18080, targetService: "api", targetPort: 80, proto: .tcp),
                       RelayForward(hostIP: "127.0.0.1", hostPort: 19090, targetService: "p-udpcheck", targetPort: 90, proto: .udp)],
            proxyListenPort: 3128)
    }

    private func echo() -> UDPCheckPlan {
        UDPCheckPlan(echoName: "p-udpcheck", imageID: "sha256:abc", tcpHostPort: 7001, udpHostPort: 7002, hostIP: "127.0.0.1")
    }

    /// Docker の常駐サービスは create(つないでから start)。
    func testDockerContainerCreate() {
        XCTAssertEqual(
            DockerCommands.containerCreate(launch: launch(), image: "img:1", envFile: "/env"),
            ["create", "--name", "p-api", "--network", "p", "--network-alias", "api",
             "-p", "127.0.0.1:18080:80", "-p", "127.0.0.1:19090:90/udp",
             "-v", "/real:/m:ro", "-v", "p-data:/d", "--env-file", "/env",
             "--label", "a=1", "--label", "b=2", "--memory", "512m", "--cpus", "0.5", "--init",
             "--user", "1000", "-w", "/w", "--platform", "linux/arm64", "--tmpfs", "/tmp",
             "--entrypoint", "/bin/app", "img:1", "--e", "serve", "--x"])
    }

    func testAppleContainerRun() {
        var l = launch()
        l.aliases = []
        l.publishes = [HostBinding(hostIP: "127.0.0.1", hostPort: 18080, containerPort: 80, proto: .tcp)]
        XCTAssertEqual(
            AppleContainerCommands.containerRun(launch: l, image: "img:1", envFile: "/env", hostsFile: "/h/hosts", detached: true),
            ["run", "-d", "--name", "p-api", "--network", "p", "-p", "127.0.0.1:18080:80",
             "-v", "/real:/m:ro", "-v", "p-data:/d", "-v", "/h/hosts:/etc/hosts", "--env-file", "/env",
             "--label", "a=1", "--label", "b=2", "-m", "512m", "-c", "1", "--init",
             "--user", "1000", "-w", "/w", "--platform", "linux/arm64", "--tmpfs", "/tmp",
             "--entrypoint", "/bin/app", "img:1", "--e", "serve", "--x"])
    }

    /// 初期化サービスは前面で実行する(`-d` 無し)。それ以外の引数は同じ
    func testInitServiceRunsInTheForeground() {
        let docker = DockerCommands.containerRun(launch: launch(), image: "img:1", envFile: "/env", detached: false)
        XCTAssertEqual(Array(docker.prefix(3)), ["run", "--name", "p-api"])
        XCTAssertFalse(docker.contains("-d"))
        XCTAssertEqual(Array(docker.dropFirst(1)),
                       Array(DockerCommands.containerCreate(launch: launch(), image: "img:1", envFile: "/env").dropFirst(1)))
        let apple = AppleContainerCommands.containerRun(launch: launch(), image: "img:1", envFile: "/env", hostsFile: "/h/hosts", detached: false)
        XCTAssertEqual(Array(apple.prefix(3)), ["run", "--name", "p-api"])
        XCTAssertFalse(apple.contains("-d"))
    }

    func testNetworkVolumeAndLifecycleCommands() {
        XCTAssertEqual(DockerCommands.networkCreate(name: "n"), ["network", "create", "--internal", "n"])
        XCTAssertEqual(DockerCommands.networkCreateEgress(name: "n"), ["network", "create", "n"])
        XCTAssertEqual(DockerCommands.networkRemove(name: "n"), ["network", "rm", "n"])
        XCTAssertEqual(DockerCommands.networkConnect(name: "n", container: "c", alias: "a"),
                       ["network", "connect", "--alias", "a", "n", "c"])
        XCTAssertEqual(DockerCommands.networkConnect(name: "n", container: "c", alias: nil), ["network", "connect", "n", "c"])
        XCTAssertEqual(DockerCommands.volumeRemove(name: "v"), ["volume", "rm", "v"])
        XCTAssertEqual(AppleContainerCommands.volumeCreate(name: "v"), ["volume", "create", "v"])
        XCTAssertEqual(AppleContainerCommands.volumeRemove(name: "v"), ["volume", "delete", "v"])
        XCTAssertEqual(AppleContainerCommands.networkCreate(name: "n"), ["network", "create", "--internal", "n"])
        XCTAssertEqual(DockerCommands.containerStop(name: "c", timeoutSeconds: 7), ["stop", "-t", "7", "c"])
        XCTAssertEqual(AppleContainerCommands.containerLogs(name: "c", tail: 50), ["logs", "-n", "50", "c"])
        XCTAssertEqual(DockerCommands.containerLogs(name: "c", tail: 50), ["logs", "--tail", "50", "c"])
        XCTAssertEqual(DockerCommands.containerExec(name: "c", argv: ["ls", "-l"]), ["exec", "c", "ls", "-l"])
    }

    func testImageCommands() {
        XCTAssertEqual(DockerCommands.imageInspectID(ref: "r"), ["image", "inspect", "--format", "{{.Id}}", "r"])
        XCTAssertEqual(AppleContainerCommands.imageInspectID(ref: "r"), ["image", "inspect", "r"])
        XCTAssertEqual(DockerCommands.imageLoad(file: "/f.tar"), ["load", "-i", "/f.tar"])
        XCTAssertEqual(AppleContainerCommands.imageLoad(file: "/f.tar"), ["image", "load", "-i", "/f.tar"])
        let expected = ["build", "-f", "/c/Dockerfile", "-t", "t:1", "--build-arg", "A=1", "--build-arg", "B=2",
                        "--target", "prod", "--platform", "linux/arm64", "--label", "k=v", "/c"]
        XCTAssertEqual(DockerCommands.imageBuild(context: "/c", dockerfile: "/c/Dockerfile", tag: "t:1",
                                                 args: ["B": "2", "A": "1"], target: "prod",
                                                 platform: "linux/arm64", labels: ["k": "v"]), expected)
        XCTAssertEqual(AppleContainerCommands.imageBuild(context: "/c", dockerfile: "/c/Dockerfile", tag: "t:1",
                                                         args: ["B": "2", "A": "1"], target: "prod",
                                                         platform: "linux/arm64", labels: ["k": "v"]), expected)
    }

    func testListByPrefix() {
        XCTAssertEqual(DockerCommands.listByPrefix(prefix: "fleetest-abc"),
                       ["ps", "-a", "--filter", "label=fleetest-prefix=fleetest-abc", "--format", "{{.ID}}\t{{.Names}}"])
        XCTAssertEqual(AppleContainerCommands.listByPrefix(prefix: "fleetest-abc"), ["ls", "-a", "--format", "json"])
    }

    func testRelayCreateAndScript() {
        let script = DockerCommands.relayScript(plan: relay())
        XCTAssertEqual(
            DockerCommands.relayCreate(plan: relay()),
            ["create", "--name", "p-relay", "--network", "p-egress",
             "-p", "127.0.0.1:18080:18080/tcp", "-p", "127.0.0.1:19090:19090/udp",
             "--entrypoint", "sh", "sha256:abc", "-c", script])
        XCTAssertEqual(script, """
            socat TCP-LISTEN:18080,fork,reuseaddr,nodelay TCP:api:80,nodelay &
            socat UDP-RECVFROM:19090,fork UDP-SENDTO:p-udpcheck:90 &
            socat TCP-LISTEN:3128,fork,reuseaddr,nodelay TCP:host.docker.internal:3128,nodelay &
            wait
            """)
    }

    /// nodelay を落とすと Nagle で p99 が張り付く(両側に要る)。
    func testRelayTCPForwardsSetNodelayOnBothSides() {
        for line in DockerCommands.relayScript(plan: relay()).split(separator: "\n") where line.contains("TCP-LISTEN") {
            XCTAssertTrue(line.contains("reuseaddr,nodelay TCP:"), String(line))
            XCTAssertTrue(line.contains(",nodelay &"), String(line))
        }
    }

    func testEchoRun() {
        let script = "socat TCP-LISTEN:7001,fork,reuseaddr EXEC:cat & socat UDP-RECVFROM:7002,fork EXEC:cat & wait"
        XCTAssertEqual(DockerCommands.echoRun(plan: echo(), network: "p"),
                       ["run", "-d", "--name", "p-udpcheck", "--network", "p",
                        "--entrypoint", "sh", "sha256:abc", "-c", script])
        XCTAssertEqual(AppleContainerCommands.echoRun(plan: echo(), network: "p"),
                       ["run", "-d", "--name", "p-udpcheck", "--network", "p",
                        "-p", "127.0.0.1:7001:7001", "-p", "127.0.0.1:7002:7002/udp",
                        "--entrypoint", "sh", "sha256:abc", "-c", script])
    }
}
