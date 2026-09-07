// occlusion-guard の crop 矩形計算(FM の Tier-2 と Vision OCR の Tier-2 が同じ画素を見るための
// 共通定義元。RegionText.swift(OCR)と FTFoundationModels/OcclusionVerifier.swift(FM)の双方が
// これを呼ぶ)。

import CoreGraphics
import Foundation

public enum OcclusionCrop {
    /// frame(pt)→スクショ(px)へ換算し、判定器に渡すクロップ矩形(px・画像内にクランプ済み)を返す。
    /// nil = 換算後に有効領域が無い(退化 frame・画面外)。純幾何のためユニットテスト対象。
    ///
    /// 余白(cropPadding)は覆いの縁・近傍の文脈を見せるためのものだが、固定値だと小要素
    /// (バッジ「3」・価格など)でクロップの過半を近傍が占め、FM が対象でなく近傍を見て誤反転する
    /// (実機で約50%誤反転の一因)。そこで **軸ごとに余白を要素サイズの 1/3 で頭打ち**にし、
    /// 対象がクロップの概ね 6 割以上を占めるようにする(大要素では従来どおり cropPadding で頭打ち)。
    public static func rect(frame: FTRect, screen: FTRect, imageWidth: Int, imageHeight: Int,
                            cropPadding: CGFloat) -> CGRect? {
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        let scaleX = CGFloat(imageWidth) / CGFloat(screen.width == 0 ? Double(imageWidth) : screen.width)
        let scaleY = CGFloat(imageHeight) / CGFloat(screen.height == 0 ? Double(imageHeight) : screen.height)
        let wpx = CGFloat(frame.width) * scaleX
        let hpx = CGFloat(frame.height) * scaleY
        // 対象がクロップの ≳60% を占めるよう、小要素では余白を要素サイズの 1/3 に比例縮小する。
        let padX = min(cropPadding, wpx / 3)
        let padY = min(cropPadding, hpx / 3)
        let px = CGRect(x: CGFloat(frame.x) * scaleX - padX,
                        y: CGFloat(frame.y) * scaleY - padY,
                        width: wpx + padX * 2,
                        height: hpx + padY * 2)
        let clamped = px.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped
    }
}
