// LocalConfig.resolveIssuerId(自己申告の帰属)と issuerId の round-trip。
// テスト用の config.json は一時ディレクトリに作り、実機の ~/.config/fleetest/config.json には触れない。

import Foundation
import XCTest
@testable import FTCore

// クラス名は LocalConfigIssuerIdTests(素の LocalConfigTests は ProjectStoreTests.swift に既存)
final class LocalConfigIssuerIdTests: XCTestCase {

    private func tempConfigURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConfigTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    private var fallback: String { "\(NSUserName())@\(ProcessInfo.processInfo.hostName)" }

    // MARK: - resolveIssuerId

    func testResolveIssuerIdReturnsConfiguredValue() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var config = LocalConfig()
        config.issuerId = "alice@ci-runner"
        try config.save(to: url)

        XCTAssertEqual(LocalConfig.resolveIssuerId(environment: [:], configURL: url), "alice@ci-runner")
    }

    func testResolveIssuerIdFallsBackWhenUnset() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try LocalConfig().save(to: url)

        XCTAssertEqual(LocalConfig.resolveIssuerId(environment: [:], configURL: url), fallback)
    }

    /// FT_ISSUER はリモートディスパッチが子へ発行者を運ぶ口(RemoteShell.remoteRunCommand が
    /// export する)。設定より強くないと、ランナー機の config が全員の run を上書きする
    func testResolveIssuerIdPrefersEnvironmentOverConfig() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var config = LocalConfig()
        config.issuerId = "runner-account@runner"
        try config.save(to: url)

        XCTAssertEqual(
            LocalConfig.resolveIssuerId(environment: ["FT_ISSUER": "tanaka@dev-mbp"], configURL: url),
            "tanaka@dev-mbp")
        XCTAssertEqual(
            LocalConfig.resolveIssuerId(environment: ["FT_ISSUER": ""], configURL: url),
            "runner-account@runner")
    }

    func testResolveIssuerIdFallsBackWhenConfiguredValueIsEmpty() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var config = LocalConfig()
        config.issuerId = ""
        try config.save(to: url)

        XCTAssertEqual(LocalConfig.resolveIssuerId(environment: [:], configURL: url), fallback)
    }

    // MARK: - resolveIssuer (explicit フラグ付き。§18.2: resolveLayoutIssuer が USER@hostname
    // フォールバックのときだけ1回警告するための出所判定)

    func testResolveIssuerExplicitTrueForEnvironment() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try LocalConfig().save(to: url)

        let (id, explicit) = LocalConfig.resolveIssuer(environment: ["FT_ISSUER": "tanaka@dev-mbp"], configURL: url)
        XCTAssertEqual(id, "tanaka@dev-mbp")
        XCTAssertTrue(explicit)
    }

    func testResolveIssuerExplicitTrueForConfigFile() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var config = LocalConfig()
        config.issuerId = "alice@ci-runner"
        try config.save(to: url)

        let (id, explicit) = LocalConfig.resolveIssuer(environment: [:], configURL: url)
        XCTAssertEqual(id, "alice@ci-runner")
        XCTAssertTrue(explicit)
    }

    func testResolveIssuerExplicitFalseForFallback() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try LocalConfig().save(to: url)

        let (id, explicit) = LocalConfig.resolveIssuer(environment: [:], configURL: url)
        XCTAssertEqual(id, fallback)
        XCTAssertFalse(explicit)
    }

    /// resolveIssuerId は resolveIssuer(...).id へ畳んだ実装(重複実装を持たない)。
    /// 同じ入力で常に一致することを固定する
    func testResolveIssuerIdMatchesResolveIssuerID() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var config = LocalConfig()
        config.issuerId = "bob@laptop"
        try config.save(to: url)

        XCTAssertEqual(
            LocalConfig.resolveIssuerId(environment: [:], configURL: url),
            LocalConfig.resolveIssuer(environment: [:], configURL: url).id)
    }

    // MARK: - LocalConfig round-trip / back-compat

    func testLocalConfigRoundTripsIssuerId() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var config = LocalConfig()
        config.issuerId = "bob@laptop"
        try config.save(to: url)

        XCTAssertEqual(LocalConfig.load(from: url).issuerId, "bob@laptop")
    }

    /// 旧 config.json(issuerId キーが無い)も引き続き decode できる
    func testLocalConfigDecodesOldConfigWithoutIssuerId() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{\"defaultProject\":\"SampleApp\"}".utf8).write(to: url)

        let loaded = LocalConfig.load(from: url)
        XCTAssertNil(loaded.issuerId)
        XCTAssertEqual(loaded.defaultProject, "SampleApp")
    }
}
