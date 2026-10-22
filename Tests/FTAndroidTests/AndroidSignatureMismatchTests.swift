// 署名違い(INSTALL_FAILED_UPDATE_INCOMPATIBLE)の扱い: 消してよい事実が揃ったときだけ入れ直し、
// 不明は「消さない」へ倒す。拒否のときに uninstall を撃たないことを偽 adb の記録で固定する

import XCTest
@testable import FTAndroid

final class AndroidSignatureMismatchTests: XCTestCase {
    func testActionTable() {
        typealias A = AndroidSignatureMismatch
        XCTAssertEqual(A.action(isEmulator: true, installedDebuggable: false), .reinstall(reason: "an Emulator"))
        XCTAssertEqual(A.action(isEmulator: true, installedDebuggable: nil), .reinstall(reason: "an Emulator"))
        XCTAssertEqual(A.action(isEmulator: false, installedDebuggable: true), .reinstall(reason: "a debuggable build"))
        XCTAssertEqual(A.action(isEmulator: nil, installedDebuggable: true), .reinstall(reason: "a debuggable build"))
        XCTAssertEqual(A.action(isEmulator: false, installedDebuggable: false), .refuse(unknown: false))
        XCTAssertEqual(A.action(isEmulator: false, installedDebuggable: nil), .refuse(unknown: true))
        XCTAssertEqual(A.action(isEmulator: nil, installedDebuggable: false), .refuse(unknown: true))
        XCTAssertEqual(A.action(isEmulator: nil, installedDebuggable: nil), .refuse(unknown: true))
    }

    func testDebuggableParsing() {
        let marker = "--ft-debuggable--"
        let debuggable = "0\n\(marker)\n    privateFlags=[ PRIVATE_FLAG_ACTIVITIES_RESIZE_MODE_RESIZEABLE ]\n"
            + "    flags=[ DEBUGGABLE HAS_CODE ALLOW_CLEAR_USER_DATA ]\n"
        let release = "0\n\(marker)\n    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]\n"
        XCTAssertEqual(AndroidSignatureMismatch.installedDebuggable(probeOutput: debuggable, status: 0), true)
        XCTAssertEqual(AndroidSignatureMismatch.installedDebuggable(probeOutput: release, status: 0), false)
        XCTAssertNil(AndroidSignatureMismatch.installedDebuggable(probeOutput: "0\n\(marker)\n", status: 0))
        XCTAssertNil(AndroidSignatureMismatch.installedDebuggable(probeOutput: "", status: 0))
        XCTAssertNil(AndroidSignatureMismatch.installedDebuggable(probeOutput: debuggable, status: 1))
    }

    func testRefusalMessageNamesTheUninstallCommand() {
        let message = AndroidSignatureMismatch.refusalMessage(serial: "ABC123", package: "com.example.app", unknown: false)
        XCTAssertTrue(message.contains("`adb -s ABC123 uninstall com.example.app`"), message)
        XCTAssertTrue(message.contains("not a debuggable build"), message)
        XCTAssertTrue(AndroidSignatureMismatch.refusalMessage(serial: "x", package: "a.b", unknown: true)
            .contains("could not tell"))
    }

    // MARK: - 偽 adb で install を通す

