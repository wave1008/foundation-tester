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

/// `LocalConfig.save` の原子性。読み手(`FMLock.concurrency` → `load`)は別プロセスから随時読むので、
/// truncate → 書込の2段になる素の write では途中の空ファイルを読んで decode 失敗 = 空設定へ倒れる
/// (fmConcurrency が既定へ戻る)。
final class LocalConfigSaveAtomicityTests: XCTestCase {

    private func tempConfigURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConfigAtomic-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// ソース走査: save の write が `.atomic` を付けている(競合テストは取りこぼしうるので、
    /// 決定的な砦をこちらに置く)
    func testSaveWritesAtomically() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/LocalConfig.swift"), encoding: .utf8)
        let saveBody = try XCTUnwrap(source.range(of: "public func save(to url: URL")
            .map { source[$0.lowerBound...] })
        XCTAssertTrue(saveBody.contains("options: .atomic"),
                      "LocalConfig.save の write は .atomic でなければならない")
    }

    /// 書き手と読み手を同時に回しても、読み手が「途中の状態」(decode 失敗 → 空設定)を1度も見ない。
    /// 常に fmConcurrency を入れて書くので、空設定を読んだら torn read
    func testConcurrentLoadNeverObservesATornFile() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var initial = LocalConfig()
        initial.fmConcurrency = 1
        try initial.save(to: url)

        let torn = NSLock()
        var tornReads = 0
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for i in 0..<300 {
                var config = LocalConfig()
                config.fmConcurrency = 1 + (i % 7)
                // issuerId で本文を長くして、truncate 後の空の窓を広げる
                config.issuerId = String(repeating: "x", count: 2_000)
                try? config.save(to: url)
            }
        }
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for _ in 0..<3_000 where LocalConfig.load(from: url).fmConcurrency == nil {
                torn.lock(); tornReads += 1; torn.unlock()
            }
        }
        group.wait()
        XCTAssertEqual(tornReads, 0, "読み手が途中まで書かれた config.json を見た")
    }
}
