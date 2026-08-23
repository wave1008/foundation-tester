// physicalUDID の配線漏れを防ぐソース走査。
//
// `BridgeClient` は physicalUDID を持つときだけ実機として振る舞う(installTarget()/
// simctlTarget()/simulatorTarget() の分岐)。**実機の CLI 引数(--physical/--udid)や
// プロファイルの device.physical が既にスコープに来ている構築箇所**でこれを渡し忘れると、
// 名前引きの simctl 経路へ誤って落ち、実機なのに「Invalid device: <名前>」という的外れな
// 失敗になる(2026-08-09 実測。ScenarioRunnerMain.swift の3箇所で実際に踏んだ)。
//
// 対象は「実機かどうかの情報を既に持っている」ファイルだけに絞る(MCP のポート直指定や
// --port 単体の CLI コマンドは physicalUDID を元々持たず、BridgeClient 内部の名前引き
// フォールバックに委ねる設計 —— そちらまで対象にすると意図的な設計を誤検知する)。
final class PhysicalUDIDPlumbingTests: FTBridgeClientSourceScanCase {

    /// 実機かどうかの情報(--physical/--udid・device.physical)が既にスコープに来ている
    /// ファイル。ここでの `BridgeClient(port: ...)` 構築は必ず physicalUDID を渡すこと
    private static let filesRequiringPhysicalUDID = [
        "Sources/FTScenarioRunner/ScenarioRunnerMain.swift",
        "Sources/FTAndroid/ProfileWorkerFactory.swift",
    ]

