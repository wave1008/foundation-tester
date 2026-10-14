import FTServices
import XCTest
@testable import fleetest

/// docker を起こす環境: 接続先の固定と、docker の置き場を PATH の先頭に足すこと(認証ヘルパーは PATH から起こされる)。
final class RuntimeCLIEnvironmentTests: XCTestCase {
    func testDockerGetsItsOwnDirectoryAtTheHeadOfPATH() {
        let cli = RuntimeCLI(runtime: LocatedRuntime(kind: .docker, executable: "/Users/u/.rd/bin/docker", endpoint: "/Users/u/.rd/docker.sock"),
                             environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        XCTAssertEqual(cli.controlEnvironment, [
            "DOCKER_HOST=unix:///Users/u/.rd/docker.sock",
            "PATH=/Users/u/.rd/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ])
        XCTAssertEqual(cli.argv(["pull", "busybox:latest"]).suffix(3), ["/Users/u/.rd/bin/docker", "pull", "busybox:latest"])
    }

    func testPATHIsNotDuplicatedWhenTheDirectoryIsAlreadyThere() {
        XCTAssertEqual(RuntimeCLI.pathWithExecutableDirectory("/usr/local/bin/docker", environment: ["PATH": "/usr/local/bin:/usr/bin"]),
                       "/usr/local/bin:/usr/bin")
        XCTAssertEqual(RuntimeCLI.pathWithExecutableDirectory("/usr/local/bin/docker", environment: ["PATH": "/usr/bin:/usr/local/bin:/bin"]),
                       "/usr/local/bin:/usr/bin:/bin")
        XCTAssertEqual(RuntimeCLI.pathWithExecutableDirectory("/opt/homebrew/bin/docker", environment: [:]), "/opt/homebrew/bin")
    }

    func testAppleContainerGetsNoControlEnvironment() {
        let cli = RuntimeCLI(runtime: LocatedRuntime(kind: .apple, executable: "/opt/homebrew/bin/container", endpoint: "apple"),
                             environment: ["PATH": "/usr/bin"])
        XCTAssertEqual(cli.controlEnvironment, [])
    }
}
