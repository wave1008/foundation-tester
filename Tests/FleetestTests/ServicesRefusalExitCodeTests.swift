// `services` の状態による拒否を ValidationError(終了コード 64・「--help を見よ」)で投げない。
// 2026-10-15 の負荷テスト: run の最中の `services reset --force` が正しく断ったのに、使い方の誤りとして
// 「See 'fleetest services reset --help'」を付けて 64 で終わっていた。

import XCTest
import ArgumentParser
@testable import fleetest

extension ServicesResetDecisionTests {

    private func refusalSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 残してよい ValidationError は引数の誤りだけ(等号で固定 = 新しい拒否を ValidationError で足すと落ちる)
    func testOnlyArgumentErrorsUseValidationError() throws {
        for (file, allowed) in [
            ("Sources/fleetest/ServicesCommand.swift", ["--profile is required", "does not exist"]),
            ("Sources/fleetest/ServicesOwnerLaunch.swift", []),
        ] {
            let throwing = try refusalSource(file).components(separatedBy: "\n")
                .filter { $0.contains("throw ValidationError(") }
            XCTAssertEqual(throwing.count, allowed.count, "\(file): \(throwing)")
            for fragment in allowed {
                XCTAssertTrue(throwing.contains { $0.contains(fragment) }, "\(file): \(fragment)")
            }
        }
    }

    /// 拒否は文言だけを出す(ArgumentParser は LocalizedError を「Error: <文言>」・終了コード 1 で出す)
    func testRefusalCarriesOnlyItsMessage() {
        let refusal = ServicesRefused("run pid 1 holds these services")
        XCTAssertEqual(refusal.localizedDescription, "run pid 1 holds these services")
        XCTAssertEqual(ServicesCommand.exitCode(for: refusal).rawValue, 1)
        XCTAssertEqual(ServicesCommand.exitCode(for: ValidationError("x")).rawValue, 64)
    }
}
