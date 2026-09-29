// 画面凍結時の「一様フレーム」(白/黒ベタ)を解像度・縮小に依存せず判定する。
// AndroidHealthProbe.blankScreen(PNG サイズ閾値、adb screencap 全解像度前提)とは別軸の判定:
// こちらはブリッジ縮小スクショ等どんな解像度でも使え、内容のある画面(アイコン・文字・ボタン)は
// サンプル点が割れるため誤検知しない。

import CoreGraphics
import Foundation
import ImageIO

public enum BlankFrameDetector {
    /// pngData を sampleGrid×sampleGrid に縮小描画し、基準ピクセル(先頭サンプル)から全チャンネル
    /// tolerance 以内の点が uniformFraction 以上を占めれば一様フレーム(凍結症状)と判定する。
    /// alpha は無視(白黒どちらのベタも検出対象。白限定にしない)。
    /// デコード・描画に失敗した場合は false(過検知よりプローブ欠測を優先する安全側)。
    public static func isUniformBlank(pngData: Data,
                                      sampleGrid: Int = 16,
                                      tolerance: Int = 8,
                                      uniformFraction: Double = 0.995) -> Bool {
        uniformBlankness(pngData: pngData, sampleGrid: sampleGrid,
                         tolerance: tolerance, uniformFraction: uniformFraction) ?? false
    }

    /// `isUniformBlank` と同じ判定を、**デコード・描画に失敗した場合は nil**(判定不能)で返す。
    /// nil = 欠測。「一様でない」の能動的な証拠(false)と区別する必要がある呼び手だけがこちらを使う
    /// (例: モニターの凍結デバウンス。読めないフレームで確定を取り消さないため)。
    public static func uniformBlankness(pngData: Data,
                                        sampleGrid: Int = 16,
                                        tolerance: Int = 8,
                                        uniformFraction: Double = 0.995) -> Bool? {
        guard sampleGrid > 0,
              let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * sampleGrid
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * sampleGrid)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let fraction: Double? = buffer.withUnsafeMutableBytes { rawBuffer -> Double? in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(data: baseAddress, width: sampleGrid, height: sampleGrid,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleGrid, height: sampleGrid))

            let total = sampleGrid * sampleGrid
            let baseR = Int(rawBuffer[0]), baseG = Int(rawBuffer[1]), baseB = Int(rawBuffer[2])
            var uniformCount = 0
            for i in 0..<total {
                let offset = i * bytesPerPixel
                let r = Int(rawBuffer[offset]), g = Int(rawBuffer[offset + 1]), b = Int(rawBuffer[offset + 2])
                if abs(r - baseR) <= tolerance, abs(g - baseG) <= tolerance, abs(b - baseB) <= tolerance {
                    uniformCount += 1
                }
            }
            return Double(uniformCount) / Double(total)
        }

        guard let fraction else { return nil }
        return fraction >= uniformFraction
    }

    /// 下端の帯を除いて**画面全体が黒い**か(occlusion-guard が「描かれていない」の根拠にしないための判定)。
    /// 絵が撮れていない・表示が凍結した回は、ホームインジケータ / ナビゲーションハンドルの1本だけが残り
    /// `isUniformBlank` の 0.995 に届かない(実測 16x16 中 4 セルが割れて 0.984。iOS in-app と Android Emulator)。
    /// **凍結の確定(回復を撃つ根拠)には使わない**。32 x 32 で見るのは、16 x 16 だと暗い画面の小さな文字が
    /// セルの平均に薄まって黒に紛れるため
    public static func isBlackApartFromBottomStrip(pngData: Data) -> Bool {
        isBlack(pngData: pngData, ignoringTopRows: 0)
    }

    /// 上端のステータスバーの帯**も**除いて黒いか。**occlusion-guard の素通りだけが使う**(凍結の警告には使わない
    /// = 上端に中身がある暗い画面を凍結と呼ばない)。撮れていない絵に時計と電池の帯だけが残る形は、
    /// 下端だけ除く判定では黒と言えず、黒い絵を根拠に「描かれていない」の赤を出していた
    /// (実測 Android Emulator: 5 周で 3 本。3 台の Mac の OCR が同じ 2 行だけを読んだ = 絵そのものが黒い)
    public static func isBlackApartFromSystemBars(pngData: Data) -> Bool {
        isBlack(pngData: pngData, ignoringTopRows: blackFrameIgnoredTopRows)
    }

    private static func isBlack(pngData: Data, ignoringTopRows topRows: Int) -> Bool {
        let grid = blackFrameGrid
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: grid, height: grid, bitsPerComponent: 8,
                                      bytesPerRow: grid * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: grid, height: grid))
        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: grid * grid * 4)
        // メモリの行 0 が画像の上端。下端 blackFrameIgnoredBottomRows 行(帯)は見ない
        for row in topRows..<(grid - blackFrameIgnoredBottomRows) {
            for column in 0..<grid {
                let offset = (row * grid + column) * 4
                if max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) > blackFrameMaxChannel {
                    return false
                }
            }
        }
        return true
    }

    /// 32 x 32 の下端 2 行 = 画面の約 6%。ホームインジケータ(iPhone 下端 約 5pt 高)・ナビゲーションハンドルが
    /// 収まる高さ(実測の黒い絵では割れたセルは最下行だけ)
    static let blackFrameGrid = 32
    static let blackFrameIgnoredBottomRows = 2
    /// 32 x 32 の上端 2 行 = 画面の約 6%。ステータスバー(Android 1080x2424 で 142px = 5.9%・iPhone 約 6%)が収まる高さ
    static let blackFrameIgnoredTopRows = 2
    /// セル平均の各チャンネルの上限。実測の黒い絵は 0。暗いテーマの文字入りのセルは 32 x 32 でもこれを超える
    static let blackFrameMaxChannel: UInt8 = 12
}

