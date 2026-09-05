// 親プロセスの死を検知して自分も終わる ParentDeathWatch(Sources/FTCore/ParentDeathWatch.swift)。
// kqueue(EVFILT_PROC/NOTE_EXIT)を使う経路と、既に死んでいる pid への即応を両方確かめる。

import XCTest
@testable import FTCore

final class ParentDeathWatchTests: XCTestCase {

    func testOnExitFiresWhenTheWatchedProcessExits() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let expectation = expectation(description: "onExit fires after the watched process exits")
        ParentDeathWatch.arm(parentPID: process.processIdentifier) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        process.waitUntilExit()
    }

    func testOnExitFiresImmediatelyForAnAlreadyDeadPID() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        let expectation = expectation(description: "onExit fires immediately for a dead pid")
        ParentDeathWatch.arm(parentPID: process.processIdentifier) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    /// 差し替え口(onExit)が無いので、例外を出さず戻ることだけ確かめる
    func testArmIfRequestedWithoutTheEnvironmentKeyDoesNothing() {
        ParentDeathWatch.armIfRequested(environment: [:])
    }

    func testChildEnvironmentCarriesTheOwnPID() {
        let env = ParentDeathWatch.childEnvironment(base: [:])
        XCTAssertEqual(env[ParentDeathWatch.environmentKey], String(getpid()))
    }
}
