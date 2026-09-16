// 2026-09-16 の負荷テストで拾った2件の修正:
//   (1) `reconcilePort` の「no running bridge」案内が `fleetest bridge up` とだけ言い、
//       udid を効かせる完成コマンド(`--device`)を出していなかった —— 案内どおり打っても
//       別デバイス・既定ポートに建ってしまい直らなかった。
//   (2) 同じ文言が、ブリッジが生きていて処理中で `/status` に答えられないときにも出ていた
//       (`bridgePorts(forUDID:)` は `/status` 応答だけで数えるため)。
//
// さらに2026-09-16 の実機実測で拾った3件目: (2)の初版は全ポート範囲(最大32本)へ
// `PortHolder.describe`(lsof を毎回起こす同期ブロッキング)を `withTaskGroup` で同時に起こしており、
// Swift の協調スレッドプールを埋め尽くして `ft_status` が200秒以上詰まった。作り直した実装は
// lsof を一切起こさず、候補ポートを台帳(`candidatePorts`)から絞ってから `BridgeDiscovery.isBound`
// (生ソケットの connect+poll。300ms 上限)だけで確かめる。
//
// ここでは文面を組み立てる純粋関数(`bridgeUpSuggestion`/`noResponsiveBridgeMessage`/
// `bridgeBusyOnUDIDMessage`)と、走査の広さを決める純粋関数(`cappedCandidatePorts`)、
// 台帳の絞り込み(`candidatePorts`。実デバイス・実ブリッジは使わず、注入した台帳ファイルだけで
// 固定する)を `UDIDBridgeDiagnosis`/入力を直接注入してテストする。
// `udidBridgeDiagnosis` 自体(`BridgeDiscovery.isBound`/`RunLease.holderPID`/
// `SimulatorCatalog.isPhysical` という既存の・既にテスト済みの部品を束ねるだけの IO 層)は
// 実ブリッジが無いと材料が作れないためここではテストしない。lsof を撃つテストは書かない。

import XCTest
import FTCore
import FTBridgeClient
@testable import fleetest_mcp

final class UDIDBridgeDiagnosisMessageTests: XCTestCase {

    // MARK: - bridgeUpSuggestion(3形)

    /// ①udid がシミュレータと判定できた: `--device` に udid をそのまま渡すコマンドを出す。
    /// `--physical` は付けない(名前より udid が優先されるので名前引きの曖昧さも迂回できる)
    func testBridgeUpSuggestionForSimulator() {
        let text = MCPServer.bridgeUpSuggestion(udid: "SIM-1234", isPhysical: false)
        XCTAssertTrue(text.contains("fleetest bridge up --device \"SIM-1234\""), text)
        XCTAssertFalse(text.contains("--physical"), text)
    }

    /// ①'udid が実機と判定できた: `--physical` を必ず添える(付けなければ実機 UDID は
    /// bridge up の形状判定に外れて名前引きされ、必ず失敗する)
    func testBridgeUpSuggestionForPhysicalDevice() {
        let text = MCPServer.bridgeUpSuggestion(udid: "00008130-ABCDEF", isPhysical: true)
        XCTAssertTrue(text.contains("fleetest bridge up --device \"00008130-ABCDEF\" --physical"), text)
    }

    /// ②引けない(シミュレータ・実機のどちらとも判定できない): **嘘のコマンドを出さない** ——
    /// 実際の udid を埋めた `--device "<udid>"` を組んではいけない
    func testBridgeUpSuggestionWhenPhysicalityIsUnknownDoesNotFabricateACommand() {
        let text = MCPServer.bridgeUpSuggestion(udid: "U1", isPhysical: nil)
        // 実際の udid を埋め込んだ、コピペで即使える(が確度の無い)コマンドを組んでいないこと。
        // `--device "<udid>"` はプレースホルダとしてのみ登場してよい
        XCTAssertFalse(text.contains("--device \"U1\""), text)
        XCTAssertFalse(text.contains("start it with"), text)
        XCTAssertTrue(text.contains("ft_list_devices"), text)
    }

    // MARK: - noResponsiveBridgeMessage(①②③の等号固定)

    /// ①名前(udid)からシミュレータと判定でき、他に LISTEN の痕跡も無い = 本当に居ない
    func testNoResponsiveBridgeMessageWhenGoneAndResolvedAsSimulator() {
        let text = MCPServer.noResponsiveBridgeMessage(
            udid: "SIM-1234",
            diagnosis: .init(listeningButUnresponsive: [], heldByRunPID: nil, isPhysical: false))
        XCTAssertEqual(text, "no running bridge is on udid SIM-1234. ft_list_devices shows which"
            + " devices have one; start it with `fleetest bridge up --device \"SIM-1234\"`"
            + " (a device without a bridge cannot be driven from MCP)")
    }

