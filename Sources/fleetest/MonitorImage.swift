// MonitorImage.swift
// スクリーンショット PNG を Webview 用 JPEG へダウンスケール変換する。ApiMonitorCommand.swift から分離。

import ArgumentParser
import CoreGraphics
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore
import FTRemote
import ImageIO
import UniformTypeIdentifiers

// MARK: - 画像変換

/// 生PNGの base64 は1フレーム数MBになり Webview に流せないため maxWidth px にダウンスケールして
/// JPEG化する。private を外して ApiLiveCommand.swift にも共有する
enum MonitorImage {
    struct Result {
        let data: Data
        let width: Int
        let height: Int
    }

    enum ConvertError: Error, LocalizedError {
        case decodeFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .decodeFailed: return "failed to decode the screenshot"
            case .encodeFailed: return "failed to encode to JPEG"
            }
        }
    }

    /// maxWidth が 0 以下なら縮小せず原寸で JPEG 化する(ライブ操作の原寸表示用。
    /// モニタータイルは正の値でダウンスケールする)
    static func downscaledJPEG(pngData: Data, maxWidth: Int,
                               quality: CGFloat = 0.7) throws -> Result {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else {
            throw ConvertError.decodeFailed
        }
        var thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if maxWidth > 0 {
            thumbnailOptions[kCGImageSourceThumbnailMaxPixelSize] = maxWidth
        }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary) else {
            throw ConvertError.decodeFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConvertError.encodeFailed
        }
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, thumbnail, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConvertError.encodeFailed
        }
        return Result(data: output as Data, width: thumbnail.width, height: thumbnail.height)
    }
}
