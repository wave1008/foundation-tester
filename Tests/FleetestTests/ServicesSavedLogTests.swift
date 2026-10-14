import FTCore
import Foundation
import XCTest
@testable import fleetest

/// 失敗時に残すサービスログ(`results/runs/<月>/<runID>/services/<service>.log`)は ConsoleOut を通らないので、
/// 書く側が伏せ字を通す。登録簿はテスト専用のインスタンス(`shared` はプロセス大域で並列のテストに漏れる)
final class ServicesSavedLogTests: XCTestCase {
    func testSavedServiceLogMasksRegisteredSecrets() throws {
        let redactor = SecretRedactor()
        redactor.register("hunter2-pass")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-services-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        try ServicesSession.writeServiceLog("db ready\nPOSTGRES_PASSWORD=hunter2-pass\nlistening", to: file, redactor: redactor)
        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(written.contains("hunter2-pass"))
        XCTAssertEqual(written, "db ready\nPOSTGRES_PASSWORD=***\nlistening")
    }
}
