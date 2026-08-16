// `--host` 登録簿(docs/remote-runner.md §13)の純粋ロジック。
// ssh/ファイル I/O は Sources/ftester/RemoteCommands.swift の RemoteHostResolver 側(e2e に残す)。

import Foundation
import XCTest
@testable import FTCore

final class RemoteHostRegistryTests: XCTestCase {

    // MARK: - validateName

    func testValidateNameAcceptsAlnumAndAllowedPunctuation() throws {
        XCTAssertNoThrow(try RemoteHostRegistry.validateName("M1Ultra"))
        XCTAssertNoThrow(try RemoteHostRegistry.validateName("mac_2.studio-1"))
    }

    func testValidateNameRejectsEmpty() {
        XCTAssertThrowsError(try RemoteHostRegistry.validateName(""))
    }

    func testValidateNameRejectsWhitespaceOnly() {
        XCTAssertThrowsError(try RemoteHostRegistry.validateName("   "))
    }

    func testValidateNameRejectsReservedLocal() {
        XCTAssertThrowsError(try RemoteHostRegistry.validateName("local"))
    }

    /// 予約は "local" の完全一致のみ("Local" 等は通常の名前として使える)。ケースセンシティブは
    /// machines プロファイル名と同じ規律(CLAUDE.md 委任事項)
    func testValidateNameAllowsDifferentCaseOfLocal() throws {
        XCTAssertNoThrow(try RemoteHostRegistry.validateName("Local"))
    }

    func testValidateNameRejectsSpaces() {
        XCTAssertThrowsError(try RemoteHostRegistry.validateName("M1 Ultra"))
    }

    func testValidateNameRejectsSlash() {
        XCTAssertThrowsError(try RemoteHostRegistry.validateName("m1/ultra"))
    }

    func testValidateNameRejectsAtSign() {
        XCTAssertThrowsError(try RemoteHostRegistry.validateName("user@host"))
    }

    // MARK: - resolve

    func testResolveFindsRegisteredEntry() {
        let entry = RemoteHostEntry(name: "M1Ultra", host: "wave1008@192.168.20.95")
        guard case .registered(let found) = RemoteHostRegistry.resolve("M1Ultra", entries: [entry]) else {
            return XCTFail("expected .registered")
        }
        XCTAssertEqual(found, entry)
    }

    /// **登録簿が優先**: 同名が登録されていれば、その文字列を生の ssh 宛先として解釈し直さない
    func testResolvePrefersRegistryOverRawInterpretation() {
        let entry = RemoteHostEntry(name: "M1Ultra", host: "wave1008@192.168.20.95")
        let resolution = RemoteHostRegistry.resolve("M1Ultra", entries: [entry])
        guard case .registered = resolution else {
            return XCTFail("expected .registered, got \(resolution)")
        }
    }

    func testResolveFallsBackToRawTargetWhenNotRegistered() {
        guard case .rawTarget(let raw) = RemoteHostRegistry.resolve("someone@example.com", entries: []) else {
            return XCTFail("expected .rawTarget")
        }
        XCTAssertEqual(raw, "someone@example.com")
    }

    func testResolveIsCaseSensitive() {
        let entry = RemoteHostEntry(name: "M1Ultra", host: "wave1008@192.168.20.95")
        guard case .rawTarget = RemoteHostRegistry.resolve("m1ultra", entries: [entry]) else {
            return XCTFail("expected .rawTarget (case must not match)")
        }
    }

    func testResolveReservedLocal() {
        XCTAssertEqual(RemoteHostRegistry.resolve("local", entries: []), .reserved)
    }

    func testResolveReservedEmpty() {
        XCTAssertEqual(RemoteHostRegistry.resolve("", entries: []), .reserved)
    }

    func testResolveReservedWhitespaceOnly() {
        XCTAssertEqual(RemoteHostRegistry.resolve("   ", entries: []), .reserved)
    }

    /// "local" という名前の登録があっても reserved が勝つ(RemoteHostRegistry.validateName が
    /// そもそも登録時に "local" を拒否するので、この状況は登録簿の手編集でしか起こらない —
    /// それでも fail-closed に倒す)
    func testResolveReservedWinsEvenIfRegistryHasLocalEntry() {
        let entry = RemoteHostEntry(name: "local", host: "should-not-be-used")
        XCTAssertEqual(RemoteHostRegistry.resolve("local", entries: [entry]), .reserved)
    }

    // MARK: - upsert

