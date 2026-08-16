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
                                              dir: "~/ftester-runner", machine: "M1Ultra")]
        try config.save(to: url)

        let loaded = LocalConfig.load(from: url)
        XCTAssertEqual(loaded.remoteHosts, config.remoteHosts)
    }

    /// 既存の(remoteHosts キーを持たない)config.json を読んでも壊れない
    func testLocalConfigDecodesOldConfigWithoutRemoteHosts() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteHostRegistryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data("{\"machineName\":\"M2Ultra\"}".utf8).write(to: url)

        let loaded = LocalConfig.load(from: url)
        XCTAssertEqual(loaded.machineName, "M2Ultra")
        XCTAssertNil(loaded.remoteHosts)
    }

    // MARK: - RemoteCompat.mismatches (machineName, 3rd item added for §13)

    /// localMachineName が nil(登録簿に machine キャッシュが無い/生の ssh 宛先)のときは
    /// 照合しない — 既存の2項目だけで判定する
    func testMismatchesSkipsMachineNameWhenLocalIsNil() {
        let reasons = RemoteCompat.mismatches(
            localRevision: "abc", remoteRevision: "abc",
            localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.0",
            localMachineName: nil, remoteMachineName: "SomeOtherMachine")
        XCTAssertEqual(reasons, [])
    }

    func testMismatchesEmptyWhenMachineNameMatches() {
        let reasons = RemoteCompat.mismatches(
            localRevision: "abc", remoteRevision: "abc",
            localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.0",
            localMachineName: "M1Ultra", remoteMachineName: "M1Ultra")
        XCTAssertEqual(reasons, [])
    }

    func testMismatchesFlagsMachineNameMismatch() {
        let reasons = RemoteCompat.mismatches(
            localRevision: "abc", remoteRevision: "abc",
            localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.0",
            localMachineName: "M1Ultra", remoteMachineName: "M2Ultra")
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].contains("machine name"), reasons[0])
        XCTAssertTrue(reasons[0].contains("local=M1Ultra") && reasons[0].contains("remote=M2Ultra"), reasons[0])
    }

    /// fail-closed: local に期待値があるのにリモート値が取れない(nil)場合も不一致
    func testMismatchesFlagsMachineNameWhenRemoteUnavailable() {
        let reasons = RemoteCompat.mismatches(
            localRevision: "abc", remoteRevision: "abc",
            localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.0",
            localMachineName: "M1Ultra", remoteMachineName: nil)
        XCTAssertEqual(reasons.count, 1)
        XCTAssertTrue(reasons[0].contains("could not determine the remote value"), reasons[0])
    }

    /// 既存呼び出し(machineName 引数を渡さない)は後方互換のまま動く
    func testMismatchesBackwardCompatibleWithoutMachineNameArgs() {
        let reasons = RemoteCompat.mismatches(
            localRevision: "abc", remoteRevision: "abc",
            localToolchain: "Xcode 27.0", remoteToolchain: "Xcode 27.0")
        XCTAssertEqual(reasons, [])
    }

    // MARK: - RemoteMachineNameProbe.parse

    func testMachineNameProbeParsesRegisteredName() {
        XCTAssertEqual(RemoteMachineNameProbe.parse("Machine name: M1Ultra\nConfig file: /x/config.json"),
                      "M1Ultra")
    }

    func testMachineNameProbeReturnsNilForUnregistered() {
        XCTAssertNil(RemoteMachineNameProbe.parse(
            "Machine name: unregistered (register with: ftester machine set \"<name>\")\nConfig file: /x"))
    }

    /// FT_MACHINE 環境変数由来の注記は名前の一部ではないので削る
    func testMachineNameProbeStripsEnvironmentVariableNote() {
        XCTAssertEqual(RemoteMachineNameProbe.parse(
            "Machine name: CI-Runner (from the FT_MACHINE environment variable)\nConfig file: /x"),
            "CI-Runner")
    }

    func testMachineNameProbeReturnsNilForGarbageOutput() {
        XCTAssertNil(RemoteMachineNameProbe.parse("bash: ftester: command not found"))
    }

    func testMachineNameProbeReturnsNilForEmptyOutput() {
        XCTAssertNil(RemoteMachineNameProbe.parse(""))
    }
}
