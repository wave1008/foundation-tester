// run() の中で投げた ValidationError は、ルートの Usage ではなくそのサブコマンドの help を名指しする
// (`Fleetest.main`)。名指しの元になる `commandPath(of:)` と、実バイナリの出力の両方を縛る。

import XCTest
@testable import fleetest

final class RunTimeValidationUsageTests: XCTestCase {

    func testCommandPathNamesNestedSubcommands() {
        XCTAssertEqual(Fleetest.commandPath(of: ResultsListCommand.self), "results list")
        XCTAssertEqual(Fleetest.commandPath(of: RemoteCommand.Status.self), "remote status")
        XCTAssertEqual(Fleetest.commandPath(of: Fleetest.self), "")
    }

    /// **実バイナリ**: 値の検証が run() の中にある `results list --since 0d` が、そのサブコマンドへ案内する
    func testARunTimeValidationErrorPointsAtTheSubcommandHelp() throws {
        let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/fleetest")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("fleetest の実バイナリが無い(swift build --product fleetest の後に回る)")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["results", "list", "--since", "0d"]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: stderr.fileHandleForReading.availableData, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 64, text)
        XCTAssertTrue(text.contains("See 'fleetest results list --help'"), text)
        XCTAssertFalse(text.contains("fleetest <subcommand>"), text)
    }
}
