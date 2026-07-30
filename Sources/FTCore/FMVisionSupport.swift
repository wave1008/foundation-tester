// FoundationModels の画像入力(Attachment)が使えるかどうかの単一判定点。
//
// パッケージの最低プラットフォームは macOS 26(Package.swift)だが、Attachment =
// マルチモーダル入力は macOS 27+ でしか存在しない。テキスト系(heal・triage・命名)は
// macOS 26 でも動くため、**視覚系だけ**を実行時に落とす。
//
// 同期相手(ここが false のときに素通り/skip する側):
//   - FTCore/StepExecutor.swift: occlusionFlip・screenMatches
//   - FTAgent/OcclusionVerifier.swift・ReplayAssist.swift(#available で実 API を分岐)

import Foundation

public enum FMVisionSupport {
    /// FM に画像を渡せるか(macOS 27+)。false のとき occlusion-guard と screenIs は無効。
    public static let isSupported: Bool = {
        if #available(macOS 27, *) { return true }
        return false
    }()

    /// 無効理由(ユーザー向け文言。skip 理由・doctor 出力で共用)
    public static let requirement = "FM image input requires macOS 27+"
}
