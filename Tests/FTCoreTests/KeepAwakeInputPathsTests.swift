// KeepAwake が「最後の入力からの経過」を数える基準(BridgeRouter.inputPaths)の取りこぼしを
// ソース走査で落とす。**操作エンドポイントを足して inputPaths に載せ忘れると、
// その操作だけでテストが進む間に端末が寝る**(自動ロック 30 秒の実機)。逆に問い合わせを
// 入れてしまうと、木のポーリング中は撃たれず同じく寝る。どちらもデバイス実行でしか
// 顕在化しないので、POST ルートの全部がどちらかに分類されていることをここで固定する。

import XCTest

final class KeepAwakeInputPathsTests: XCTestCase {

    private var routerSource: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // FTCoreTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // リポジトリルート
            return try String(
                contentsOf: root.appendingPathComponent(
                    "Runner/FleetestRunnerUITests/BridgeRouter.swift"), encoding: .utf8)
        }
    }

    /// `case ("POST", "/x")` の x を全部拾う
    private func postRoutes(in source: String) -> Set<String> {
        var routes: Set<String> = []
        let pattern = #"case \("POST", "([^"]+)"\)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        for match in regex.matches(in: source, range: range) {
            guard let r = Range(match.range(at: 1), in: source) else { continue }
            routes.insert(String(source[r]))
        }
        return routes
    }

    /// `private static let <name>: Set<String> = [...]` の中身
    private func literalSet(named name: String, in source: String) -> Set<String> {
        guard let start = source.range(of: "let \(name): Set<String> = ["),
              let end = source.range(of: "]", range: start.upperBound..<source.endIndex) else {
            return []
        }
        let body = source[start.upperBound..<end.lowerBound]
        return Set(body.split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"")) }.filter { !$0.isEmpty })
    }

    /// KeepAwake が読む環境変数が、ホストから xctestrun へ**全部**渡っていること。
    /// 渡し忘れてもコンパイルも実行も通り、**ノブが黙って効かないだけ**になる
    /// (実際 FT_KEEP_AWAKE_PULSE が抜けていた)
    func testEveryKeepAwakeEnvKeyIsForwarded() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let keepAwake = try String(
            contentsOf: root.appendingPathComponent(
                "Runner/FleetestRunnerUITests/KeepAwake.swift"), encoding: .utf8)
        // ホストが渡す鍵の一覧は KeepAwakePolicy が唯一の定義元(BridgeLauncher はそれを回す)
        let policy = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/FTCore/KeepAwakePolicy.swift"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"environment\["(FT_[A-Z_]+)"\]"#)
        let range = NSRange(keepAwake.startIndex..., in: keepAwake)
        var keys: Set<String> = []
        for match in regex.matches(in: keepAwake, range: range) {
            guard let r = Range(match.range(at: 1), in: keepAwake) else { continue }
            keys.insert(String(keepAwake[r]))
        }
        XCTAssertFalse(keys.isEmpty, "KeepAwake が読む環境変数を1つも拾えていない(走査が壊れた)")
        for key in keys.sorted() {
            XCTAssertTrue(policy.contains("\"\(key)\""),
                          "\(key) が KeepAwakePolicy に載っていない = xctestrun へ渡らない"
                          + "(ランナーは既定値のまま動き、ノブが黙って効かない)")
        }
    }

    func testEveryPostRouteIsClassified() throws {
        let source = try routerSource
        let routes = postRoutes(in: source)
        XCTAssertGreaterThan(routes.count, 10, "POST ルートを1つも拾えていない(走査が壊れた)")
        let input = literalSet(named: "inputPaths", in: source)
        let nonInput = literalSet(named: "nonInputPaths", in: source)
        XCTAssertTrue(input.isDisjoint(with: nonInput),
                      "両方に載っている: \(input.intersection(nonInput).sorted())")
        let unclassified = routes.subtracting(input).subtracting(nonInput)
        XCTAssertTrue(unclassified.isEmpty,
                      "BridgeRouter の POST ルートが KeepAwake の分類から漏れている: "
                      + "\(unclassified.sorted())。HID を伴うなら inputPaths、"
                      + "問い合わせなら nonInputPaths へ載せること")
        let stale = input.union(nonInput).subtracting(routes)
        XCTAssertTrue(stale.isEmpty, "存在しないルートが載っている: \(stale.sorted())")
    }
}
