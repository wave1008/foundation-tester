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
// 4件目(コードレビュー指摘): 3件目の作り直しでも `udidBridgeDiagnosis` 自体は素の async 関数の
// 本体に `ps`/`simctl`/`devicectl` という同期ブロッキングをそのまま書いていた —— 並列に起こして
// いなくても、`Shell.run` の完了待ち(`DispatchSemaphore.wait`)は協調スレッドプールのワーカーを
// 直列に最大 devicectl の timeout(30秒)ぶん占有する。同じ型の事故が本数だけ減って残っていた。
// `udidBridgeDiagnosisBlocking`(同期本体)を専用 Thread(`runOffCooperativePool`)へ逃がし、
// `budgeted` で全体に `udidBridgeDiagnosisBudget`(3秒)の上限を掛けるよう作り直した。
//
// 5件目(2026-09-17 M3b。高負荷下の実測): `SimulatorCatalog.isPhysical(udid:)` は
// `(try? devices()) ?? []` で simctl の読み取り失敗を空一覧に潰しており、「どちらにも載っていない」
// と「一覧が読めなかった」が同じ nil に落ちていた。`SimulatorCatalog.UDIDLookup`(4値。
// simulator/physical/notFound/unreadable(理由))へ置き換え、`bridgeUpSuggestion`/
// `noResponsiveBridgeMessage` が「読めなかった」を「載っていない」と断定しない文面に分けた。
// 既存の `isPhysical(udid:)`(Bool?)の他の呼び手(ApiLiveCommand 等)は変更していない。
//
// ここでは文面を組み立てる純粋関数(`bridgeUpSuggestion`/`noResponsiveBridgeMessage`/
// `bridgeBusyOnUDIDMessage`)と、走査の広さを決める純粋関数(`cappedCandidatePorts`)、
// 台帳の絞り込み(`candidatePorts`。実デバイス・実ブリッジは使わず、注入した台帳ファイルだけで
// 固定する)を `UDIDBridgeDiagnosis`/入力を直接注入してテストする。
// `udidBridgeDiagnosis` 自体(`BridgeDiscovery.isBound`/`RunLease.holderPID`/
// `SimulatorCatalog.lookupUDID` という既存の・既にテスト済みの部品を束ねるだけの IO 層)は
// 実ブリッジが無いと材料が作れないためここではテストしない。lsof を撃つテストは書かない。
// **上限の仕組み(`budgeted`/`runOffCooperativePool`)だけは時間のかかるダミー work を注入して
// テストする**(実際の ps/simctl/devicectl は起こさない。下部の MARK 参照)。

import XCTest
import Foundation
import FTCore
import FTBridgeClient
@testable import fleetest_mcp

final class UDIDBridgeDiagnosisMessageTests: XCTestCase {

    // MARK: - bridgeUpSuggestion(4形)

    /// ①udid がシミュレータと判定できた: `--device` に udid をそのまま渡すコマンドを出す。
    /// `--physical` は付けない(名前より udid が優先されるので名前引きの曖昧さも迂回できる)
    func testBridgeUpSuggestionForSimulator() {
        let text = MCPServer.bridgeUpSuggestion(udid: "SIM-1234", lookup: .simulator)
        XCTAssertTrue(text.contains("fleetest bridge up --device \"SIM-1234\""), text)
        XCTAssertFalse(text.contains("--physical"), text)
    }

    /// ①'udid が実機と判定できた: `--physical` を必ず添える(付けなければ実機 UDID は
    /// bridge up の形状判定に外れて名前引きされ、必ず失敗する)
    func testBridgeUpSuggestionForPhysicalDevice() {
        let text = MCPServer.bridgeUpSuggestion(udid: "00008130-ABCDEF", lookup: .physical)
        XCTAssertTrue(text.contains("fleetest bridge up --device \"00008130-ABCDEF\" --physical"), text)
    }

