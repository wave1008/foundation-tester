// WorkspaceAppStaging.swift
// appPath の原本(ResolvedAppTarget.sourcePath。常にリポジトリルート基準)を
// `remoteControl.workspace` の apps/ へ供給する I/O 層。インストール先の決定(パス計算)は
// ProfileResolver.resolve が既に行っている(ResolvedAppTarget.appPath)。ここは
// 「そこにバイトを実際に運ぶ」ことだけを担う。呼び出し場所は3つ:
//   - ProfileRunner.run / ApiRunCommand: 自分自身の apps[platform] を揃える(stageWorkspaceApps)
//   - RemoteRunDispatcher: ミラー rsync 直前にローカルのワークスペースへ揃える(installPath 単体)
// docs/remote-runner.md §17。

import CryptoKit
import Foundation

public enum WorkspaceAppStagingError: Error, LocalizedError {
    /// 原本・複製のどちらも見つからない。**原本のパスを名指しする**(ステージ先を出しても
    /// 「何をビルドすればよいか」分からないため)
    case sourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let path):
            return "app package not found at \(path) (this is the appPath source location —"
                + " build it there before running with a workspace declared)"
        }
    }
}

public enum WorkspaceAppStaging {

    /// インストール先の唯一の規則:
    /// "<workspaceRoot>/apps/[physical/]<declared のハッシュ12桁>/<declared のファイル名>"。
    /// ProfileResolver.resolve(ResolvedAppTarget.appPath の計算)とここ(実コピー先)の両方が
    /// この関数を呼ぶ ―― 定義がずれると「ローカルでは動くがリモートでは見つからない」が起きる。
    ///
    /// **`declared` はプロファイル JSON に書かれた生の文字列(resolvePath で絶対化する前)を渡す**。
    /// 絶対パス(source/sourcePath)から名前空間を作らないのは、絶対パスの前置き(repoRoot)が
    /// ローカルとリモートの子で異なるため ―― 同じ宣言でもホストごとに違うステージ先になり、
    /// リモートの子が自分で resolve() し直したときに手元がステージしたファイルを見失う
    /// (ワークスペースは rsync で丸ごと運ばれる複製で、リモートは中身を読むだけ。
    /// docs/remote-runner.md §17)。`declared` はプロジェクトの JSON ファイル自体を通じて
    /// 両ホストへ届くので、文字列としては常に一致する。
    ///
    /// **名前空間を挟むのは、declared のファイル名(basename)だけでは衝突するから** ——
    /// 同じプロジェクトの別アプリプロファイルが `E2EAppIOS/dist/ios-simulator/X.app` と
    /// `E2EAppIOS/dist/ios-device/X.app` のように**同名の別ビルド**を指すのは珍しくなく、
    /// basename だけをステージ先にすると並走する2つの run が交互に上書きし合う
    /// (実測: 実機の run がシミュレータ build を install して 0xe8008014 で落ちた)。
    /// 名前空間は SHA-256(declared) の先頭12桁 ―― パス区切り・記号を気にせず
    /// ディレクトリ名にでき、declared が同じなら常に同じ、違えば(ほぼ確実に)別になる。
    ///
    /// **実機用を別ディレクトリに置くのは appPathPhysical の意味を変えないため**
    /// (物理端末とシミュレータ/仮想デバイスで appPath が同名でも運用上は別物として扱う既存の規則)
    public static func installPath(declared: String, workspaceRoot: URL,
                                   physical: Bool = false) -> String {
        workspaceRoot.appendingPathComponent("apps")
            .appendingPathComponent(physical ? "physical" : "")
            .appendingPathComponent(declaredPathNamespace(declared))
            .appendingPathComponent((declared as NSString).lastPathComponent).path
    }