/// 凍結の根拠に使う1枚ぶんの観測。**同じスクショから2つとも取る**(撮り直すと健全機の固定費が倍になる)。
/// `uniform` の判定は経路ごと(iOS = `isUniformBlank` / Android = 全画素の幅か PNG サイズ)なので呼び手が埋める
public struct FrameBlankness: Equatable, Sendable {
    public let uniform: Bool
    public let blackApartFromBottomStrip: Bool

    public init(uniform: Bool, blackApartFromBottomStrip: Bool) {
        self.uniform = uniform
        self.blackApartFromBottomStrip = blackApartFromBottomStrip
    }

    public static func observe(pngData: Data) -> FrameBlankness {
        FrameBlankness(uniform: BlankFrameDetector.isUniformBlank(pngData: pngData),
                       blackApartFromBottomStrip: BlankFrameDetector.isBlackApartFromBottomStrip(pngData: pngData))
    }
}

/// 連続したサンプルが「ずっと」何だったか。iOS(`BlankWorkerTriage`)と Android(`AndroidHealthProbe`)の
/// 窓の判定はここだけ。**全サンプルが同じ性質を持つときだけ**言い、`uniform` を優先する(確定の根拠)。
/// 一様な黒は下端を除いても黒いので、一様な黒とハンドル付きの黒が混ざった窓は `blackApartFromBottomStrip`
public enum PersistentBlank: Equatable, Sendable {
    case none, uniform, blackApartFromBottomStrip

    /// 空(1枚も撮れていない)は none。呼び手は none になった時点でサンプリングをやめてよい
    /// (以後のサンプルで none から戻ることはない = 健全機は1枚で抜ける)
    public static func fold(_ samples: [FrameBlankness]) -> PersistentBlank {
        guard !samples.isEmpty else { return .none }
        if samples.allSatisfy(\.uniform) { return .uniform }
        if samples.allSatisfy(\.blackApartFromBottomStrip) { return .blackApartFromBottomStrip }
        return .none
    }
}

/// **白フレームを凍結の根拠にしてよいか**。前面にシステムアラートがある
/// (`StepNote.systemAlertPresent`)と分かっている間は、in-app スクショが一様な白になるのは
/// アプリの非アクティブ化のせいであって画面凍結ではない。ここを見ずに「白 = 凍結」と決めると、
/// デバイスは生きているのにワーカー離脱・ブリッジ停止・同じデバイスでの再実行を繰り返して結果が変わらない
public enum FrozenFrameJudgement {
    public static func shouldMarkFrozen(evidenceBlank: Bool, systemAlertPresent: Bool) -> Bool {
        evidenceBlank && !systemAlertPresent
    }
}
