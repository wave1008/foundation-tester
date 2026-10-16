import ArgumentParser
import Foundation
import FTCore
import XCTest
@testable import fleetest

final class FMAlignBuildCommandTests: XCTestCase {
    func testBuildOptionRequiresTargetAndPreservesTheShellCommand() throws {
        XCTAssertThrowsError(try ApiFMAlignCommand.parse(["--build-command", "exit 0"]))
        let shell = "printf '%s' 'literal $variable and spaces'; exit 0"
        let command = try ApiFMAlignCommand.parse(["--target-executable", "/tmp/runner clone/.build/debug/fleetest",
                                                  "--build-command", shell])
        XCTAssertNoThrow(try command.validate())
        XCTAssertEqual(command.targetExecutable, "/tmp/runner clone/.build/debug/fleetest")
        XCTAssertEqual(command.buildCommand, shell)
        XCTAssertNotNil(ApiFMAlignCommand.buildOperation(command: command.buildCommand))
        XCTAssertNil(ApiFMAlignCommand.buildOperation(command: nil))
    }

    func testBuildOperationRunsTheRealShellAndPropagatesNonzeroExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fm-align-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("build output.txt")
        let success = try XCTUnwrap(ApiFMAlignCommand.buildOperation(
            command: "printf '%s' 'literal $variable and spaces' > '\(output.path)'"))
        try await success()
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "literal $variable and spaces")
        let failure = try XCTUnwrap(ApiFMAlignCommand.buildOperation(command: "exit 23"))
        do {
            try await failure()
            XCTFail("a failed build was reported as successful")
        } catch let error as ApiFMAlignCommand.BuildFailure {
            XCTAssertEqual(error.status, 23)
        }
    }

    func testCancellationLetsTheBuildRunItsTerminationCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fm-align-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        let finished = directory.appendingPathComponent("finished")
        let command = "trap 'printf done > \"\(finished.path)\"; exit 0' TERM; "
            + "printf '%s' $$ > '\(started.path)'; while :; do sleep 0.05; done"
        let operation = Task { try await ApiFMAlignCommand.runBuildCommand(command) }
        let startDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: started.path), Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: started, encoding: .utf8)))
        operation.cancel()
        let finishDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: finished.path), Date() < finishDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let cleanedUp = FileManager.default.fileExists(atPath: finished.path)
        // 変異で中断の配線が消えても、試験用の子を残さずアサーションで落とす。
        if !cleanedUp { killpg(pid, SIGTERM) }
        do { try await operation.value; XCTFail("a cancelled build was reported as successful") }
        catch is CancellationError {}
        XCTAssertTrue(cleanedUp, "the build never received termination or its cleanup was interrupted")
        XCTAssertEqual(try String(contentsOf: finished, encoding: .utf8), "done")
    }
}