    /// ②本当に居ないが、実体も判定できない(名前引きできない)—— 事実だけ言い、嘘のコマンドは出ない
    func testNoResponsiveBridgeMessageWhenGoneAndUnresolvable() {
        let text = MCPServer.noResponsiveBridgeMessage(
            udid: "U1", diagnosis: .init(listeningButUnresponsive: [], heldByRunPID: nil, isPhysical: nil))
        XCTAssertTrue(text.hasPrefix("no running bridge is on udid U1."), text)
        XCTAssertFalse(text.contains("--device \"U1\""), text)
    }

    /// ③LISTEN しているが `/status` 無応答 = busy。**「no running bridge」とは言わない**
    /// (「居ない」と「答えない」を混同しない)。`bridge up` は勧めない
    func testNoResponsiveBridgeMessageWhenBusyDoesNotClaimAbsence() {
        let text = MCPServer.noResponsiveBridgeMessage(
            udid: "SIM-1234",
            diagnosis: .init(listeningButUnresponsive: [8124], heldByRunPID: nil, isPhysical: false))
        XCTAssertFalse(text.contains("no running bridge"), text)
        XCTAssertTrue(text.contains("port 8124"), text)
        XCTAssertTrue(text.contains("busy"), text)
    }

    /// busy かつ run が使用中と分かっているときは、その pid を理由として添える
    /// (`markDeviceInUse`/`writeAndWarnIfRunHolds` の警告と表現は重ねず、ここだけの1文で言う)
    func testBridgeBusyMessageNamesTheHoldingRunWhenKnown() {
        let text = MCPServer.bridgeBusyOnUDIDMessage(
            udid: "SIM-1234",
            diagnosis: .init(listeningButUnresponsive: [8124], heldByRunPID: 4242, isPhysical: false))
        XCTAssertTrue(text.contains("fleetest run (pid 4242)"), text)
        XCTAssertTrue(text.contains("is using this device right now"), text)
    }

    /// run の保持が分からないときはその一文を足さない(無い情報を捏造しない)
    func testBridgeBusyMessageOmitsRunNoteWhenUnknown() {
        let text = MCPServer.bridgeBusyOnUDIDMessage(
            udid: "SIM-1234",
            diagnosis: .init(listeningButUnresponsive: [8124], heldByRunPID: nil, isPhysical: false))
        XCTAssertFalse(text.contains("fleetest run"), text)
    }

    /// busy の案内は `fleetest bridge up` を勧めない(勧めると同じ機に2本目を起動させる)
    func testBridgeBusyMessageDoesNotRecommendBridgeUp() {
        let text = MCPServer.bridgeBusyOnUDIDMessage(
            udid: "SIM-1234",
            diagnosis: .init(listeningButUnresponsive: [8124], heldByRunPID: nil, isPhysical: nil))
        // 「`fleetest bridge up` は…のためのもの」と説明する1回だけは許容し、それ以外に
        // 積極的な推奨("start it with `fleetest bridge up")が無いことを見る
        XCTAssertFalse(text.contains("start it with `fleetest bridge up"), text)
    }

    // MARK: - reconcilePort との配線(diagnosis を渡すと busy 分岐へ回る)

    /// 応答ポート0本でも、LISTEN の痕跡があれば busy の文面になる(「no running bridge」ではない)
    func testReconcilePortUsesBusyMessageWhenDiagnosisShowsListeningPorts() {
        XCTAssertThrowsError(try MCPServer.reconcilePort(
            nil, udid: "U1", udidPorts: [],
            diagnosis: .init(listeningButUnresponsive: [8130], heldByRunPID: nil, isPhysical: false))
        ) {
            let text = $0.localizedDescription
            XCTAssertFalse(text.contains("no running bridge"), text)
            XCTAssertTrue(text.contains("port 8130"), text)
        }
    }

    /// diagnosis を省略した既存呼び出しは従来どおり「no running bridge」のまま
    /// (`testUDIDWithoutABridgeFails` と同じ入口。後方互換の確認)
    func testReconcilePortDefaultsToGoneMessageWithoutDiagnosis() {
        XCTAssertThrowsError(try MCPServer.reconcilePort(nil, udid: "U1", udidPorts: [])) {
            XCTAssertTrue($0.localizedDescription.contains("no running bridge is on udid"),
                          $0.localizedDescription)
        }
    }