    /// ②一覧は読めたがどちらにも載っていない: **嘘のコマンドを出さない** ——
    /// 実際の udid を埋めた `--device "<udid>"` を組んではいけない
    func testBridgeUpSuggestionWhenNotFoundDoesNotFabricateACommand() {
        let text = MCPServer.bridgeUpSuggestion(udid: "U1", lookup: .notFound)
        // 実際の udid を埋め込んだ、コピペで即使える(が確度の無い)コマンドを組んでいないこと。
        // `--device "<udid>"` はプレースホルダとしてのみ登場してよい
        XCTAssertFalse(text.contains("--device \"U1\""), text)
        XCTAssertFalse(text.contains("start it with"), text)
        XCTAssertTrue(text.contains("ft_list_devices"), text)
        XCTAssertTrue(text.contains("not currently listed"), text)
    }

    /// ③一覧そのものが読めなかった(負荷下の simctl タイムアウト等): 「載っていない」と断定しない。
    /// 読めなかった理由をそのまま運び、②と文面を分ける(2026-09-17 実測の修正)
    func testBridgeUpSuggestionWhenUnreadableStatesTheReasonAndDoesNotClaimAbsence() {
        let text = MCPServer.bridgeUpSuggestion(
            udid: "U1", lookup: .unreadable("simctl list devices failed: timed out"))
        XCTAssertFalse(text.contains("--device \"U1\""), text)
        XCTAssertFalse(text.contains("start it with"), text)
        XCTAssertFalse(text.contains("not currently listed"), text)
        XCTAssertTrue(text.contains("could not read the simulator/physical device lists"), text)
        XCTAssertTrue(text.contains("simctl list devices failed: timed out"), text)
        XCTAssertTrue(text.contains("ft_list_devices"), text)
    }

    // MARK: - noResponsiveBridgeMessage(①②③の等号固定)

    /// ①名前(udid)からシミュレータと判定でき、他に LISTEN の痕跡も無い = 本当に居ない
    func testNoResponsiveBridgeMessageWhenGoneAndResolvedAsSimulator() {
        let text = MCPServer.noResponsiveBridgeMessage(
            udid: "SIM-1234",
            diagnosis: .init(listeningButUnresponsive: [], heldByRunPID: nil, lookup: .simulator))
        XCTAssertEqual(text, "no running bridge is on udid SIM-1234. ft_list_devices shows which"
            + " devices have one; start it with `fleetest bridge up --device \"SIM-1234\"`"
            + " (a device without a bridge cannot be driven from MCP)")
    }

    /// ②本当に居ないが、実体も判定できない(名前引きできない)—— 事実だけ言い、嘘のコマンドは出ない
    func testNoResponsiveBridgeMessageWhenGoneAndUnresolvable() {
        let text = MCPServer.noResponsiveBridgeMessage(
            udid: "U1", diagnosis: .init(listeningButUnresponsive: [], heldByRunPID: nil, lookup: .notFound))
        XCTAssertTrue(text.hasPrefix("no running bridge is on udid U1."), text)
        XCTAssertFalse(text.contains("--device \"U1\""), text)
    }

    /// ②' 一覧そのものが読めなかった(M3b。負荷下の simctl タイムアウト等): 「載っていない」と
    /// 断定せず、読めなかった事実を言う —— `.notFound` と文面を混同しない
    func testNoResponsiveBridgeMessageWhenListsAreUnreadableStatesTheReason() {
        let text = MCPServer.noResponsiveBridgeMessage(
            udid: "U1", diagnosis: .init(listeningButUnresponsive: [], heldByRunPID: nil,
                                         lookup: .unreadable("simctl list devices failed: timed out")))
        XCTAssertTrue(text.hasPrefix("no running bridge is on udid U1."), text)
        XCTAssertFalse(text.contains("--device \"U1\""), text)
        XCTAssertFalse(text.contains("not currently listed"), text)
        XCTAssertTrue(text.contains("could not read the simulator/physical device lists"), text)
        XCTAssertTrue(text.contains("simctl list devices failed: timed out"), text)
    }

    /// ③LISTEN しているが `/status` 無応答 = busy。**「no running bridge」とは言わない**
    /// (「居ない」と「答えない」を混同しない)。`bridge up` は勧めない
    func testNoResponsiveBridgeMessageWhenBusyDoesNotClaimAbsence() {
        let text = MCPServer.noResponsiveBridgeMessage(
            udid: "SIM-1234",
            diagnosis: .init(listeningButUnresponsive: [8124], heldByRunPID: nil, lookup: .simulator))
        XCTAssertFalse(text.contains("no running bridge"), text)
        XCTAssertTrue(text.contains("port 8124"), text)
        XCTAssertTrue(text.contains("busy"), text)
    }