    func testUpsertAddsNewEntry() {
        let result = RemoteHostRegistry.upsert(
            RemoteHostEntry(name: "M1Ultra", host: "a@host"), into: [])
        XCTAssertEqual(result, [RemoteHostEntry(name: "M1Ultra", host: "a@host")])
    }

    func testUpsertReplacesSameName() {
        let existing = [RemoteHostEntry(name: "M1Ultra", host: "old@host", dir: "~/old")]
        let result = RemoteHostRegistry.upsert(
            RemoteHostEntry(name: "M1Ultra", host: "new@host", dir: "~/new"), into: existing)
        XCTAssertEqual(result, [RemoteHostEntry(name: "M1Ultra", host: "new@host", dir: "~/new")])
    }

    /// 出力が実行のたびに揺れないよう、名前順で安定に並べる
    func testUpsertKeepsResultSortedByName() {
        var entries: [RemoteHostEntry] = []
        entries = RemoteHostRegistry.upsert(RemoteHostEntry(name: "zeta", host: "z@host"), into: entries)
        entries = RemoteHostRegistry.upsert(RemoteHostEntry(name: "alpha", host: "a@host"), into: entries)
        entries = RemoteHostRegistry.upsert(RemoteHostEntry(name: "mid", host: "m@host"), into: entries)
        XCTAssertEqual(entries.map(\.name), ["alpha", "mid", "zeta"])
    }

    // MARK: - remove

    func testRemoveDeletesByName() {
        let entries = [
            RemoteHostEntry(name: "a", host: "a@host"),
            RemoteHostEntry(name: "b", host: "b@host"),
        ]
        XCTAssertEqual(RemoteHostRegistry.remove(name: "a", from: entries),
                      [RemoteHostEntry(name: "b", host: "b@host")])
    }

    func testRemoveIsNoOpWhenNameAbsent() {
        let entries = [RemoteHostEntry(name: "a", host: "a@host")]
        XCTAssertEqual(RemoteHostRegistry.remove(name: "nonexistent", from: entries), entries)
    }

    // MARK: - duplicateTargets

    func testDuplicateTargetsEmptyWhenAllUnique() {
        let entries = [
            RemoteHostEntry(name: "a", host: "one@host"),
            RemoteHostEntry(name: "b", host: "two@host"),
        ]
        XCTAssertEqual(RemoteHostRegistry.duplicateTargets(entries), [])
    }

    func testDuplicateTargetsFindsSharedHost() {
        let entries = [
            RemoteHostEntry(name: "a", host: "shared@host"),
            RemoteHostEntry(name: "b", host: "shared@host"),
            RemoteHostEntry(name: "c", host: "unique@host"),
        ]
        XCTAssertEqual(RemoteHostRegistry.duplicateTargets(entries), ["shared@host"])
    }

    // MARK: - LocalConfig round-trip / back-compat

    func testLocalConfigRoundTripsRemoteHosts() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteHostRegistryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")

        var config = LocalConfig()
        config.remoteHosts = [RemoteHostEntry(name: "M1Ultra", host: "wave1008@192.168.20.95",
                                              dir: "~/ftester-runner")]
        try config.save(to: url)

        let loaded = LocalConfig.load(from: url)
        XCTAssertEqual(loaded.remoteHosts, config.remoteHosts)
    }

    /// 既存の config.json を読んでも壊れない。**廃止した machineName のような未知キーは
    /// 黙って無視される**(2026-08-17 に登録名を廃止したので、古い設定がそのまま残っている)
    func testLocalConfigDecodesOldConfigWithUnknownKeys() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteHostRegistryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data("{\"machineName\":\"M2Ultra\"}".utf8).write(to: url)

        let loaded = LocalConfig.load(from: url)
        XCTAssertNil(loaded.remoteHosts)
    }

    // MARK: - RemoteCompat.mismatches

    /// 照合は rev と toolchain の2つだけ(2026-08-17)。機械の身元は ssh の宛先が保証しており、
    /// 「リモートの登録名」という概念自体を廃止した
    func testMismatchesChecksRevisionAndToolchainOnly() {
        XCTAssertEqual(
            RemoteCompat.mismatches(localRevision: "abc", remoteRevision: "abc",
                                    localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.0"),
            [])
        XCTAssertEqual(
            RemoteCompat.mismatches(localRevision: "abc", remoteRevision: "def",
                                    localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.0").count,
            1)
    }

}
