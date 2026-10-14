import Darwin
import FTCore
import FTServices
import Foundation
import XCTest
@testable import fleetest

/// compose.yaml の検査へ渡す入力(ファイルの事実・予約ポート・辞書・指紋・env-file・資格情報)の集め方を固定する。
/// 期待値は production の定数を参照せずリテラルで書く。
final class ServicesFactsTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        // /var/folders/… (実体は /private/var/folders/…)に作る = realpath が /private を足すことを見る
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("services-facts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func write(_ text: String, _ relative: String) throws {
        let url = scratch.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func expectedReal(_ path: String) -> String {
        path.hasPrefix("/var/") ? "/private" + path : path
    }

    // MARK: pathFacts

    func testPathFactsFillRealpathSymlinkAndExistence() throws {
        try write("select 1;", "scripts/init.sql")
        try write("A=1\n", "scripts/app.env")
        try write("FROM scratch\n", "scripts/ctx/Dockerfile")
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("data"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: scratch.appendingPathComponent("link"), withDestinationURL: scratch.appendingPathComponent("scripts"))

        let service = ServiceDef(
            name: "db", build: BuildDef(context: "./scripts/ctx"), envFiles: ["./scripts/app.env"],
            mounts: [.bind(source: "./scripts/init.sql", target: "/init.sql", readOnly: true),
                     .bind(source: "./link", target: "/l", readOnly: true),
                     .bind(source: "./missing", target: "/m", readOnly: true),
                     .volume(name: "pgdata", target: "/data", readOnly: false)])
        let spec = ServiceSpec(services: [service], networks: [], volumes: [], ignoredTopLevelKeys: [])
        let workspace = ServicesWorkspace(root: scratch)
        let facts = ServicesFacts.pathFacts(for: spec, workspace: workspace)

        let sql = try XCTUnwrap(facts["./scripts/init.sql"])
        XCTAssertTrue(sql.exists)
        XCTAssertFalse(sql.isSymlink)
        XCTAssertFalse(sql.isDirectory)
        XCTAssertEqual(sql.realpath, expectedReal(scratch.path + "/scripts/init.sql"))

        let link = try XCTUnwrap(facts["./link"])
        XCTAssertTrue(link.isSymlink)
        XCTAssertTrue(link.isDirectory)
        XCTAssertEqual(link.realpath, expectedReal(scratch.path + "/scripts"))

        let missing = try XCTUnwrap(facts["./missing"])
        XCTAssertFalse(missing.exists)
        XCTAssertNil(missing.realpath)

        XCTAssertEqual(facts["./scripts/app.env"]?.exists, true)
        XCTAssertEqual(facts["./scripts/ctx"]?.isDirectory, true)
        // dockerfile は ComposePolicy.dockerfileKey の鍵(context + "/Dockerfile")で引ける
        XCTAssertEqual(facts["./scripts/ctx/Dockerfile"]?.exists, true)
        XCTAssertNil(facts["pgdata"], "named volumes are not paths")
    }

    func testPolicyContextRealpathsAndSymlinkFlags() throws {
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("real-data"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: scratch.appendingPathComponent("data"), withDestinationURL: scratch.appendingPathComponent("real-data"))
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("src"), withIntermediateDirectories: true)
        let settings = ServicesSettings(runtime: nil, buildSources: [scratch.path + "/src"], publishForPhysicalDevices: nil)
        let context = ServicesFacts.policyContext(
            runtime: .docker, workspace: ServicesWorkspace(root: scratch), settings: settings,
            reservedPorts: [], facts: [:])
        XCTAssertEqual(context.scriptsRoot, expectedReal(scratch.path + "/scripts"))
        XCTAssertFalse(context.scriptsRootIsSymlink)
        XCTAssertTrue(context.dataRootIsSymlink)
        XCTAssertEqual(context.dataRoot, expectedReal(scratch.path + "/real-data"))
        XCTAssertEqual(context.buildSources, [expectedReal(scratch.path + "/src")])
    }

    // MARK: 予約ポート

    func testReservedHostPortsCoverBridgeEmulatorAndAdbServer() {
        XCTAssertEqual(ServicesFacts.reservedHostPorts(environment: [:]),
                       [8123...8154, 5554...5585, 5037...5037])
        XCTAssertEqual(ServicesFacts.reservedHostPorts(environment: ["ANDROID_ADB_SERVER_PORT": "5038"]).last, 5038...5038)
    }

    // MARK: 辞書

    func testDotEnvMayNotReferenceSecrets() throws {
        let home = scratch.appendingPathComponent("home").path
        try write("TOKEN=s3cret\n", "home/.config/fleetest/secrets/demo.env")
        try write("TAG=${TOKEN}\n", "scripts/.env")
        let workspace = ServicesWorkspace(root: scratch)
        XCTAssertThrowsError(try ServicesFacts.dictionaries(project: "demo", workspace: workspace, home: home)) { error in
            let text = (error as? ServicesError)?.detail ?? ""
            XCTAssertTrue(text.contains(ComposeRefusal.secretReferencedFromDotEnv(name: "TOKEN").message), text)
        }
    }

    func testDictionariesReadSecretsAndPlainSeparately() throws {
        let home = scratch.appendingPathComponent("home").path
        try write("TOKEN=s3cret\n", "home/.config/fleetest/secrets/demo.env")
        try write("TAG=v1\nIMG=app:${TAG}\n", "scripts/.env")
        let dictionaries = try ServicesFacts.dictionaries(
            project: "demo", workspace: ServicesWorkspace(root: scratch), home: home)
        XCTAssertEqual(dictionaries.secrets, ["TOKEN": "s3cret"])
        XCTAssertEqual(dictionaries.plain, ["TAG": "v1", "IMG": "app:v1"])
    }

    // MARK: 指紋

    func testFingerprintInputsApplyDockerignoreAndKeepDockerfile() throws {
        try write("FROM scratch\nCOPY . .\n", "ctx/Dockerfile")
        try write("keep", "ctx/src/app.js")
        try write("big", "ctx/dist/out.js")
        try write("noise", "ctx/notes.log")
        try write("dist\n*.log\n", "ctx/.dockerignore")
        let build = BuildDef(context: scratch.path + "/ctx", dockerfile: scratch.path + "/ctx/Dockerfile",
                             args: ["A": "1"], target: "prod")
        let inputs = try ServicesFacts.fingerprintInputs(build: build, platform: "linux/arm64")
        let paths = Set(inputs.files.map(\.relativePath))
        XCTAssertTrue(paths.contains("src/app.js"))
        XCTAssertTrue(paths.contains("Dockerfile"))
        XCTAssertFalse(paths.contains("dist"))
        XCTAssertFalse(paths.contains("dist/out.js"))
        XCTAssertFalse(paths.contains("notes.log"))
        XCTAssertEqual(inputs.dockerfileContents, "FROM scratch\nCOPY . .\n")
        XCTAssertEqual(inputs.args, ["A": "1"])
        XCTAssertEqual(inputs.target, "prod")
        XCTAssertEqual(inputs.platform, "linux/arm64")
        // ディレクトリ自身は大きさと mtime を持たない
        XCTAssertEqual(inputs.files.first { $0.relativePath == "src" }?.size, 0)
        XCTAssertEqual(inputs.files.first { $0.relativePath == "src" }?.mtimeNanoseconds, 0)
    }

    func testFingerprintNegatedRuleStillFindsReincludedFile() throws {
        try write("FROM scratch\n", "ctx/Dockerfile")
        try write("x", "ctx/dist/keep.txt")
        try write("y", "ctx/dist/drop.txt")
        try write("dist/*\n!dist/keep.txt\n", "ctx/.dockerignore")
        let build = BuildDef(context: scratch.path + "/ctx", dockerfile: scratch.path + "/ctx/Dockerfile")
        let paths = Set(try ServicesFacts.fingerprintInputs(build: build, platform: nil).files.map(\.relativePath))
        XCTAssertTrue(paths.contains("dist/keep.txt"))
        XCTAssertFalse(paths.contains("dist/drop.txt"))
    }

    // MARK: 資格情報・env-file

    func testDockerConfigCopiesOnlyCredentialKeys() throws {
        let home = scratch.appendingPathComponent("home").path
        try write("""
        {"auths":{"ghcr.io":{"auth":"abc"}},"credsStore":"desktop","credHelpers":{"x":"y"},
         "proxies":{"default":{"httpProxy":"http://user:pw@proxy:3128"}},"currentContext":"colima"}
        """, "home/.docker/config.json")
        let privateDir = scratch.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: privateDir, withIntermediateDirectories: true)
        let dir = try ServicesFacts.dockerConfigDirectory(privateDir: privateDir, home: home, environment: [:])
        let data = try Data(contentsOf: dir.appendingPathComponent("config.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["auths", "credsStore", "credHelpers"])
        XCTAssertNil(object["proxies"])
        var st = stat()
        XCTAssertEqual(stat(dir.appendingPathComponent("config.json").path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    func testDockerConfigIsEmptyObjectWithoutUserConfig() throws {
        let privateDir = scratch.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: privateDir, withIntermediateDirectories: true)
        let dir = try ServicesFacts.dockerConfigDirectory(privateDir: privateDir, home: scratch.path + "/nohome", environment: [:])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("config.json"), encoding: .utf8), "{}")
    }

    func testWriteEnvFileIsOwnerOnlyKeyValueLines() throws {
        let privateDir = scratch.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: privateDir, withIntermediateDirectories: true)
        let url = try ServicesFacts.writeEnvFile(
            entries: [EnvEntry(key: "A", value: "1"), EnvEntry(key: "EMPTY", value: nil), EnvEntry(key: "B", value: "x y")],
            into: privateDir, name: "db")
        XCTAssertEqual(url.lastPathComponent, "db.env")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "A=1\nEMPTY=\nB=x y\n")
        var st = stat()
        XCTAssertEqual(stat(url.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    /// 確認用の空きポートは TCP と UDP で別々に取り、予約の範囲(ブリッジ・Emulator・adb)を避ける
    func testFreeCheckPortsAreDistinctAndOutsideTheReservedRanges() throws {
        let reserved: [ClosedRange<Int>] = [8123...8154, 5554...5585, 5037...5037]
        let ports = try ServicesFacts.freeCheckPorts(reserved: reserved)
        XCTAssertGreaterThan(ports.tcp, 1024)
        XCTAssertGreaterThan(ports.udp, 1024)
        XCTAssertFalse(reserved.contains { $0.contains(ports.tcp) || $0.contains(ports.udp) })
        // 予約の範囲が全部なら見つからない(黙って予約のポートを使わない)
        XCTAssertThrowsError(try ServicesFacts.freeCheckPorts(reserved: [1...65535]))
    }

    /// `#` 始まりはコメント・空白を含む名前は読み違え = ランタイムが黙って落とす形は書く前に断る
    func testWriteEnvFileRefusesNamesTheRuntimeWouldDropOrMisread() throws {
        for key in ["#SECRET", "A B", "", "A\tB"] {
            XCTAssertThrowsError(try ServicesFacts.writeEnvFile(entries: [EnvEntry(key: key, value: "1")], into: scratch, name: "svc"),
                                 key.debugDescription)
        }
        XCTAssertNoThrow(try ServicesFacts.writeEnvFile(entries: [EnvEntry(key: "A_1", value: "x#y z")], into: scratch, name: "ok"))
    }

    func testWriteEnvFileRefusesLineBreaksInValues() throws {
        XCTAssertThrowsError(try ServicesFacts.writeEnvFile(
            entries: [EnvEntry(key: "K", value: "a\nb")], into: scratch, name: "x"))
        XCTAssertThrowsError(try ServicesFacts.writeEnvFile(
            entries: [EnvEntry(key: "K=V", value: "a")], into: scratch, name: "y"))
    }

    // MARK: 計画の入力

    func testPlanOptionsRequireLANAddressForPhysicalLanesAndAllocateCheckPortsOnlyForUDP() throws {
        let empty = ServiceSpec(services: [ServiceDef(name: "a")], networks: [], volumes: [], ignoredTopLevelKeys: [])
        XCTAssertThrowsError(try ServicesFacts.planOptions(
            runtime: .docker, workspaceRealpath: "/w", generation: "g", physicalLanes: true,
            settings: nil, relayImageID: "sha256:x", spec: empty, proxyPort: nil))
        let withLAN = ServicesSettings(publishForPhysicalDevices: "192.168.1.20")
        let lan = try ServicesFacts.planOptions(
            runtime: .docker, workspaceRealpath: "/w", generation: "g", physicalLanes: true,
            settings: withLAN, relayImageID: "sha256:x", spec: empty, proxyPort: 8899)
        XCTAssertEqual(lan.lanAddress, "192.168.1.20")
        XCTAssertEqual(lan.proxyPort, 8899)
        XCTAssertNil(lan.checkPorts, "/udp の公開が無ければ確認用のポートは取らない")
        let udp = ServiceSpec(
            services: [ServiceDef(name: "a", ports: [PortPublish(hostIP: "127.0.0.1", hostPort: 9000, containerPort: 9000, proto: .udp)])],
            networks: [], volumes: [], ignoredTopLevelKeys: [])
        let checked = try ServicesFacts.planOptions(
            runtime: .docker, workspaceRealpath: "/w", generation: "g", physicalLanes: false,
            settings: nil, relayImageID: "sha256:x", spec: udp, proxyPort: nil)
        let ports = try XCTUnwrap(checked.checkPorts)
        XCTAssertGreaterThan(ports.tcp, 1024)
        XCTAssertGreaterThan(ports.udp, 1024)
    }

    // MARK: ランタイムの選択の部品

    func testVersionParsingAndGate() {
        XCTAssertEqual(ServicesRuntimeLocator.parseVersion("container CLI version 1.1.0 (build: release)"), [1, 1, 0])
        XCTAssertNil(ServicesRuntimeLocator.parseVersion("no version here"))
        XCTAssertTrue(ServicesRuntimeLocator.isVersion([1, 1, 0], atLeast: [1, 1, 0]))
        XCTAssertTrue(ServicesRuntimeLocator.isVersion([1, 2, 0], atLeast: [1, 1, 9]))
        XCTAssertFalse(ServicesRuntimeLocator.isVersion([1, 0, 9], atLeast: [1, 1, 0]))
        XCTAssertTrue(ServicesRuntimeLocator.isVersion([2, 0, 0], atLeast: [1, 9, 9]))
    }

    func testOnlyUnixSocketsAreAccepted() throws {
        XCTAssertThrowsError(try ServicesRuntimeLocator.unixSocketPath("tcp://10.0.0.5:2375"))
        XCTAssertThrowsError(try ServicesRuntimeLocator.unixSocketPath("ssh://me@host"))
        XCTAssertEqual(try ServicesRuntimeLocator.unixSocketPath("unix:///no/such/docker.sock"), "/no/such/docker.sock")
    }
}