    /// busy かつ run が使用中と分かっているときは、その pid を理由として添える
    /// (`markDeviceInUse`/`writeAndWarnIfInUse` の警告と表現は重ねず、ここだけの1文で言う)
    func testBridgeBusyMessageNamesTheHoldingRunWhenKnown() {
        let text = MCPServer.bridgeBusyOnUDIDMessage(
            udid: "SIM-1234",
            diagnosis: .init(listeningButUnresponsive: [8124], heldByRunPID: 4242, lookup: .simulator))
        XCTAssertTrue(text.contains("fleetest run (pid 4242)"), text)
        XCTAssertTrue(text.contains("is using this device right now"), text)
    }

    /// run の保持が分からないときはその一文を足さない(無い情報を捏造しない)
    func testBridgeBusyMessageOmitsRunNoteWhenUnknown() {
        let text = MCPServer.bridgeBusyOnUDIDMessage(
            udid: "SIM-1234",
            diagnosis: .init(listeningButUnresponsive: [8124], heldByRunPID: nil, lookup: .simulator))
        XCTAssertFalse(text.contains("fleetest run"), text)
    }

    /// busy の案内は `fleetest bridge up` を勧めない(勧めると同じ機に2本目を起動させる)
    func testBridgeBusyMessageDoesNotRecommendBridgeUp() {
        let text = MCPServer.bridgeBusyOnUDIDMessage(
            udid: "SIM-1234",
            diagnosis: .init(listeningButUnresponsive: [8124], heldByRunPID: nil, lookup: .notFound))
        // 「`fleetest bridge up` は…のためのもの」と説明する1回だけは許容し、それ以外に
        // 積極的な推奨("start it with `fleetest bridge up")が無いことを見る
        XCTAssertFalse(text.contains("start it with `fleetest bridge up"), text)
    }

    // MARK: - reconcilePort との配線(diagnosis を渡すと busy 分岐へ回る)

