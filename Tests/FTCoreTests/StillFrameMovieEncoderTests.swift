import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FTCore

final class StillFrameMovieEncoderTests: XCTestCase {

    private var dir: URL!
    private let base: Int64 = 1_801_234_567_890

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StillFrameMovieEncoderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func writePNG(name: String, width: Int, height: Int, gray: CGFloat) -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: gray, green: 0.5, blue: 1 - gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    private func out() -> URL { dir.appendingPathComponent("out.mp4") }

    private func sampleCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var n = 0
        // 空のバッファ(サンプル数 0 = 終端・編集の印)も返るので、バッファではなくサンプルを数える
        while let buffer = output.copyNextSampleBuffer() { n += CMSampleBufferGetNumSamples(buffer) }
        return n
    }

    private func XCTUnwrapAsync<T>(_ v: @autoclosure () async throws -> T?) async throws -> T {
        guard let x = try await v() else { throw XCTSkip("nil") }
        return x
    }

    func testFramesSortedAndFiltered() {
        writePNG(name: "\(base + 1200).png", width: 10, height: 10, gray: 0.1)
        writePNG(name: "\(base).png", width: 10, height: 10, gray: 0.2)
        writePNG(name: "\(base + 500).png", width: 10, height: 10, gray: 0.3)
        writePNG(name: "x.png", width: 10, height: 10, gray: 0.3)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("123.jpg").path, contents: Data([1]))
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".DS_Store").path, contents: Data([1]))
        let frames = StillFrameMovieEncoder.frames(in: dir)
        XCTAssertEqual(frames.map { $0.url.lastPathComponent },
                       ["\(base).png", "\(base + 500).png", "\(base + 1200).png"])
        XCTAssertEqual(frames[1].at.timeIntervalSince1970, Double(base + 500) / 1000, accuracy: 0.0005)
    }

    func testEncodeDurationSizeAndSampleCount() async throws {
        writePNG(name: "\(base).png", width: 100, height: 200, gray: 0.1)
        writePNG(name: "\(base + 500).png", width: 100, height: 200, gray: 0.5)
        writePNG(name: "\(base + 1200).png", width: 100, height: 200, gray: 0.9)
        let frames = StillFrameMovieEncoder.frames(in: dir)
        let end = date(base + 3000)
        let ok = await StillFrameMovieEncoder.encode(frames: frames, endAt: end, to: out())
        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out().path))
        let asset = AVURLAsset(url: out())
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3.0, accuracy: 0.05)
        let track = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 200)
        let n = try await sampleCount(out())
        XCTAssertEqual(n, 3)
    }

    func testOddSizeRoundsDownToEven() async throws {
        writePNG(name: "\(base).png", width: 101, height: 201, gray: 0.1)
        writePNG(name: "\(base + 500).png", width: 101, height: 201, gray: 0.8)
        let ok = await StillFrameMovieEncoder.encode(
            frames: StillFrameMovieEncoder.frames(in: dir), endAt: date(base + 1000), to: out())
        XCTAssertTrue(ok)
        let asset = AVURLAsset(url: out())
        let track = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 200)
    }

    func testDifferentSizedFrameIsAccepted() async throws {
        writePNG(name: "\(base).png", width: 100, height: 200, gray: 0.1)
        writePNG(name: "\(base + 500).png", width: 200, height: 100, gray: 0.8)
        let ok = await StillFrameMovieEncoder.encode(
            frames: StillFrameMovieEncoder.frames(in: dir), endAt: date(base + 1000), to: out())
        XCTAssertTrue(ok)
        let n = try await sampleCount(out())
        XCTAssertEqual(n, 2)
    }

    func testUndecodableFrameIsSkipped() async throws {
        writePNG(name: "\(base).png", width: 100, height: 200, gray: 0.1)
        try Data("not a png".utf8).write(to: dir.appendingPathComponent("\(base + 400).png"))
        writePNG(name: "\(base + 800).png", width: 100, height: 200, gray: 0.8)
        let ok = await StillFrameMovieEncoder.encode(
            frames: StillFrameMovieEncoder.frames(in: dir), endAt: date(base + 2000), to: out())
        XCTAssertTrue(ok)
        let n = try await sampleCount(out())
        XCTAssertEqual(n, 2)
    }

    func testEmptyAndAllUndecodableReturnFalse() async throws {
        let empty = await StillFrameMovieEncoder.encode(frames: [], endAt: date(base + 1000), to: out())
        XCTAssertFalse(empty)
        try Data("junk".utf8).write(to: dir.appendingPathComponent("\(base).png"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("\(base + 100).png"))
        let bad = await StillFrameMovieEncoder.encode(
            frames: StillFrameMovieEncoder.frames(in: dir), endAt: date(base + 1000), to: out())
        XCTAssertFalse(bad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out().path))
    }

    func testEndBeforeLastFrameHoldsLastFrameOneSecond() async throws {
        writePNG(name: "\(base).png", width: 100, height: 200, gray: 0.1)
        writePNG(name: "\(base + 2000).png", width: 100, height: 200, gray: 0.8)
        let ok = await StillFrameMovieEncoder.encode(
            frames: StillFrameMovieEncoder.frames(in: dir), endAt: date(base + 500), to: out())
        XCTAssertTrue(ok)
        let duration = try await AVURLAsset(url: out()).load(.duration).seconds
        XCTAssertEqual(duration, 3.0, accuracy: 0.05)
    }

    /// 画像の赤成分(0〜1)。fill の red = gray なので、どのフレームが映っているかを見分けられる
    private func redAt(_ seconds: Double, in url: URL) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 1000))
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return Double(pixel[0]) / 255
    }

    /// 各フレームは自分の時刻から次のフレームまで映る(0〜0.5 秒 = 1枚目・0.5〜1.2 秒 = 2枚目・以降 3枚目)
    func testEachFrameIsShownFromItsOwnTime() async throws {
        writePNG(name: "\(base).png", width: 100, height: 200, gray: 0.1)
        writePNG(name: "\(base + 500).png", width: 100, height: 200, gray: 0.5)
        writePNG(name: "\(base + 1200).png", width: 100, height: 200, gray: 0.9)
        let ok = await StillFrameMovieEncoder.encode(
            frames: StillFrameMovieEncoder.frames(in: dir), endAt: date(base + 3000), to: out())
        XCTAssertTrue(ok)
        let early = try await redAt(0.2, in: out())
        let middle = try await redAt(0.8, in: out())
        let late = try await redAt(2.5, in: out())
        // 値そのものは色空間の変換(sRGB ↔ H.264 の YUV)でずれる(実測 0.1→0.24・0.5→0.61)ので、
        // 3枚の赤(0.1 / 0.5 / 0.9)の中点で区切ってどれが映っているかだけを見る
        XCTAssertLessThan(early, 0.4, "0.2 秒は1枚目")
        XCTAssertTrue((0.4..<0.75).contains(middle), "0.8 秒は2枚目: \(middle)")
        XCTAssertGreaterThanOrEqual(late, 0.75, "2.5 秒は3枚目")
    }

    /// 先頭が復号できなくても原点は frames[0].at のまま(呼び手が segments の開始に使う時刻とずらさない)
    func testOriginStaysAtTheFirstFileEvenIfItCannotBeDecoded() async throws {
        try Data("junk".utf8).write(to: dir.appendingPathComponent("\(base).png"))
        writePNG(name: "\(base + 500).png", width: 100, height: 200, gray: 0.5)
        let ok = await StillFrameMovieEncoder.encode(
            frames: StillFrameMovieEncoder.frames(in: dir), endAt: date(base + 2000), to: out())
        XCTAssertTrue(ok)
        let duration = try await AVURLAsset(url: out()).load(.duration).seconds
        XCTAssertEqual(duration, 2.0, accuracy: 0.05)
    }
}

