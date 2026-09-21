// dispatch.lock の待機チケット(FTRemote.DispatchTicket)を **親が1回だけ採って全ての子へ配る**
// 配線を固定する。
//
// 直す前の形: `FT_DISPATCH_TICKET` を読む側(RemoteDispatchQueue.resolveTicket)だけが居て、
// 書き出す親が居なかった。複数機械にまたがる run では子が機械ごとに別々の時刻を採るので、
// 同じ run の前後関係が機械によって食い違う —— 機械 A の待機列では自分が先・機械 B では相手が先、
// という形になり、2つの run が互いに相手の機械を待って `--wait-lock` の上限まで進まない。
//
// **この契約は型では守れない**(環境変数という型の効かない継ぎ目・親と子が別プロセス)ので、
// 純粋関数の等号とソース走査の両方で縛る。

import FTCore
import FTRemote
import Foundation
import XCTest
@testable import fleetest

final class DispatchTicketPlumbingTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// 親が子を起こす3経路(ここが「リモートへ出る子」を起こす全部)
    private static let fanoutSites = [
        "Sources/fleetest/ApiRunMachineFanout.swift",
        "Sources/fleetest/DeviceMachineRunner.swift",
        "Sources/fleetest/FleetRunner.swift",
    ]

    private let environment = ["FT_ISSUER": "tester"]  // 実設定ファイルを読ませない

    // MARK: - 値の受け渡し

    /// 子の環境にチケットが載ること。**FT_PARENT_PID も同時に載る**
    /// (ParentDeathWatchWiringTests が認める形の土台)
    func testChildEnvironmentCarriesTheTicketAndTheParentPID() {
        let ticket = DispatchTicketIssuer.issue(runGroup: "G1", environment: environment, pid: 4242,
                                                now: Date(timeIntervalSince1970: 1_700_000_000))
        let env = DispatchTicketIssuer.childEnvironment(ticket: ticket, base: [:])
        XCTAssertEqual(env[DispatchTicket.environmentKey], ticket.environmentValue)
        XCTAssertEqual(DispatchTicket.fromEnvironment(env), ticket)
        XCTAssertEqual(env[ParentDeathWatch.environmentKey], String(getpid()))
    }

    /// **同じ run の全ての子が同じ値を受け取る**(この変更の目的)。
    /// 併せて「採り直したら値が変わる」ことも示す —— これが成り立たなければ上の等号は
    /// 何も証明しない(常に同じ値を返す実装と区別が付かない)
    func testEveryChildOfOneRunGetsTheSameTicketWhileRetakingWouldDiffer() {
        let ticket = DispatchTicketIssuer.issue(runGroup: "G1", environment: environment, pid: 4242,
                                                now: Date(timeIntervalSince1970: 1_700_000_000))
        let machineEnvironments = ["local", "M1Max", "M1Ultra"].map { _ in
            DispatchTicketIssuer.childEnvironment(ticket: ticket, base: [:])
        }
        XCTAssertEqual(Set(machineEnvironments.compactMap { $0[DispatchTicket.environmentKey] }).count, 1,
                       "同じ run の子が別々のチケットを受け取っている(機械ごとに順番が食い違う)")

        // 子ごとに採り直す形(直す前の挙動)なら値は割れる
        let retaken = DispatchTicketIssuer.issue(runGroup: "G1", environment: environment, pid: 4242,
                                                 now: Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertNotEqual(retaken.environmentValue, ticket.environmentValue)
    }

    /// 親自身が誰かの子でチケットを継いでいれば、そのまま孫へ配る(採り直さない)
    func testInheritedTicketIsForwardedInsteadOfRetaken() {
        let inherited = DispatchTicket(requestedAtMillis: 1_699_999_000_000, issuer: "someone", group: "G0")
        let ticket = DispatchTicketIssuer.issue(
            runGroup: "G1",
            environment: environment.merging([DispatchTicket.environmentKey: inherited.environmentValue]) { _, new in new },
            pid: 4242, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(ticket, inherited)
    }

    /// runGroup の無い経路(`--fleet`)は pid が同時 run を区別する鍵になる
    func testRunGrouplessPathFallsBackToThePID() {
        let ticket = DispatchTicketIssuer.issue(runGroup: nil, environment: environment, pid: 4242,
                                                now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(ticket.group, "4242")
    }

    // MARK: - 配線(ソース走査)

    /// **チケットを採る場所は1箇所だけ**。`DispatchTicket.now` / `RemoteDispatchQueue.resolveTicket`
    /// を呼んでよいのは、発行の1箇所(DispatchTicketIssuer)と、実際に待機列へ並ぶ子の側
    /// (RemoteRunDispatcher)だけ —— 3つ目が増えると、そこだけ別の時刻で並ぶ
    func testOnlyTwoPlacesResolveATicket() throws {
        let dir = Self.repoRoot.appendingPathComponent("Sources/fleetest")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        var resolvers: [String] = []
        for name in files {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            if text.contains("RemoteDispatchQueue.resolveTicket(") || text.contains("DispatchTicket.now(") {
                resolvers.append(name)
            }
        }
        XCTAssertEqual(resolvers, ["DispatchTicketIssuer.swift", "RemoteRunDispatcher.swift"],
                       "チケットを採る場所が増減した(採る場所は発行の1箇所と待機列に並ぶ1箇所だけ)")
    }

    /// 親は **`withTaskGroup` の外で1回だけ** チケットを採る。子ごとの closure の中で採ると、
    /// 機械ごとに別の時刻になり、この配線の目的そのものが消える
    func testEachFanoutIssuesOnceBeforeLaunchingChildren() throws {
        for path in Self.fanoutSites {
            let text = try source(path)
            let occurrences = text.components(separatedBy: "DispatchTicketIssuer.issue(").count - 1
            XCTAssertEqual(occurrences, 1, "\(path): チケットの発行は run ごとに1回だけ")
            let issue = try XCTUnwrap(text.range(of: "DispatchTicketIssuer.issue("), path)
            let addTask = try XCTUnwrap(text.range(of: "addTask {"), "\(path): 子の起動が見つからない")
            XCTAssertLessThan(issue.lowerBound, addTask.lowerBound,
                              "\(path): チケットを子ごとの closure の中で採っている")
        }
    }

    /// 子を起こす2経路が、チケット入りの環境を渡していること(素の
    /// `ParentDeathWatch.childEnvironment()` へ戻すと、その経路の子だけが自分で採り直す)
    func testBothSpawnSitesPassTheTicketBearingEnvironment() throws {
        for path in ["Sources/fleetest/ApiRunMachineFanout.swift", "Sources/fleetest/FleetRunner.swift"] {
            let text = try source(path)
            XCTAssertTrue(
                text.contains("process.environment = DispatchTicketIssuer.childEnvironment(ticket: ticket)"),
                "\(path): 子の環境にチケットが入っていない")
        }
    }

    /// 発行側が `ParentDeathWatch.childEnvironment` を土台にしていること
    /// (`ParentDeathWatchWiringTests` が上の2経路でこの形を認める根拠)
    func testIssuerBuildsOnTheParentDeathWatchEnvironment() throws {
        let text = try source("Sources/fleetest/DispatchTicketIssuer.swift")
        XCTAssertTrue(text.contains("ParentDeathWatch.childEnvironment(base: base)"),
                      "土台が変わると FT_PARENT_PID が子へ届かなくなる(孤児が残る)")
    }
}
