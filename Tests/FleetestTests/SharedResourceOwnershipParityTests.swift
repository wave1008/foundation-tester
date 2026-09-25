// 契約: 共有資源(ポート・ブリッジのツールチェーン・デバイス)を壊す操作は、撃つ前に持ち主を
// 確かめること(run-lease / MCP の印 / ownerUDID / BridgeToolchainLedger)。判定そのものは
// FTAndroid.DeviceBooter・FTBridgeClient.PortHolder・FTBridgeClient.BridgeToolchainLedger に
// 1箇所ずつあるが、新しい呼び手がそこを通さずに直接プリミティブ(simctl shutdown/erase・
// adb emu kill・BridgeLauncher.stop 系・PortHolder.stopIfOwnedBridge)を撃つ穴は、判定が
// 1箇所にあるだけでは機械的にしか塞げない(呼び手側の網羅は別に固定する必要がある)。
//
// **集合は破壊的プリミティブ側から機械的に導出する**(手書きの呼び出し一覧を固定しない) ——
// Sources/ 全体をプリミティブの文字列で走査し、ヒットした関数がゲート語彙を自分の本体に
// 持つかを見る。**新しい無防備な呼び出しを足すと落ちる**。免除は Set<String> で理由つきに
// 固定し、免除できるのは次の3種類だけ:
//   ①この run/セッション自身が今使っている(=既に持ち主である)資源の後始末
//   ②呼び出し元が既にゲートを通した後にだけ呼ぶ内側のヘルパー(関数分割の内側)
//   ③供給(provision)・ライブ操作の自動起動経路の内部処理
//     (門は CLI の口にだけ置く。あちらに足すと run/ライブ操作自体が使えなくなる)

import Foundation
import XCTest

final class SharedResourceOwnershipParityTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func sourcesRoot() -> URL {
        repoRoot().appendingPathComponent("Sources")
    }

    /// Sources/ 配下の .swift を再帰的に集める(手書きの一覧を持たない)
    private func allSwiftFiles() throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourcesRoot(), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else {
            XCTFail("Sources/ が読めていない — テストを見直すこと")
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result
    }

    /// **コメントを落としてから走査する**(LiveControlExitParityTests と同じ流儀) ——
    /// プリミティブ名・ゲート語彙とも doc コメントに書かれることがあるので、素のまま検索すると
    /// 配線を消してもコメントだけで通ってしまう
    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") ? "" : $0 }
            .joined(separator: "\n")
    }

    private func regexMatches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - 関数単位の抽出(KillCallSiteOwnershipGuardTests と同じ簡易パーサ)

    private struct FunctionBody {
        let name: String
        let text: String
    }

    /// ソースを「func」単位へ大まかに分割する。波括弧のネストを数えて本体の終端を決める
    /// (この走査対象ファイル群には波括弧を含む文字列リテラルが無いことを実地確認済み。
    /// 増えたら見直す)。name は "<ファイル名>.<関数名>"(KillCallSiteOwnershipGuardTests と同じ命名)
    private func functions(in source: String, file: String) -> [FunctionBody] {
        var results: [FunctionBody] = []
        let pattern = try! NSRegularExpression(pattern: #"func\s+(\w+)\s*\("#)
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches {
            guard let matchRange = Range(match.range, in: source),
                  let nameRange = Range(match.range(at: 1), in: source) else { continue }
            let name = String(source[nameRange])
            guard let braceStart = source.range(of: "{", range: matchRange.upperBound..<source.endIndex)
            else { continue }
            var depth = 0
            var idx = braceStart.lowerBound
            var end = source.endIndex
            while idx < source.endIndex {
                let ch = source[idx]
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        end = source.index(after: idx)
                        break
                    }
                }
                idx = source.index(after: idx)
            }
            results.append(FunctionBody(name: "\(file).\(name)", text: String(source[braceStart.lowerBound..<end])))
        }
        return results
    }

    // MARK: - 資源③ デバイス(simctl shutdown/erase・adb emu kill・BridgeLauncher.stop 系)

    /// これを直接撃つ関数は、run-lease / MCP の印の判定を自分の本体に持つか、それを内包する
    /// 既にゲート済みのラッパ(DeviceBooter.shutdownOne/shutdownAll)を呼ぶこと
    private static let devicePrimitivePatterns = [
        #""simctl",\s*"shutdown""#,
        #""simctl",\s*"erase""#,
        #""emu",\s*"kill""#,
        #"EmulatorControl\.shutdown\("#,
        #"BridgeLauncher\.stopAll\("#,
        #"BridgeLauncher\.stopMatching\("#,
        #"\blauncher\.stop\(\)"#,
        #"\blauncher\.stopAndWait\("#,
    ]

    private static let deviceGateMarkers = [
        "deviceInUseRefusal(", "sweepRefusal(", "stopRefusal(", "mcpStopRefusal(",
        "BridgeDownRefusal.decide(", "BridgeDownRefusal.unresponsiveButBoundRefusal(",
        "DeviceBooter.shutdownOne(", "DeviceBooter.shutdownAll(",
    ]

    /// 免除(理由つき)。**足すときは、なぜここが持ち主判定を持たなくてよいかを書くこと**
    private static let deviceGateExemptions: Set<String> = [
        // ③ライブ操作の自動起動・建て直し。対象は呼び出し元(ライブ操作のセッション)が指した
        // その1台だけで、他プロセスの持ち物を横取りしない
        "LiveBridgeAutoStarter.launchBridge",
        // ③供給(provision)経路の内部処理。今まさに供給しようとしているその1台のブリッジを
        // 建て直すだけ。ここに lease 判定を足すと run 自体が建てられなくなる
        // (docs/remote-runner.md §18.7「門は CLI の口にだけ置く」)
        "XCUIBridgeResolver.start",
        "BridgeProvisioner.restartRunner",
        "BridgeProvisioner.restartSimulatorAndRunner",
        "BridgeProvisioner.executeBridge",
        "BridgeProvisioner.stopAndRelaunch",
        // ①この run 自身が今使っている凍結ワーカーの自己回復(BlankWorkerTriage.recover)。
        // 他プロセスの台は触らない
        "ProfileWorkerFactory.recoverFrozenIOSWorkers",
        // ②呼び出し元 DeviceWiper.wipeOne(android) が deviceInUseRefusal を通した後にだけ呼ぶ
        // 実体部分(関数分割の内側。単体では判定語彙が現れない)
        "AndroidDataWiper.stopIfRunning",
        // ①cleanupRetiredWorker クロージャがこの run 自身の離脱済みワーカーを後始末するだけ
        // (他プロセスの持ち物ではない)。ProfileRunOrchestrator.make は多数のクロージャを
        // 組み立てる工場関数なので、この1つのクロージャのために関数全体が免除に載る
        "ProfileRunOrchestrator.make",
    ]

    /// **戻すと落ちる根拠**: 新しい停止経路が run-lease / MCP の印のどちらも確認せずに
    /// simctl shutdown/erase・adb emu kill・BridgeLauncher.stop 系を撃つと、他プロセス
    /// (走っている run・MCP セッション)の台を無言で落とす
    func testEveryDeviceStopPrimitiveIsGuardedByAnOwnershipCheck() throws {
        var sawAnyHit = false
        for url in try allSwiftFiles() {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let source = codeOnly(raw)
            guard Self.devicePrimitivePatterns.contains(where: { regexMatches($0, in: source) }) else { continue }
            let file = url.deletingPathExtension().lastPathComponent
            for function in functions(in: source, file: file) {
                let hitPatterns = Self.devicePrimitivePatterns.filter { regexMatches($0, in: function.text) }
                guard !hitPatterns.isEmpty else { continue }
                sawAnyHit = true
                guard !Self.deviceGateExemptions.contains(function.name) else { continue }
                let hasGate = Self.deviceGateMarkers.contains { function.text.contains($0) }
                XCTAssertTrue(hasGate, """
                    \(function.name) がデバイス破壊系プリミティブ(\(hitPatterns.joined(separator: "/")))を \
                    呼ぶが、持ち主判定の語彙(\(Self.deviceGateMarkers.joined(separator: "/")))が見当たらない。\
                    run-lease / MCP の印を確認する DeviceBooter.deviceInUseRefusal 系を通すか、\
                    確認済みの内側ヘルパーであれば deviceGateExemptions へ理由つきで追加すること。
                    """)
            }
        }
        XCTAssertTrue(sawAnyHit, "デバイス破壊系プリミティブを1件も見つけていない — 走査が壊れている")
    }

    // MARK: - 資源① ポート(PortHolder.stopIfOwnedBridge)

    /// 呼び出しの引数の丸括弧を対応づけて取り出す(NSRegularExpression の後、括弧の深さを
    /// 手で数える。ネストした呼び出し(例: stateDir.appendingPathComponent(...))があっても崩れない)
    private func callArguments(after openParenIndex: String.Index, in source: String) -> String {
        var depth = 1
        var idx = openParenIndex
        while idx < source.endIndex {
            let ch = source[idx]
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 { return String(source[openParenIndex..<idx]) }
            }
            idx = source.index(after: idx)
        }
        return String(source[openParenIndex...])
    }

    /// **戻すと落ちる根拠**: `ownerUDID:` を渡さなければ常に `.foreign`(安全側)へ倒れるが、
    /// 渡さずに呼ぶこと自体が「ポートだけで自分の残骸と決める」型の再発の芽。
    /// PortHolder.swift の doc「ownerUDID: を必ず渡す」の唯一の外形的チェック
    func testEveryStopIfOwnedBridgeCallPassesOwnerUDIDExplicitly() throws {
        let marker = "PortHolder.stopIfOwnedBridge("
        var callSites = 0
        for url in try allSwiftFiles() {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let source = codeOnly(raw)
            var searchStart = source.startIndex
            while let range = source.range(of: marker, range: searchStart..<source.endIndex) {
                callSites += 1
                let args = callArguments(after: range.upperBound, in: source)
                XCTAssertTrue(args.contains("ownerUDID:"), """
                    \(url.lastPathComponent) の PortHolder.stopIfOwnedBridge( 呼び出しが \
                    ownerUDID: を渡していない — 渡さなければ常に .foreign(安全側)に倒れるが、\
                    対象デバイスを分かっているなら明示すること(bridge-provision.md \
                    「ownerUDID: を必ず渡す」)。
                    """)
                searchStart = range.upperBound
            }
        }
        XCTAssertGreaterThan(callSites, 0, "PortHolder.stopIfOwnedBridge の呼び出しを1件も見つけていない — 走査が壊れている")
    }

    // MARK: - 資源② ブリッジのツールチェーン(BridgeToolchainLedger)

    /// **戻すと落ちる根拠**: 建て直しの判定(BridgeToolchainLedger.decide)が走るのは
    /// 「建てるとき」だけなので、生きたブリッジを**引き取る**(.adopt)側で別途確認しないと、
    /// 版の違うブリッジを黙って引き取り続ける(bridge-provision.md「.reuse と .adopt の両方で見る」)。
    ///
    /// **`decide(` と `matchesCurrent(` の同居では固定できない** —— `.reuse` 側は
    /// `decide(toolchainMatches: matchesCurrent(...))` の形で引数として `matchesCurrent` を含むので、
    /// 引き取り側の呼び出しを消しても同居の条件は満たされたままになる。そこで
    /// **`toolchainMatches:` の引数ではない `matchesCurrent(` が1つ以上ある**ことを別に要求する。
    func testReuseAndAdoptBothConsultTheToolchainLedger() throws {
        let file = "Sources/FTBridgeClient/BridgeProvisioner.swift"
        let url = repoRoot().appendingPathComponent(file)
        let source = codeOnly(try String(contentsOf: url, encoding: .utf8))
        guard source.contains("BridgeToolchainLedger.decide(") else {
            XCTFail("BridgeToolchainLedger.decide の呼び出しが見当たらない — 走査が壊れている")
            return
        }
        // decide( を本体に含む「最も狭い」関数を選ぶ(ネストした関数があれば外側も同じ文字列を
        // 含んでしまうため、テキストが最短のものを取る)
        let functionList = functions(in: source, file: "BridgeProvisioner")
            .filter { $0.text.contains("BridgeToolchainLedger.decide(") }
        guard let owner = functionList.min(by: { $0.text.count < $1.text.count }) else {
            XCTFail("BridgeToolchainLedger.decide を囲む関数が見つからない — 走査を見直すこと")
            return
        }
        let marker = "BridgeToolchainLedger.matchesCurrent("
        let total = owner.text.components(separatedBy: marker).count - 1
        let asDecideArgument = owner.text
            .components(separatedBy: "toolchainMatches: " + marker).count - 1
        let standalone = total - asDecideArgument
        XCTAssertGreaterThan(standalone, 0, """
            \(owner.name): 引き取り(.adopt)側の BridgeToolchainLedger.matchesCurrent 呼び出しが無い \
            (見つかった \(total) 件はすべて decide の toolchainMatches: 引数)。建て直しの判定は \
            「建てるとき」しか走らないので、生きたブリッジを引き取る経路で確認しないと版の \
            違うブリッジを黙って駆動し続ける。
            """)
    }
}
