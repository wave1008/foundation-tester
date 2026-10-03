// アプリプロファイルの `platform`(対象 OS)で実行プロファイルのデバイスを絞る共有ヘルパー。
// 使い手: ProfileResolver.resolve / runDeviceMachines / RunProfileScope.roster。
// 3か所で判定がずれると monitor・ディスパッチ・run が別のデバイス集合を見るので、判定はここだけに置く。

import Foundation

public enum AppPlatformScoping {
    /// runDoc が指すアプリプロファイルの対象 OS を軽く読む。app 参照なし・ファイル無し・
    /// デコード不能は hybrid(= 絞らない。エラーは resolve が受け持つ)
    public static func scope(project: TestProject, runDoc: RunProfileDocument) -> AppPlatformScope {
        guard let appRef = runDoc.app,
              let data = try? Data(contentsOf: project.appsDir.appendingPathComponent("\(appRef).json")),
              let profile = try? JSONDecoder().decode(AppProfile.self, from: data) else {
            return .hybrid
        }
        return profile.platform ?? .hybrid
    }

    /// 対象 OS に含まれるデバイス(kept)と無視するデバイス(ignored)に分ける。順序は保つ
    public static func partition(_ entries: [DeviceMachineGrouping.CatalogEntry],
                                 scope: AppPlatformScope)
        -> (kept: [DeviceMachineGrouping.CatalogEntry], ignored: [DeviceMachineGrouping.CatalogEntry]) {
        (entries.filter { scope.includes(platform: $0.platform) },
         entries.filter { !scope.includes(platform: $0.platform) })
    }

    public static func ignoredWarning(entry: DeviceMachineGrouping.CatalogEntry, app: String,
                                      scope: AppPlatformScope) -> String {
        "device \"\(entry.name)\" (\(entry.platform)) is ignored:"
            + " app profile \"\(app)\" targets \(scope.rawValue) only"
    }
}