    /// `declared`(プロファイル JSON の生の相対/絶対文字列)から決定的に導くディレクトリ名。
    /// SHA-256 の先頭12桁の hex ―― 衝突を実質無視できる長さで、パス区切り・空白等の
    /// 記号を含む declared 文字列でも安全にディレクトリ名へ落とせる
    private static func declaredPathNamespace(_ declared: String) -> String {
        let digest = SHA256.hash(data: Data(declared.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// resolved.apps の全 platform について、sourcePath と appPath(インストール先)が
    /// 食い違っている(= ワークスペース有効)ものだけ同期する。戻り値: 実際にコピーした platform 名
    /// (ログ表示用。ソート済み)
    @discardableResult
    public static func stageWorkspaceApps(_ profile: ResolvedProfile) throws -> [String] {
        var staged: [String] = []
        for platform in profile.apps.keys.sorted() {
            guard let app = profile.apps[platform] else { continue }
            if let source = app.sourcePath, let dest = app.appPath, source != dest,
               try stageApp(source: source, dest: dest) {
                staged.append(platform)
            }
            // 実機用は**その platform に実機が居るときだけ**運ぶ(仮想デバイスだけの run で
            // 100MB 級のパッケージを毎回コピーし、リモートへも rsync するのは払い損)
            guard profile.devices.contains(where: { $0.platform == platform && $0.spec.isPhysical }),
                  let source = app.sourcePathPhysical, let dest = app.appPathPhysical,
                  source != dest else { continue }
            if try stageApp(source: source, dest: dest), !staged.contains(platform) {
                staged.append(platform)
            }
        }
        return staged
    }

    /// 単一パッケージの同期。冪等 —— フィンガープリント(バイト数+自分自身の更新日時。中身は
    /// 読まない)が一致すればコピーしない。115MB の .app 全体を毎回ハッシュすると「変化していなければ
    /// 読まない」という目的に反するため、rsync の既定クイックチェック(--checksum を渡さない限り
    /// size+mtime で十分とみなす)と同じ根拠を採る。
    ///
    /// **source が存在せず dest も無い場合だけエラー**(原本のパスを名指しする)。source が無く
    /// dest だけあるのは想定内で無視する ―— リモートの子は rsync で複製だけを受け取り原本を
    /// 持たない(docs/remote-runner.md §17)。ここで常にエラーにすると、この機構が解決した
    /// 「リモートで appPath が見つからない」問題へ逆戻りする。
    ///
    /// 戻り値: 実際にコピーしたら true(スキップ/複製のみ確認は false)
    @discardableResult
    public static func stageApp(source: String, dest: String) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source) else {
            guard fm.fileExists(atPath: dest) else {
                throw WorkspaceAppStagingError.sourceNotFound(source)
            }
            return false
        }
        if let sourceFP = fingerprint(source), let destFP = fingerprint(dest), sourceFP == destFP {
            return false
        }
        let destURL = URL(fileURLWithPath: dest)
        try fm.createDirectory(
            at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
        try fm.copyItem(atPath: source, toPath: dest)
        // フィンガープリントの mtime 成分は「自分自身」の更新日時であり、copyItem の mtime 保持は
        // 実装詳細(プラットフォーム依存)に頼りたくないため明示的に原本と揃える。
        // これが無いと次回呼び出しで size は一致するが mtime が「コピーした瞬間」になり、
        // 変化していないのに毎回コピーし直す(冪等性が壊れる)
        if let sourceMTime = (try? fm.attributesOfItem(atPath: source))?[.modificationDate] as? Date {
            try? fm.setAttributes([.modificationDate: sourceMTime], ofItemAtPath: dest)
        }
        return true
    }

    private struct Fingerprint: Equatable {
        let totalSize: Int64
        /// 秒単位に切り捨てた mtime(epoch seconds)。stageApp が copyItem 後に
        /// setAttributes(.modificationDate:) で dest を原本と揃えるが、その値は一度
        /// ファイルシステムへ書き出されてから読み直すため、Date(Double)のままだと
        /// ナノ秒精度の丸め込みで一致判定が実装依存になりうる。伝統的な stat の mtime の粒度
        /// (秒)に合わせて切り捨てることで、往復後の再読み込みでも決定的に一致させる
        let selfModificationEpochSeconds: Int
    }

    /// ファイル: 自分自身のサイズ+更新日時。ディレクトリ(.app 等): 配下ファイルの総バイト数
    /// (深い変更も拾う。バイトは読まず属性のみ走査)+ 自分自身の更新日時(stageApp が copyItem 後に
    /// 明示的に原本と揃えるので、次回呼び出しではここが一致する)。走査に失敗したら nil を返し、
    /// 呼び出し側は「一致を確認できない」= コピーへフォールバックする(安全側に倒す)
    private static func fingerprint(_ path: String) -> Fingerprint? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let selfModificationDate = attrs[.modificationDate] as? Date else { return nil }
        let selfModificationEpochSeconds = Int(selfModificationDate.timeIntervalSince1970)
        if !isDirectory.boolValue {
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            return Fingerprint(totalSize: size, selfModificationEpochSeconds: selfModificationEpochSeconds)
        }
        guard let enumerator = fm.enumerator(atPath: path) else { return nil }
        var totalSize: Int64 = 0
        for case let relative as String in enumerator {
            let full = (path as NSString).appendingPathComponent(relative)
            var childIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &childIsDirectory),
                  !childIsDirectory.boolValue,
                  let childAttrs = try? fm.attributesOfItem(atPath: full) else { continue }
            totalSize += (childAttrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        return Fingerprint(totalSize: totalSize, selfModificationEpochSeconds: selfModificationEpochSeconds)
    }
}