    // MARK: - cappedCandidatePorts(走査の広さの上限。純粋関数・等号固定)

    /// 上限そのものをリテラルで固定する。**変異(数字を動かす)でここが落ちる**契約
    func testMaxUDIDBridgeCandidatePortsIsFour() {
        XCTAssertEqual(MCPServer.maxUDIDBridgeCandidatePorts, 4)
    }

    /// 上限以下ならそのまま(昇順)通す
    func testCappedCandidatePortsPassesThroughWhenAtOrBelowLimit() {
        XCTAssertEqual(MCPServer.cappedCandidatePorts([8125, 8123, 8124]), [8123, 8124, 8125])
    }

    /// 上限を超えたら**ポート番号の小さい側から**その本数だけに切る(全ポート走査に戻る変異・
    /// 上限を外す変異のどちらでも落ちる)
    func testCappedCandidatePortsCutsToTheLowestPortsWhenAboveLimit() {
        let many: [UInt16] = [8130, 8123, 8129, 8124, 8128, 8125]
        XCTAssertEqual(MCPServer.cappedCandidatePorts(many), [8123, 8124, 8125, 8128])
    }

    /// 空集合は空のまま(境界)
    func testCappedCandidatePortsHandlesEmptyInput() {
        XCTAssertEqual(MCPServer.cappedCandidatePorts([]), [])
    }

    // MARK: - candidatePorts(台帳の絞り込み。lsof は撃たない・注入した台帳ファイルだけで確認)

    private func makeTempRepoRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-udid-candidate-ports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
        return root
    }

    /// repoRoot が解決できない(nil)ときは何も見ずに空を返す(lsof はおろか ps すら起こさない)
    func testCandidatePortsReturnsEmptyWithoutRepoRoot() {
        XCTAssertEqual(MCPServer.candidatePorts(forUDID: "U1", repoRoot: nil), Set<UInt16>())
    }

    /// 台帳が何も無ければ空(`.pid` ファイルが無いので `BridgeLauncher.portsByUDID` は
    /// `ps` すら起こさずに空を返す。`.inapp` も無いので候補は0件)
    func testCandidatePortsReturnsEmptyWithEmptyLedger() throws {
        let root = try makeTempRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(MCPServer.candidatePorts(forUDID: "U1", repoRoot: root), Set<UInt16>())
    }

    /// **`.inapp` 台帳に記録された udid と一致すれば候補に入る**(in-app は `.pid` を持たないので
    /// これが唯一の経路)。実体の書き込みは `InAppBridgeState.write`(公開 API)を使い、
    /// 自前パーサがその契約(先頭語 = udid)と食い違わないことも一緒に確かめる
    func testCandidatePortsFindsPortFromMatchingInAppLedger() throws {
        let root = try makeTempRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent(".fleetest")
        InAppBridgeState.write(stateDir: stateDir, port: 8140, udid: "SIM-1234", bundleID: "com.example.app")

        XCTAssertEqual(MCPServer.candidatePorts(forUDID: "SIM-1234", repoRoot: root), Set<UInt16>([8140]))
    }

    /// 別の udid の `.inapp` 台帳は候補に入れない(取り違えない)
    func testCandidatePortsIgnoresInAppLedgerForADifferentUDID() throws {
        let root = try makeTempRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent(".fleetest")
        InAppBridgeState.write(stateDir: stateDir, port: 8140, udid: "OTHER-UDID", bundleID: "com.example.app")

        XCTAssertEqual(MCPServer.candidatePorts(forUDID: "SIM-1234", repoRoot: root), Set<UInt16>())
    }

    /// 複数の `.inapp` 台帳のうち一致するものだけを拾う
    func testCandidatePortsMergesMultipleMatchingInAppLedgers() throws {
        let root = try makeTempRepoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent(".fleetest")
        InAppBridgeState.write(stateDir: stateDir, port: 8140, udid: "SIM-1234", bundleID: "com.example.app")
        InAppBridgeState.write(stateDir: stateDir, port: 8141, udid: "SIM-1234", bundleID: "com.example.other")
        InAppBridgeState.write(stateDir: stateDir, port: 8142, udid: "OTHER-UDID", bundleID: "com.example.app")

        XCTAssertEqual(MCPServer.candidatePorts(forUDID: "SIM-1234", repoRoot: root),
                      Set<UInt16>([8140, 8141]))
    }
}
