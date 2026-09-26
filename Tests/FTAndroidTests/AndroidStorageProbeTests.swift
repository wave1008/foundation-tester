// AndroidStorageProbe の純粋パーサ(df /data の出力解析)。adb 実行そのものは対象外(実機/エミュ依存)。

import XCTest
@testable import FTAndroid

final class AndroidStorageProbeTests: XCTestCase {

    func testParsesStandardDfOutput() {
        let output = """
        Filesystem     1K-blocks    Used Available Use% Mounted on
        /dev/block/dm-7 53584132 8140864  44239884  16% /data
        """
        let parsed = AndroidStorageProbe.parse(dfOutput: output)
        XCTAssertEqual(parsed?.usedBytes, 8_140_864 * 1024)
        XCTAssertEqual(parsed?.freeBytes, 44_239_884 * 1024)
    }

    /// ヘッダ行(数値列を持たない)は無視される
    func testIgnoresTheHeaderLine() {
        let output = "Filesystem     1K-blocks    Used Available Use% Mounted on\n"
            + "/dev/block/dm-7 53584132 8140864 44239884 16% /data"
        XCTAssertNotNil(AndroidStorageProbe.parse(dfOutput: output))
    }

    func testUnparsableOutputReturnsNil() {
        XCTAssertNil(AndroidStorageProbe.parse(dfOutput: ""))
        XCTAssertNil(AndroidStorageProbe.parse(dfOutput: "adb: device offline"))
    }

    /// 間隔の既定値をリテラルで固定する(docs/results-json.md「間隔: Android 5 分」)
    func testDefaultProbeIntervalIsFiveMinutes() {
        XCTAssertEqual(AndroidStorageProbe.probeIntervalSeconds, 300)
    }
}