    func testEveryBridgeClientConstructionForwardsPhysicalUDID() throws {
        var checked = 0
        var offenders: [String] = []
        for relativePath in Self.filesRequiringPhysicalUDID {
            let source = try Self.readSource(relativePath)
            for range in Self.argumentRanges(in: source, callPrefix: "BridgeClient(port:") {
                checked += 1
                if !source[range].contains("physicalUDID") {
                    offenders.append("\(relativePath):\(Self.lineNumber(of: range.lowerBound, in: source))")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "走査対象が見つからない = パスかシグネチャの書式が変わった")
        XCTAssertTrue(offenders.isEmpty,
                      "BridgeClient(port: ...) の構築は physicalUDID: を渡すこと(渡さないと実機で"
                      + " 名前引きの simctl 経路へ誤って落ち、Invalid device の的外れな失敗になる): \(offenders)")
    }

    /// **シミュレータの UDID も同じく渡し切ること**(2026-08-19)。
    /// 渡さないと install/uninstall/clearAppData の対象特定が `status()` に落ち、
    /// **`removeApp()` の直後の `installApp()` が「接続拒否」で失敗する** ——
    /// アプリごと in-app ブリッジを消した後は「入れる先を教えてくれる相手」が居ない
    /// (受け手報告で実際に踏んだ。BridgeClient.knownTarget の宣言)。
    /// 対象は**ワーカーを組み立てるファイルだけ**: そこは device.udid が既にスコープに来ている。
    /// MCP のポート直指定や runner の駆動用クライアントは UDID を持たないので対象にしない
    /// (対象にすると意図的な設計を誤検知する)
    /// **シナリオ側も同じ**(2026-08-23): ホスト側(ProfileWorkerFactory)だけ直しても、
    /// DSL の removeApp が通るのはシナリオプロセスの InAppDriver が持つ client で、そこが
    /// UDID 無しだと前のシナリオがアプリを終了した直後の removeApp が同じ形で落ちる(受け手報告)
    func testWorkerBridgeClientsForwardTheSimulatorUDID() throws {
        var checked = 0
        var offenders: [String] = []
        for relativePath in ["Sources/FTAndroid/ProfileWorkerFactory.swift",
                             "Sources/FTScenarioRunner/ScenarioRunnerMain.swift",
                             "Sources/FTBridgeClient/InAppDriver.swift"] {
            let source = try Self.readSource(relativePath)
            for range in Self.argumentRanges(in: source, callPrefix: "BridgeClient(port:") {
                checked += 1
                if !source[range].contains("simulatorUDID") {
                    offenders.append("\(relativePath):\(Self.lineNumber(of: range.lowerBound, in: source))")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "走査対象が見つからない = パスかシグネチャの書式が変わった")
        XCTAssertTrue(offenders.isEmpty,
                      "ワーカーの BridgeClient(port: ...) は simulatorUDID: も渡すこと"
                      + "(渡さないと removeApp() の直後の installApp() が接続拒否で落ちる): \(offenders)")
    }

    /// **稼働ブリッジ → 端末の引き当ては共有規則を通すこと**(2026-08-14)。
    /// `scanRunningBridges` はここが名前引きだけだったため、udid を申告しない実機のブリッジが
    /// **生きていても端末に紐付かず**、planBridge の同一デバイス判定に一度も当たらないまま
    /// 2本目のランナーが立っていた(1台の実機に2本立てると両方死ぬ)。
    /// 純粋関数のテスト(BridgeDiscoveryTests)は規則の正しさしか見ないので、
    /// **呼んでいること・結果を使っていること**は別に要求する
    func testRunningBridgeIdentityGoesThroughTheSharedResolveUDID() throws {
        let source = try Self.readSource("Sources/FTBridgeClient/BridgeProvisioner.swift")
        let calls = Self.argumentRanges(in: source, callPrefix: "BridgeDiscovery.resolveUDID(")
        // **添字で取らない**: 0 件のときに続きの行がクラッシュし、失敗の分類が「アサート失敗」
        // ではなく「ビルド失敗」に化ける(変異テストの判定が濁る)
        guard calls.count == 1, let first = calls.first else {
            return XCTFail("scanRunningBridges は共有規則を1回だけ通すこと"
                           + "(見つかった数 \(calls.count)。0 = 名前引きへ戻った)")
        }
        let arguments = Self.collapsed(String(source[first]))
        XCTAssertTrue(arguments.contains("reported: status.udid"), arguments)
        XCTAssertTrue(arguments.contains("BridgeDeviceRecord.load(port: port"),
                      "実機は記録でしか特定できない: \(arguments)")
        XCTAssertTrue(arguments.contains("matchedByName:"), arguments)

        // 呼んだ結果を捨てていないこと(規則を通しても RunningBridge へ渡さなければ無意味)
        let built = Self.argumentRanges(in: source, callPrefix: "RunningBridge(udid:")
        guard built.count == 1, let construction = built.first else {
            return XCTFail("RunningBridge の構築箇所が \(built.count) 箇所 = この走査を見直すこと")
        }
        XCTAssertTrue(Self.collapsed(String(source[construction])).hasPrefix("udid: udid,"),
                      Self.collapsed(String(source[construction])))
    }
}

// MARK: - 共通ヘルパー(ソース走査系テストで使い回す)

import XCTest

class FTBridgeClientSourceScanCase: XCTestCase {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FTBridgeClientTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // リポジトリルート

    static func readSource(_ relativePath: String) throws -> String {
        let file = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    static func lineNumber(of index: String.Index, in source: String) -> Int {
        source[source.startIndex..<index].filter { $0 == "\n" }.count + 1
    }

    /// `callPrefix`(例 "BridgeClient(port:")で始まる呼び出しの引数リスト全体を返す。
    /// 丸カッコの対応を数えて取り出すため、複数行の呼び出しにもまたがる
    static func argumentRanges(in source: String, callPrefix: String) -> [Range<String.Index>] {
        // 末尾は "(" でも ":" でもよい。**"(" で切れる形を許す**のは、引数を改行で折り返した
        // 呼び出し(`foo(\n  bar: ...`)では最初のラベルまで含む prefix が原文に現れず、
        // 要求すると整形を検査することになるため(2026-08-14)
        precondition(callPrefix.contains("("))
        let callee = String(callPrefix[callPrefix.startIndex..<callPrefix.firstIndex(of: "(")!])
        var ranges: [Range<String.Index>] = []
        var searchStart = source.startIndex
        while let hit = source.range(of: callPrefix, range: searchStart..<source.endIndex) {
            let openParen = source.index(hit.lowerBound, offsetBy: callee.count)
            var depth = 0
            var index = openParen
            var closeParen: String.Index?
            while index < source.endIndex {
                let ch = source[index]
                if ch == "(" { depth += 1 } else if ch == ")" {
                    depth -= 1
                    if depth == 0 { closeParen = index; break }
                }
                index = source.index(after: index)
            }
            guard let close = closeParen else { break }
            ranges.append(source.index(after: openParen)..<close)
            searchStart = source.index(after: close)
        }
        return ranges
    }

    /// 走査の照合は**空白を潰してから**行う(2026-08-14 の教訓)。引数を改行で折り返しただけで
    /// 落ちる走査は、整形を検査しているのであって配線を検査していない
    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
