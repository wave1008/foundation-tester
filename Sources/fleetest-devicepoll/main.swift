// 実機(iOS/Android)の画面ストリーミング。既存の 2 ヘルパーが実機で使えないための第3の供給源:
//   fleetest-simstream    … iOS シミュレータ。CoreSimulator/SimulatorKit の私有 API で IOSurface を
//                          掴むため**実機では原理的に不可**(deviceSet に実機は居ない)。
//                          macOS 27 では iOS 実機を AVCaptureDevice として出す DAL プラグインも
//                          消えており(2026-07-25 実測: CoreMediaIO デバイス数 0)、この道も無い。
//   fleetest-androidstream … adb screenrecord。Android 実機でも動くが **画面が動いている間しか
//                          フレームが流れない**(静止画面は 20 バイトのキープアライブのみ。同実測)。
// そこで実機は「スクリーンショットを一定間隔で取る」方式に統一する。遅いが確実で、静止画面でも映る。
//   iOS     … ブリッジの GET /screenshot(XCUIScreen.main.screenshot()。USB トンネル経由で 1 往復 ~5ms)
//   Android … adb exec-out screencap -p
//
// stdout は v1(MJPEG)フォーマット固定。契約の正本は vscode-fleetest/src/deviceStream.ts の冒頭:
//   WIDTH(uint16 BE) HEIGHT(uint16 BE) LEN(uint32 BE) JPEG(LEN バイト)の繰り返し。
// stdin EOF = 親がパイプを閉じた = 終了指示(常駐ヘルパー共通規約。他 2 ヘルパーと同じ)。

import Foundation
import FTCore

// MARK: - 引数

struct Options {
    var platform = "ios"
    var host = "127.0.0.1"
    var port: UInt16 = 8123
    var serial = ""
    var adb = "adb"
    var fps: Double = 2
    var maxWidth = 480
    var quality: Double = 0.6
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while let key = args.first {
        args.removeFirst()
        let value = args.first
        switch key {
        case "--platform": o.platform = value ?? o.platform; args = Array(args.dropFirst())
        case "--host": o.host = value ?? o.host; args = Array(args.dropFirst())
        case "--port": o.port = value.flatMap(UInt16.init) ?? o.port; args = Array(args.dropFirst())
        case "--serial": o.serial = value ?? o.serial; args = Array(args.dropFirst())
        case "--adb": o.adb = value ?? o.adb; args = Array(args.dropFirst())
        case "--fps": o.fps = value.flatMap(Double.init) ?? o.fps; args = Array(args.dropFirst())
        case "--max-width": o.maxWidth = value.flatMap(Int.init) ?? o.maxWidth; args = Array(args.dropFirst())
        case "--quality": o.quality = value.flatMap(Double.init) ?? o.quality; args = Array(args.dropFirst())
        default: break
        }
    }
    return o
}

// MARK: - フレーム取得

/// completion ハンドラが書き込む結果の受け皿。不変条件: signal 前に書き、wait 後に読む
private final class ResultBox: @unchecked Sendable { var data: Data? }

/// iOS: 常駐ブリッジの /screenshot(PNG)。実機は host が iproxy のループバックか LAN IP になる
func captureIOS(_ o: Options) -> Data? {
    guard let url = URL(string: "http://\(o.host):\(o.port)/screenshot") else { return nil }
    var request = URLRequest(url: url)
    // fps 間隔より長く待たない(詰まったフレームを溜めるより落とす方がライブ表示として正しい)
    request.timeoutInterval = max(2.0, 2.0 / max(o.fps, 0.1))
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox()
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if let data, (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
            box.data = data
        }
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + request.timeoutInterval + 1)
    return box.data
}

/// Android: adb exec-out screencap -p(PNG)
func captureAndroid(_ o: Options) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: o.adb)
    process.arguments = ["-s", o.serial, "exec-out", "screencap", "-p"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return data.isEmpty ? nil : data
}

// MARK: - 変換・出力
// **--max-width は「幅」の上限**(既存 2 ヘルパーと同じ意味。androidstream の scale=maxWidth/w 参照)。
// PNG→JPEG 縮小(長辺換算の罠込み)は Sources/FTCore/ImageDownscale.swift(MCP の ft_screenshot と共有)

/// v1 レコード 1 件。書き込み失敗(親が閉じた)は終了扱い
func emit(jpeg: Data, width: Int, height: Int) -> Bool {
    var header = Data()
    func append16(_ v: Int) {
        let value = UInt16(clamping: v).bigEndian
        withUnsafeBytes(of: value) { header.append(contentsOf: $0) }
    }
    append16(width)
    append16(height)
    let length = UInt32(jpeg.count).bigEndian
    withUnsafeBytes(of: length) { header.append(contentsOf: $0) }
    let payload = header + jpeg
    return payload.withUnsafeBytes { buffer -> Bool in
        var offset = 0
        while offset < buffer.count {
            let written = write(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
}

// MARK: - main

let options = parseOptions()
guard options.platform == "ios" || options.platform == "android" else {
    FileHandle.standardError.write(Data("error: --platform must be ios or android\n".utf8))
    exit(2)
}
if options.platform == "android" && options.serial.isEmpty {
    FileHandle.standardError.write(Data("error: --serial is required (android)\n".utf8))
    exit(2)
}

// stdin EOF = 終了指示。読み取り専用スレッドで待つ(取得ループは main で回す)
Thread.detachNewThread {
    var buffer = [UInt8](repeating: 0, count: 64)
    while true {
        let n = read(STDIN_FILENO, &buffer, buffer.count)
        if n <= 0 { exit(0) }
    }
}
signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }

let interval = 1.0 / max(options.fps, 0.1)
// 連続失敗は「デバイス消失」とみなして落とす(拡張側の常駐監視が再起動を判断する)。
// 単発の失敗で落とすと、端末のスリープ復帰やブリッジの一時的な取り込み中で無駄に再起動が走る
var consecutiveFailures = 0
let maxConsecutiveFailures = 10

while true {
    let started = Date()
    let png = options.platform == "ios" ? captureIOS(options) : captureAndroid(options)
    if let png, let (jpeg, width, height) = ImageDownscale.jpeg(
        png: png, maxWidth: options.maxWidth, quality: options.quality) {
        consecutiveFailures = 0
        if !emit(jpeg: jpeg, width: width, height: height) { exit(0) }
    } else {
        consecutiveFailures += 1
        if consecutiveFailures >= maxConsecutiveFailures {
            FileHandle.standardError.write(Data(
                "error: failed to capture a screenshot \(maxConsecutiveFailures) times in a row\n".utf8))
            exit(4)
        }
    }
    let elapsed = Date().timeIntervalSince(started)
    if elapsed < interval { Thread.sleep(forTimeInterval: interval - elapsed) }
}
