// run の**開始前**に「画面だけ死んだ iOS シミュレータ」を弾く判定を固定する。
//
// 2026-08-05 に E2E-CMP の `-06` が「画面は真っ黒・a11y ツリーは健全・タップだけ届かない」
// 状態になり、**9/9 の失敗が無警告でテストの失敗として記録された**。Android には run 前の
// 同等処理(修復つき)が既にあり、iOS だけ無かった。
// **デバイスが要る部分(スクショの取得)は引数で受け、判定はここで固める**。

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FTCore

/// 呼ばれない前提のドライバ(このテストはスクショを引数で差し替えるため)
private struct UnusedDriver: AppDriver {
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                         elements: [], truncatedCount: 0)
    }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class BlankWorkerTriageTests: XCTestCase {

    private func worker(_ label: String, platform: String = "ios",
                        physical: Bool = false) -> RunWorker {
        RunWorker(label: label, platform: platform, driver: UnusedDriver(),
                  connection: DriverConnection(platform: platform, physical: physical),
                  logicalName: label)
    }

    // MARK: - 対象の選び方

    /// **iOS の仮想デバイスだけ**。Android は修復つきの自前トリアージが既にあるので二重に撃たない。
    /// 実機は「画面が消灯しているだけ」を凍結と誤断する
    func testOnlyVirtualIOSWorkersAreCandidates() {
        XCTAssertTrue(BlankWorkerTriage.isCandidate(worker("sim")))
        XCTAssertFalse(BlankWorkerTriage.isCandidate(worker("emu", platform: "android")),
                       "Android は自前のトリアージ(修復つき)が担当する")
        XCTAssertFalse(BlankWorkerTriage.isCandidate(worker("iphone", physical: true)),
                       "実機は消灯を凍結と誤断する")
    }

    // MARK: - 恒常 blank の判定

    /// **単発のフレームでは決めない**(起動直後の白/黒フレームを凍結と誤断する)
    func testOneBlankFrameIsNotEnough() async {
        var frames = [Self.blankPNG, Self.contentPNG]
        let blank = await BlankWorkerTriage.isPersistentlyBlank(
            screenshot: { frames.isEmpty ? nil : frames.removeFirst() }, sleep: { _ in })
        XCTAssertFalse(blank, "2枚目が非一様なら健全")
    }

    func testConsecutiveBlankFramesAreBlank() async {
        var frames = [Self.blankPNG, Self.blankPNG]
        let blank = await BlankWorkerTriage.isPersistentlyBlank(
            screenshot: { frames.isEmpty ? nil : frames.removeFirst() }, sleep: { _ in })
        XCTAssertTrue(blank)
    }

    /// **撮れなかったら健全に倒す**(誤って健全機を弾かない安全側)
    func testUnreadableScreenshotIsTreatedAsHealthy() async {
        let blank = await BlankWorkerTriage.isPersistentlyBlank(
            screenshot: { nil }, sleep: { _ in })
        XCTAssertFalse(blank)
    }

    /// 健全機は**1サンプルで返る**(正常時の固定費はスクショ1枚)
    func testHealthyDeviceCostsOneSample() async {
        var taken = 0
        _ = await BlankWorkerTriage.isPersistentlyBlank(
            screenshot: { taken += 1; return Self.contentPNG }, sleep: { _ in })
        XCTAssertEqual(taken, 1, "健全機で2枚撮ると run 開始が遅くなる")
    }

    // MARK: - 除外

    func testBlankWorkersAreExcludedKeepingOrder() {
        let workers = [worker("a"), worker("b"), worker("c")]
        let result = BlankWorkerTriage.exclude(workers, blankByLabel: ["b": true])
        XCTAssertEqual(result.workers.map(\.label), ["a", "c"], "順序を保つこと")
        XCTAssertEqual(result.excluded, ["b"])
    }

    func testNothingIsExcludedWhenAllHealthy() {
        let workers = [worker("a"), worker("b")]
        let result = BlankWorkerTriage.exclude(workers, blankByLabel: ["a": false])
        XCTAssertEqual(result.workers.count, 2)
        XCTAssertTrue(result.excluded.isEmpty)
    }

    /// 全滅しても空配列を返すだけ(呼び出し側が「ワーカー不在」として扱う)。
    /// ここで throw すると混在プロファイルの Android 側まで巻き添えになる
    func testAllBlankYieldsEmptyWithoutThrowing() {
        let workers = [worker("a"), worker("b")]
        let result = BlankWorkerTriage.exclude(workers, blankByLabel: ["a": true, "b": true])
        XCTAssertTrue(result.workers.isEmpty)
        XCTAssertEqual(result.excluded.sorted(), ["a", "b"])
    }

    // MARK: - フィクスチャ(PNG)

    /// 一様な黒 = 凍結時に実際に返ってくるフレーム(2026-08-05 実採取。**サイズは 42KB あった**ので
    /// ファイルサイズでは検出できず、画素をサンプルする BlankFrameDetector だけが効く)
    static let blankPNG = makePNG { context in
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    /// 内容のある画面(サンプル点が割れる)
    static let contentPNG = makePNG { context in
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for row in 0..<8 where row.isMultiple(of: 2) {
            for col in 0..<8 where col.isMultiple(of: 2) {
                context.fill(CGRect(x: col * 8, y: row * 8, width: 8, height: 8))
            }
        }
    }

    private static func makePNG(_ draw: (CGContext) -> Void) -> Data {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("テスト用 CGContext 生成に失敗")
        }
        draw(context)
        guard let image = context.makeImage() else { fatalError("テスト用 CGImage 生成に失敗") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("テスト用 PNG destination 生成に失敗")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("テスト用 PNG 書き出しに失敗") }
        return output as Data
    }
}
