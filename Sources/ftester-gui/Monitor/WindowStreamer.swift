// WindowStreamer.swift
// 1ウィンドウ = 1ストリーム = 1タイル。フレーム更新はタイル単位の @Observable に閉じ込め、
// 他タイルの再描画を誘発しないようにする。

import AppKit
import CoreImage
import ScreenCaptureKit

/// SCStream のコールバックは背景キューで呼ばれるため、NSObject ハンドラを分離して
/// クロージャ経由で MainActor の WindowStreamer にフレームを渡す
final class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CGImage) -> Void)?
    var onStopped: ((Error?) -> Void)?

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let statusRaw = attachments[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        onFrame?(cgImage)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}

@MainActor
@Observable
final class WindowStreamer: Identifiable {
    nonisolated let id: CGWindowID
    let window: CapturableDeviceWindow
    /// 照合できたワーカーラベル("ios:8123" / "android")。照合不能なら nil
    var portLabel: String?
    private(set) var latestFrame: CGImage?
    private(set) var lastFrameAt: Date?
    private(set) var error: String?

    private var stream: SCStream?
    private let handler = StreamOutputHandler()
    private let sampleQueue = DispatchQueue(label: "ftester.monitor.frames")

    init(window: CapturableDeviceWindow) {
        self.id = window.id
        self.window = window
    }

    func start() async {
        handler.onFrame = { [weak self] cgImage in
            Task { @MainActor [weak self] in
                self?.latestFrame = cgImage
                self?.lastFrameAt = Date()
            }
        }
        handler.onStopped = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.error = error?.localizedDescription ?? "ストリーム停止"
            }
        }

        let config = SCStreamConfiguration()
        // 長辺 ~800px にキャップ(タイル表示には十分。帯域・CPU の節約)
        let size = window.scWindow.frame.size
        let scale = min(1.0, 800.0 / max(size.width, size.height, 1))
        config.width = max(Int(size.width * scale), 64)
        config.height = max(Int(size.height * scale), 64)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)  // ~10fps
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = false

        let filter = SCContentFilter(desktopIndependentWindow: window.scWindow)
        let stream = SCStream(filter: filter, configuration: config, delegate: handler)
        do {
            try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            self.stream = stream
            self.error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }
}
