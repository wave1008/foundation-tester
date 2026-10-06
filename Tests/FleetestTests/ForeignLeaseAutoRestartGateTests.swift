// 契約: ランナー・ブリッジを**自動で**起動し直す/作り直す経路は、撃つ前に「他のセッション(run・MCP)が
// そのデバイスを使っていないか」を見る(RunnerAccessibilityHealth.hasForeignLease*)。2026-10-06 の負荷テストで
// MCP の自動回復が run の引き取ったシミュレータのランナーを起動し直し、run のレーンが脱落した。同じ型の経路を
// ここで1つずつ固定する(門が破壊的な呼び出しより**前**にあること)。経路そのものはデバイスを要求するので
// ソース走査で縛る(BridgeRecoveryWiringTests / RunnerSlownessProvisioningWiringTests と同じ規律)。

import Foundation
import XCTest

final class ForeignLeaseAutoRestartGateTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let raw = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        // コメントを落とす(門の名前がコメントにだけ残っても通らないように)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") ? "" : String($0) }
            .joined(separator: "\n")
    }

    /// `func <name>(` から波括弧の対応で本体の終わりまで
    private func body(of name: String, in text: String) -> String? {
        guard let start = text.range(of: "func \(name)("),
              let brace = text.range(of: "{", range: start.upperBound..<text.endIndex) else { return nil }
        var depth = 0
        var index = brace.lowerBound
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[start.lowerBound...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// gate は `if` の直後に置かれていること(`if false, <門>` のように前置の条件で素通りにできない形)。
    /// 比較は空白・改行を落として行う
    private func assertGate(_ gate: String, precedes targets: [String], inFunction name: String,
                            file: String, line: UInt = #line) throws {
        guard let raw = body(of: name, in: try source(file)) else {
            return XCTFail("\(file) に func \(name) が見当たらない — テストを見直すこと", line: line)
        }
        let body = compact(raw)
        guard let gateRange = body.range(of: "if" + compact(gate)) else {
            return XCTFail("\(name) が他のセッションの印(\(gate))を見ていない", line: line)
        }
        for target in targets {
            guard let targetRange = body.range(of: compact(target)) else {
                return XCTFail("\(name) に \(target) が見当たらない — テストを見直すこと", line: line)
            }
            XCTAssertTrue(gateRange.lowerBound < targetRange.lowerBound,
                          "\(name): \(gate) が \(target) より後にある(撃ってから確かめている)", line: line)
        }
    }

    /// run 自身のレーンと MCP の測り直しが共有する起動し直し(run は引き取ったデバイスでも起動し直す版)
    func testRecheckRunnerChecksBeforeRestarting() throws {
        try assertGate("RunnerAccessibilityHealth.hasForeignLeaseUnlessOwnRun(key: udid, stateDir: fleetestStateDir)",
                       precedes: ["await provisionLock.acquire()", "try await restartRunner("],
                       inFunction: "recheckRunner", file: "Sources/FTBridgeClient/BridgeProvisioner.swift")
    }

    /// ライブ操作の自動起動(接続拒否から・旧ビルドの起動し直しの両方が通る)。門はロックの前(断るだけのために
    /// run の供給のロックを待たない)
    func testLiveAutoStartChecksBeforeStoppingOrStarting() throws {
        try assertGate("RunnerAccessibilityHealth.hasForeignLease(",
                       precedes: ["await provisionLock?.acquire()", "try await launcher.stopAndWait()",
                                  "try launcher.startDetached()"],
                       inFunction: "launchBridge", file: "Sources/fleetest/LiveBridgeAutoStarter.swift")
    }

    /// 「使用中」で断った回は連続失敗に数えない(数えると failed に固定され、相手が終わっても戻らない)
    func testLiveAutoStartDoesNotCountAnInUseRefusalAsAFailure() throws {
        guard let body = body(of: "finishLaunch", in: try source("Sources/fleetest/LiveBridgeAutoStarter.swift")),
              let skip = body.range(of: "case .failure(AutoStarterError.deviceHeldByAnotherSession(let detail)):"),
              let count = body.range(of: "consecutiveFailures += 1") else {
            return XCTFail("finishLaunch の分岐が見当たらない — テストを見直すこと")
        }
        XCTAssertTrue(skip.lowerBound < count.lowerBound,
                      "使用中の断りが、連続失敗を数える汎用の failure 分岐より後にある(先に拾われない)")
    }

    /// MCP / 探索の in-app 解決からの XCUITest 自動起動
    func testInAppResolverAutoStartChecksBeforeStarting() throws {
        try assertGate("RunnerAccessibilityHealth.hasForeignLease(",
                       precedes: ["PortHolder.stopIfOwnedBridge(", "startDetached"],
                       inFunction: "start", file: "Sources/FTBridgeClient/XCUIBridgeResolver.swift")
    }

    /// **Android の「使用中」は到達不能として包まない・キャッシュしない**(包むと「`fleetest bridge up` を試せ」が
    /// 付くが、その bridge up も同じ門で断られる)。ensureBridge の両方の catch で汎用の分岐より先に拾うこと
    func testAndroidInUseRefusalIsNotWrappedAsUnreachable() throws {
        let file = try source("Sources/FTAndroid/AndroidBridge.swift")
        guard let ensureRaw = body(of: "ensureBridge", in: file),
              let startRaw = body(of: "startBridge", in: file) else {
            return XCTFail("ensureBridge / startBridge が見当たらない — テストを見直すこと")
        }
        let ensure = compact(ensureRaw)
        let heldRanges = ensure.ranges(of: "catchletheldasAndroidBridgeHeldByAnotherSession{")
        XCTAssertEqual(heldRanges.count, 2, "setup の catch と外側の catch の両方で拾うこと")
        guard let first = heldRanges.first, let last = heldRanges.last,
              let cache = ensure.range(of: "Self.setRegistry(key,.unavailable("),
              let wrap = ensure.range(of: "throwSelf.unreachableError(detail:Self.rawFailureDetail(error)") else {
            return XCTFail("ensureBridge の汎用の分岐が見当たらない — テストを見直すこと")
        }
        XCTAssertTrue(first.lowerBound < cache.lowerBound, "キャッシュする汎用の catch より後で拾っている")
        XCTAssertTrue(last.lowerBound < wrap.lowerBound, "到達不能で包む汎用の catch より後で拾っている")
        XCTAssertTrue(compact(startRaw).contains("throwAndroidBridgeHeldByAnotherSession(serial:serial)"),
                      "startBridge が使用中を専用の型で投げていない")
    }

    /// Android ブリッジの作り直し(force-stop + instrument)。呼び手が run(とその子)なら MCP から引き取った
    /// デバイスでも立て直す版を使う
    func testAndroidBridgeRestartChecksBeforeForceStopping() throws {
        try assertGate("let serial, let stateDir = (try? RepoRoot.find())?.appendingPathComponent(\".fleetest\"),"
                           + " RunnerAccessibilityHealth.hasForeignLeaseUnlessOwnRun(",
                       precedes: ["try installBridgeIfNeeded()", "\"force-stop\", Self.bridgePackage"],
                       inFunction: "startBridge", file: "Sources/FTAndroid/AndroidBridge.swift")
    }
}
