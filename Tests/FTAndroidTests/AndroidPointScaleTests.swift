// Android の木は **px** なので、pt/dp で決めた幾何の床(StepExecutor.minimumVisibleTapExtent)は
// 密度で換算してからでないと使えない。換算しないと3倍密度で床が約3倍緩み、
// **わずかな重なりを「見えている部分」と信じて叩く**(誤タップは 200 を返すので沈黙する)。
//
// ここは「デバイスから採った密度が pointScale になっていること」を、
// 解析(純粋関数)と配線(ソース走査)の2面で固定する —— 実測値そのものはデバイスが要るため。

import XCTest
@testable import FTAndroid

final class AndroidPointScaleTests: XCTestCase {

    func testParsesThePhysicalDensity() {
        XCTAssertEqual(AndroidDriver.parseDisplayDensity("Physical density: 480"), 3.0)
        XCTAssertEqual(AndroidDriver.parseDisplayDensity("Physical density: 160"), 1.0)
        XCTAssertEqual(AndroidDriver.parseDisplayDensity("Physical density: 420")!,
                       2.625, accuracy: 0.0001)
    }

    /// **Override があればそちらが実効値**(最後の density 行を採る)
    func testOverrideDensityWins() {
        let output = "Physical density: 480\nOverride density: 240"
        XCTAssertEqual(AndroidDriver.parseDisplayDensity(output), 1.5)
    }

    /// 読めない出力で**嘘の倍率を作らない**(呼び手が 1 = 換算しない側へ落ちる)
    func testUnreadableOutputStaysUnknown() {
        XCTAssertNil(AndroidDriver.parseDisplayDensity(""))
        XCTAssertNil(AndroidDriver.parseDisplayDensity("error: no devices/emulators found"))
        XCTAssertNil(AndroidDriver.parseDisplayDensity("Physical density: none"))
        XCTAssertNil(AndroidDriver.parseDisplayDensity("Physical density: 0"))
    }

    /// **配線**: `pointScale` はデバイスから採った密度であること。
    /// 定数を返す実装に戻すと床の換算が無意味になるが、値そのものはデバイスが要るので
    /// ここはソースで固定する(解析の正しさは上のテスト)
    func testPointScaleIsDerivedFromTheDeviceDensity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTAndroidTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/FTAndroid/AndroidDriver.swift"),
            encoding: .utf8)
        guard let range = source.range(of: "public var pointScale: Double {") else {
            return XCTFail("pointScale の宣言が見つからない(この走査を見直すこと)")
        }
        var depth = 0
        var end = range.upperBound
        for index in source.indices[range.lowerBound...] {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
        }
        let body = String(source[range.upperBound..<end])
        XCTAssertTrue(body.contains("displayDensity()"),
                      "pointScale がデバイスの密度を見ていない(床の換算が効かなくなる): \(body)")
    }
}
