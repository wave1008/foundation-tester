// AndroidRunner/build.sh の VERSION_CODE と AndroidDriver.expectedBridgeVersionCode の同期検証。
// 片方だけ上げると、APK は新しいのに稼働中の旧ブリッジが「版一致」と見なされて再利用され、
// 追加したエンドポイントが 404 になる(dylib 側で同じ形の事故を実際に踏んだ)。
// ftester api の ProtocolVersion を protocolVersion.test.mjs が守っているのと同じ役割。

import XCTest
import FTAndroid

final class AndroidBridgeVersionSyncTests: XCTestCase {

    func testBuildScriptVersionCodeMatchesHostConstant() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTAndroidTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        let script = repoRoot.appendingPathComponent("AndroidRunner/build.sh")
        let text = try String(contentsOf: script, encoding: .utf8)

        let prefix = "VERSION_CODE="
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: false)
                .first(where: { $0.hasPrefix(prefix) }),
              let value = Int(line.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)) else {
            return XCTFail("AndroidRunner/build.sh から VERSION_CODE を読めません")
        }

        XCTAssertEqual(value, AndroidDriver.expectedBridgeVersionCode,
                       "AndroidRunner/build.sh の VERSION_CODE と "
                       + "AndroidDriver.expectedBridgeVersionCode は同時に上げること"
                       + "(片方だけだと稼働中の旧ブリッジが再利用され新機能が効かない)")
    }
}