    /// 応答ポート0本でも、LISTEN の痕跡があれば busy の文面になる(「no running bridge」ではない)
    func testReconcilePortUsesBusyMessageWhenDiagnosisShowsListeningPorts() {
        XCTAssertThrowsError(try MCPServer.reconcilePort(
            nil, udid: "U1", udidPorts: [],
            diagnosis: .init(listeningButUnresponsive: [8130], heldByRunPID: nil, lookup: .simulator))
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

    // MARK: - maintainer-notes §51.6(2026-09-25実測): 診断が予算超過で完走しなかった回を「居ない」に畳まない
    //
    // 実機 iPhone SE3 を高負荷下で MCP 越しに駆動していたセッションが、ちょうど生きている
    // udid(明示 port 8152 も生存)に対して交互に「no running bridge … run `fleetest bridge up`」で
    // 失敗した。原因は `udidBridgeDiagnosis` が予算超過時に返す値(旧 `.unknown`)が、
    // 「診断していない」ときの default 引数と同じ値を再利用しており、`noResponsiveBridgeMessage` が
    // 両者を区別できなかったこと。`UDIDBridgeDiagnosis.timedOut` で区別し、`.unknown`
    // (timedOut: false・default 引数用)と `.diagnosisTimedOut`(timedOut: true・実際に時間切れ)を
    // 分けた。

    /// 既定値をリテラルで固定する(CLAUDE.md「既定値はリテラルで固定するテストを置く」)。
    /// `.unknown` は「診断していない」の意味を保つため `timedOut: false` のまま
    func testUnknownDefaultsToNotTimedOut() {
        XCTAssertFalse(MCPServer.UDIDBridgeDiagnosis.unknown.timedOut)
    }

    /// `.diagnosisTimedOut` は `.unknown` と別の値で、`timedOut: true` を立てる
    /// (両方向を掛ける: `.unknown` が false 固定でも `.diagnosisTimedOut` まで false のままでは
    /// 「常に false を返す」変異を見逃す)
    func testDiagnosisTimedOutIsFlaggedAndDistinctFromUnknown() {
        XCTAssertTrue(MCPServer.UDIDBridgeDiagnosis.diagnosisTimedOut.timedOut)
        XCTAssertNotEqual(MCPServer.UDIDBridgeDiagnosis.diagnosisTimedOut,
                          MCPServer.UDIDBridgeDiagnosis.unknown)
    }

    /// `timedOut: true` のときは「no running bridge」を名乗らず `bridge up` も勧めない
    /// (旧実装はここが `.unknown` と区別できず、生きたブリッジへ2本目の起動を勧めかけた)
    func testNoResponsiveBridgeMessageWhenTimedOutDoesNotClaimAbsence() {
        let text = MCPServer.noResponsiveBridgeMessage(
            udid: "U1", diagnosis: MCPServer.UDIDBridgeDiagnosis.diagnosisTimedOut)
        XCTAssertFalse(text.contains("no running bridge"), text)
        // the message may explain *that* `fleetest bridge up` is not being suggested (so the
        // literal substring can appear) — what must never appear is the actual recommendation
        XCTAssertFalse(text.contains("start it with `fleetest bridge up"), text)
        XCTAssertTrue(text.contains("could not confirm"), text)
    }

    /// `bridgeDiagnosisUnconfirmedMessage` の文面を等号で固定する
    func testBridgeDiagnosisUnconfirmedMessageExactWording() {
        let text = MCPServer.bridgeDiagnosisUnconfirmedMessage(udid: "U1")
        XCTAssertEqual(text, "could not confirm whether a bridge for udid U1 is running — the"
            + " diagnosis did not finish within its time budget (the Mac or the device may be busy"
            + " right now). This does not mean the bridge is gone, and `fleetest bridge up` is not"
            + " suggested; retry the call in a moment.")
    }

    /// `timedOut` は busy/wedged より先に見る: どちらも非空のまま timedOut が立っていても
    /// 「確かめられなかった」を名乗る(busy/wedged は probe が完走してはじめて言える事実なので、
    /// 完走していない回にそれらの文言を出してはいけない)
    func testTimedOutTakesPriorityOverBusyAndWedged() {
        let text = MCPServer.noResponsiveBridgeMessage(
            udid: "U1", diagnosis: .init(listeningButUnresponsive: [8124], heldByRunPID: nil,
                                         lookup: .simulator, wedgedPorts: [8125], timedOut: true))
        XCTAssertTrue(text.contains("could not confirm"), text)
        // the specific ports named by the busy/wedged branches must not leak into the
        // unconfirmed message — their presence would mean those branches ran instead
        XCTAssertFalse(text.contains("8124"), text)
        XCTAssertFalse(text.contains("8125"), text)
        XCTAssertFalse(text.contains("gone; only its transport"), text)
    }

    /// `reconcilePort` に `.diagnosisTimedOut` を渡すと、投げるエラーが確認不能の文面になる
    /// (`testReconcilePortUsesBusyMessageWhenDiagnosisShowsListeningPorts` と同じ配線の確認)
    func testReconcilePortUsesUnconfirmedMessageWhenDiagnosisTimedOut() {
        XCTAssertThrowsError(try MCPServer.reconcilePort(
            8152, udid: "U1", udidPorts: [], diagnosis: MCPServer.UDIDBridgeDiagnosis.diagnosisTimedOut)
        ) {
            let text = $0.localizedDescription
            XCTAssertTrue(text.contains("could not confirm"), text)
            XCTAssertFalse(text.contains("no running bridge"), text)
        }
    }

    // MARK: - maintainer-notes §51.6: 明示 port の直接確認(`explicitPortIdentityProbe` の3値のうち純粋な部分)

    /// 一致したときの文面は組まない(呼び出し側は port をそのまま返すだけ)ので、ここでは
    /// 食い違い(`confirmedMismatch`)側の文面だけを固定する
    func testExplicitPortMismatchMessageExactWording() {
        let text = MCPServer.explicitPortMismatchMessage(
            port: 8152, udid: "U1", actualUDID: "U2")
        XCTAssertEqual(text, "port 8152 is not a bridge answering on udid U1 — it answered as a"
            + " different device (udid U2). Pass only one of port/udid, or use the port and udid"
            + " that belong to the same device")
    }

    /// `ExplicitPortIdentity` は3値のまま等号比較できる(呼び出し側が `switch` で畳み込まずに
    /// 扱えることの最小確認)
    func testExplicitPortIdentityCasesAreDistinct() {
        XCTAssertNotEqual(MCPServer.ExplicitPortIdentity.confirmedMatch,
                          MCPServer.ExplicitPortIdentity.unknown)
        XCTAssertNotEqual(MCPServer.ExplicitPortIdentity.confirmedMismatch(actualUDID: "U2"),
                          MCPServer.ExplicitPortIdentity.confirmedMatch)
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

    // MARK: - budgeted / runOffCooperativePool(協調スレッドプールを塞がない上限)
    //
    // `udidBridgeDiagnosis` 本体(ps/simctl/devicectl)は実ブリッジ無しでは材料が作れないので
    // ここではテストしない(ファイル冒頭の方針どおり)。代わりに、production の
    // `udidBridgeDiagnosis` が実際に組んでいる「専用 Thread + 上限」の機構(`budgeted` /
    // `runOffCooperativePool`)そのものへ、時間のかかるダミーの同期処理(`Thread.sleep`)を注入して
    // 固定する。実 IO は一切起こさない。

    /// 上限の秒数をリテラルで固定する。変異(数字を動かす)で落ちる契約
    func testUDIDBridgeDiagnosisBudgetIsThreeSeconds() {
        XCTAssertEqual(MCPServer.udidBridgeDiagnosisBudget, .seconds(3))
    }

    /// 上限を大きく超えて刺さり続けるダミーの同期処理を注入すると、`budgeted` は work の全長
    /// (2秒)を待たずに fallback へ落ちて先に返る。
    /// **所要は戻り値でなく経過時間で測る**(CLAUDE.md「予算のテストは所要を測る」): 戻り値だけを
    /// 見るテストは、`budgeted` が結局 work の完了を待ってから fallback へすり替えるだけの実装
    /// (= 協調プールを塞いだまま)でも通ってしまう
    func testBudgetedFallsBackWithoutWaitingForSlowWorkToFinish() async {
        let budget = Duration.milliseconds(150)
        let clock = ContinuousClock()

        let start = clock.now
        let result = await MCPServer.budgeted(budget, fallback: -1) {
            Thread.sleep(forTimeInterval: 2)
            return 99
        }
        let elapsed = clock.now - start

        XCTAssertEqual(result, -1, "must fall back to the default, not the slow work's value")
        XCTAssertLessThan(elapsed, .seconds(1),
                          "must return near the budget (150ms), not near the slow work (2s): \(elapsed)")
    }

    /// 逆方向: 予算内に終わる work はそのまま値を返す(fallback にすり替わらない)。
    /// 両方向を掛けないと、「常に fallback を返す」実装を上のテストが素通しする
    /// (CLAUDE.md「検知の類は両方向に掛ける」)
    func testBudgetedReturnsTheRealValueWhenWorkFinishesInTime() async {
        let result = await MCPServer.budgeted(.seconds(3), fallback: -1) { 99 }
        XCTAssertEqual(result, 99)
    }

    /// `udidBridgeDiagnosis` は上限超過時に既存の既定値(`UDIDBridgeDiagnosis.unknown` =
    /// 「診断が間に合わなかった」。listeningButUnresponsive 空・heldByRunPID nil・
    /// lookup は `.unreadable("diagnosis timed out")`)へ落ちることを、`budgeted` を直接使って
    /// 固定する(型を `UDIDBridgeDiagnosis` に揃えるだけで、`udidBridgeDiagnosis` 自身と同じ
    /// fallback を経路含めて確認する)
    func testBudgetedFallsBackToUDIDBridgeDiagnosisUnknownOnTimeout() async {
        let result = await MCPServer.budgeted(.milliseconds(150), fallback: .unknown) {
            () -> MCPServer.UDIDBridgeDiagnosis in
            Thread.sleep(forTimeInterval: 2)
            return .init(listeningButUnresponsive: [8130], heldByRunPID: 4242, lookup: .physical)
        }
        XCTAssertEqual(result, .unknown)
    }
}
