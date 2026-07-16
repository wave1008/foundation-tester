// isPersistentlyBlank の純粋な確定ロジック(decidePersistentBlank)の検証。
// adb screencap を伴う probeBlank/isPersistentlyBlank 本体は対象外(実機依存のため)。

import XCTest
@testable import FTAndroid

final class AndroidHealthProbeBlankGateTests: XCTestCase {

    func testAllBlankConfirmsPersistent() {
        XCTAssertTrue(AndroidHealthProbe.decidePersistentBlank(samples: [true, true, true]))
    }

    func testSingleBlankSampleConfirmsPersistent() {
        XCTAssertTrue(AndroidHealthProbe.decidePersistentBlank(samples: [true]))
    }

    func testRecoveryPartwayThroughIsNotPersistent() {
        XCTAssertFalse(AndroidHealthProbe.decidePersistentBlank(samples: [true, false, true]))
    }

    func testEmptySamplesIsNotPersistent() {
        XCTAssertFalse(AndroidHealthProbe.decidePersistentBlank(samples: []))
    }
}
