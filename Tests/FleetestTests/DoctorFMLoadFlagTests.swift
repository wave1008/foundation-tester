// `fleetest doctor --fm-load*` のフラグの規律。負荷生成は FM を実際に呼ぶので、ここでは
// ArgumentParser の validate() だけを固定する(呼ばずに落とせる誤用を確認する)。

import XCTest
import ArgumentParser
@testable import fleetest

final class DoctorFMLoadFlagTests: XCTestCase {

    func testTuningFlagsRequireFmLoad() {
        XCTAssertThrowsError(try Doctor.parse(["--fm-load-seconds", "10"])) { error in
            XCTAssertTrue(Doctor.message(for: error).contains("--fm-load-seconds requires --fm-load"),
                          Doctor.message(for: error))
        }
        XCTAssertThrowsError(try Doctor.parse(["--fm-load-concurrency", "3"])) { error in
            XCTAssertTrue(Doctor.message(for: error).contains("--fm-load-concurrency requires --fm-load"),
                          Doctor.message(for: error))
        }
        XCTAssertThrowsError(try Doctor.parse(["--fm-load-vision"])) { error in
            XCTAssertTrue(Doctor.message(for: error).contains("--fm-load-vision requires --fm-load"),
                          Doctor.message(for: error))
        }
    }

    func testFmLoadRejectsFmOnlyAndRootsOnly() {
        XCTAssertThrowsError(try Doctor.parse(["--fm-load", "--fm-only"])) { error in
            XCTAssertTrue(Doctor.message(for: error).contains("--fm-load cannot be combined with --fm-only"),
                          Doctor.message(for: error))
        }
        XCTAssertThrowsError(try Doctor.parse(["--fm-load", "--roots-only"])) { error in
            XCTAssertTrue(Doctor.message(for: error).contains("--fm-load cannot be combined with --roots-only"),
                          Doctor.message(for: error))
        }
    }

    func testFmLoadWithTuningFlagsParsesCleanly() {
        XCTAssertNoThrow(try Doctor.parse(["--fm-load"]))
        XCTAssertNoThrow(try Doctor.parse([
            "--fm-load", "--fm-load-seconds", "10", "--fm-load-concurrency", "3", "--fm-load-vision",
        ]))
    }
}