    private var dir: URL!
    private var serial: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-sigmm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        if let serial {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
                .appendingPathComponent("fleetest-android-\(serial).json"))
        }
    }

    /// 1回目の install -r は署名違いで落ち、debuggable プローブは `flagsLine` を返す。
    /// 呼ばれた引数を `calls` へ1行ずつ残す
    private func makeDriver(serial: String, flagsLine: String, uninstallSucceeds: Bool = true,
                            secondInstallSucceeds: Bool = true,
                            installFailure: String = "INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.example.app signatures do not match newer version; ignoring!") throws -> (AndroidDriver, URL) {
        self.serial = serial
        let calls = dir.appendingPathComponent("calls.txt")
        let script = """
        #!/bin/sh
        echo "$*" >> "\(calls.path)"
        case "$3" in
          shell)
            case "$4" in
              true) exit 0;;
              getprop*) echo 0; echo --ft-debuggable--; echo "    \(flagsLine)"; exit 0;;
            esac;;
          install)
            if [ "$4" = "-r" ]; then
              echo "Performing Streamed Install"
              echo "adb: failed to install x.apk: Failure [\(installFailure)]"
              exit 1
            fi
            \(secondInstallSucceeds ? "echo Success; exit 0" : "echo 'Failure [INSTALL_FAILED_INTERNAL_ERROR]'; exit 1");;
          uninstall) \(uninstallSucceeds ? "echo Success; exit 0" : "echo 'Failure [DELETE_FAILED_DEVICE_POLICY_MANAGER]'; exit 1");;
        esac
        exit 0
        """
        let url = dir.appendingPathComponent("adb")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (AndroidDriver(serial: serial, adbPath: url.path), calls)
    }

    func testEmulatorReinstalls() throws {
        let (driver, calls) = try makeDriver(serial: "emulator-5598", flagsLine: "flags=[ HAS_CODE ]")
        let (result, note) = try driver.reinstallAfterSignatureMismatch(
            packagePath: "/x/app.apk", apkPackageName: "com.example.app")
        XCTAssertTrue(result.output.contains("Success"))
        XCTAssertTrue(note.contains("com.example.app"), note)
        XCTAssertTrue(note.contains("data on this device was deleted"), note)
        let log = try String(contentsOf: calls, encoding: .utf8)
        XCTAssertTrue(log.contains("uninstall com.example.app"), log)
    }

    func testPhysicalDebuggableReinstalls() throws {
        let (driver, calls) = try makeDriver(serial: "R58M123ABC", flagsLine: "flags=[ DEBUGGABLE HAS_CODE ]")
        _ = try driver.reinstallAfterSignatureMismatch(packagePath: "/x/app.apk", apkPackageName: "com.example.app")
        XCTAssertTrue(try String(contentsOf: calls, encoding: .utf8).contains("uninstall com.example.app"))
    }

    func testPhysicalReleaseRefusesWithoutUninstalling() throws {
        let (driver, calls) = try makeDriver(serial: "R58M123ABC", flagsLine: "flags=[ HAS_CODE ]")
        XCTAssertThrowsError(try driver.reinstallAfterSignatureMismatch(
            packagePath: "/x/app.apk", apkPackageName: "com.example.app")) { error in
            XCTAssertTrue("\(error)".contains("adb -s R58M123ABC uninstall com.example.app"), "\(error)")
        }
        XCTAssertFalse(try String(contentsOf: calls, encoding: .utf8).contains("uninstall"))
    }

    /// uninstall が失敗したら「消した」と言わず、入れ直しも撃たずに理由を言う
    func testFailedUninstallDoesNotClaimDeletion() throws {
        let (driver, calls) = try makeDriver(serial: "emulator-5598", flagsLine: "flags=[ HAS_CODE ]", uninstallSucceeds: false)
        XCTAssertThrowsError(try driver.reinstallAfterSignatureMismatch(
            packagePath: "/x/app.apk", apkPackageName: "com.example.app")) { error in
            XCTAssertTrue("\(error)".contains("uninstalling it to install this build failed"), "\(error)")
        }
        let log = try String(contentsOf: calls, encoding: .utf8)
        XCTAssertFalse(log.contains("install /x/app.apk"), log)
    }

    func testUnknownPackageNameRefusesEvenOnEmulator() throws {
        let (driver, calls) = try makeDriver(serial: "emulator-5598", flagsLine: "flags=[ DEBUGGABLE ]")
        XCTAssertThrowsError(try driver.reinstallAfterSignatureMismatch(packagePath: "/x/app.apk", apkPackageName: nil)) { error in
            XCTAssertTrue("\(error)".contains("could not read the package name"), "\(error)")
        }
        XCTAssertFalse((try? String(contentsOf: calls, encoding: .utf8))?.contains("uninstall") ?? false)
    }

    // MARK: - 公開口 install(packagePath:) を通す(パッケージ名は同梱の実 APK から読む)

    private var bridgeAPK: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AndroidRunner/prebuilt/ftbridge.apk").path
    }

    func testPublicInstallReturnsTheReinstallNote() async throws {
        let (driver, calls) = try makeDriver(serial: "emulator-5598", flagsLine: "flags=[ HAS_CODE ]")
        let note = try await driver.install(packagePath: bridgeAPK)
        let text = try XCTUnwrap(note)
        XCTAssertTrue(text.contains("com.example.ftbridge"), text)
        XCTAssertTrue(text.contains("data on this device was deleted"), text)
        XCTAssertTrue(try String(contentsOf: calls, encoding: .utf8).contains("uninstall com.example.ftbridge"))
    }

    func testPublicInstallOtherFailureDoesNotUninstall() async throws {
        let (driver, calls) = try makeDriver(
            serial: "emulator-5598", flagsLine: "flags=[ HAS_CODE ]",
            installFailure: "INSTALL_FAILED_INSUFFICIENT_STORAGE")
        do {
            _ = try await driver.install(packagePath: bridgeAPK)
            XCTFail("install should throw")
        } catch {
            XCTAssertTrue("\(error)".contains("failed to install the app"), "\(error)")
        }
        XCTAssertFalse(try String(contentsOf: calls, encoding: .utf8).contains("uninstall"))
    }

    /// 入れ直しの2回目が落ちても、アンインストール済み(データは消えた)ことが失敗文に残る
    func testFailedSecondInstallStillReportsTheDeletion() async throws {
        let (driver, _) = try makeDriver(serial: "emulator-5598", flagsLine: "flags=[ HAS_CODE ]",
                                         secondInstallSucceeds: false)
        do {
            _ = try await driver.install(packagePath: bridgeAPK)
            XCTFail("install should throw")
        } catch {
            XCTAssertTrue("\(error)".contains("data on this device was deleted"), "\(error)")
        }
    }
}
