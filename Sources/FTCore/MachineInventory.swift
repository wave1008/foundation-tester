// MachineInventory.swift
// **実行プロファイルを選んでいないときの監視対象**(拡張の「(プロファイルなし)」)を決める。
//
// マシンプロファイルは「この Mac に何が登録されているか」の台帳で、**1つのプロジェクトに複数
// 置ける**(構成の使い分け。例: 手元だけの台帳と、ランナーも含む台帳)。実行プロファイルを
// 選んでいれば台帳は一意に決まるが、選んでいないときは決められない —— 以前はそこで諦めて
// 「今動いている台」だけを見ていたため、**台帳が2つある案件では1台も出なかった**
// (実害 2026-08-28。全台が「マシンプロファイル未記載」扱いになり、拡張の表示フィルタが落とした)。
//
// 決め方は「どれか1つを選ぶ」ではなく **全部の台帳を畳んで、観測できるマシンの台だけ残す**:
//   - **観測できるマシン = 手元 + リモート実行の登録簿にあるマシン**(設定タブのホスト表。
//     ユーザー決定 2026-08-29)。登録簿に無いマシンの台は、監視の fan-out が張られないので
//     状態が永久に "unknown" のタイルになるだけ = 出す意味が無い
//   - 重複((platform, machine, name)が同じ)は**最初の1件**。台帳をまたいで同じ台を書くのは
//     普通(手元の台は両方の台帳に居る)なので、重複はエラーではない。**入力の順序で決まる**ので
//     呼び出し側はファイル名順など安定した順で渡すこと
//   - **ただし重複が「同じ台」とは限らない** —— 実体(udid/avd/serial)が食い違うときは
//     IdentityConflict を添えて返す(merge)。どちらが正しいかはここでは決められないので警告だけ
//
// **I/O は loadAll / loadAllNamed だけ**(残りは純粋関数)。
// テストは Tests/FleetestTests/MachineInventoryTests.swift。

import Foundation

public enum MachineInventory {

    /// 台帳1枚。`name` は**警告に出す表示名**(loadAllNamed は "M1Ultra.json" の形で入れる)
    public struct Source: Sendable {
        public let name: String
        public let profile: MachineProfile

        public init(name: String, profile: MachineProfile) {
            self.name = name
            self.profile = profile
        }
    }

    public struct Merged: Sendable {
        public let entries: [DeviceMachineGrouping.CatalogEntry]
        public let conflicts: [IdentityConflict]
    }

    /// 同じ (platform, machine, name) を2枚の台帳が**別の実体**として書いている。畳み込みは
    /// 先頭を採るので、負けたほうの台は一覧から消える —— **手元に実在しないほうが勝つと、
    /// 実在して起動中の台が「id 衝突」で落ちて監視から消える**(実害 2026-09-03: ランナー機の
    /// 視点で書かれた台帳が `machine: "local"` のまま手元の台帳と同居していた)
    public struct IdentityConflict: Equatable, Sendable {
        public let platform: String
        /// 表示名(手元は "local")
        public let machine: String
        public let name: String
        public let keptProfile: String
        public let keptIdentity: String
        public let ignoredProfile: String
        public let ignoredIdentity: String

        public var message: String {
            "machine profiles disagree about \(platform):\(machine)/\(name):"
            + " \(keptProfile) says \(keptIdentity), \(ignoredProfile) says \(ignoredIdentity)."
            + " Using \(keptProfile) — the device \(ignoredProfile) describes is not listed."
            + " Is one of them written from another machine's point of view"
            + " (\"machine\": \"local\" for a device that lives on a runner)?"
        }
    }

    /// machines/ の全マシンプロファイル。**ファイル名順**(下の重複解決が入力順で決まるので、
    /// 走査順で結果が揺れないようにする)。壊れた JSON は警告して飛ばす —— 実行プロファイルを
    /// 選んでいないときは「見えるものを見せる」経路なので、1枚の壊れた台帳で全部を止めない
    /// (選んでいるときは従来どおり decodeFailed で落ちる)。
    /// **I/O はこれと loadAllNamed だけ** —— 下の3つは純粋関数
    public static func loadAll(project: TestProject, warn: (String) -> Void) -> [MachineProfile] {
        loadAllNamed(project: project, warn: warn).map(\.profile)
    }

    /// loadAll と同じものを**台帳の名前付き**で返す。名前は identity の食い違いを名指しするために
    /// 要る(どちらの .json を直せばよいかが分からないと警告が行動に繋がらない)
    public static func loadAllNamed(project: TestProject, warn: (String) -> Void) -> [Source] {
        ProfileResolver.machineNames(project: project).sorted().compactMap { name in
            let url = project.machinesDir.appendingPathComponent("\(name).json")
            guard let data = try? Data(contentsOf: url),
                  let profile = try? JSONDecoder().decode(MachineProfile.self, from: data) else {
                warn("skipping machine profile \(name): it cannot be read")
                return nil
            }
            return Source(name: "\(name).json", profile: profile)
        }
    }

    /// 畳んだカタログを1つのマシンプロファイルの姿へ戻す(`machine` は各デバイスに焼き込み済み
    /// なので既定は持たない)。**既存の (machine, name) 解決をそのまま使うため** ——
    /// 探索の規律を2つ持たない(ApiDeviceOperation.findDevice / RunProfileScope と同じ入力にする)
    public static func mergedProfile(_ entries: [DeviceMachineGrouping.CatalogEntry]) -> MachineProfile {
        MachineProfile(
            machine: nil,
            ios: MachineDeviceList(devices: entries.filter { $0.platform == "ios" }.map(\.spec)),
            android: MachineDeviceList(devices: entries.filter { $0.platform == "android" }.map(\.spec)))
    }

    /// 複数のマシンプロファイルを1つのカタログへ畳む。`registry` はリモート実行の登録簿の
    /// マシン名(手元は登録簿に載らないので常に残す)。並びは渡された台帳の順 → その中は
    /// ios → android(DeviceMachineGrouping.entries と同じ)。
    public static func observableEntries(
        profiles: [MachineProfile],
        registry: [String]
    ) -> [DeviceMachineGrouping.CatalogEntry] {
        merge(sources: profiles.enumerated().map { Source(name: "#\($0.offset + 1)", profile: $0.element) },
              registry: registry).entries
    }

    /// observableEntries と同じ畳み込みに **identity の食い違い**を添えて返す。
    /// 呼び手(監視)は conflicts を stderr へ出すだけ —— どちらが正しいかはここでは決められない
    /// (実体が手元にあるかを見ないと分からず、この関数は I/O を持たない)。
    /// **警告に留める**のは、同居自体は誤りではない(構成の使い分け)ため
    public static func merge(sources: [Source], registry: [String]) -> Merged {
        let registered = Set(registry.compactMap { MachineDispatch.normalize($0) })
        var result: [DeviceMachineGrouping.CatalogEntry] = []
        var conflicts: [IdentityConflict] = []
        // 鍵 → (採用したエントリの台帳名, 実体)
        var seen: [String: (profile: String, identity: String?)] = [:]
        for source in sources {
            for entry in DeviceMachineGrouping.entries(machine: source.profile) {
                // entries() が実効マシンを spec へ焼き込んである(nil = 手元)
                if let machine = entry.machine, !registered.contains(machine) {
                    continue
                }
                // マシン名にタブは現れない(登録名は ssh 宛先ではなく識別子)ので区切りに使える
                let key = "\(entry.platform)\t\(DeviceMachineGrouping.display(entry.machine))\t\(entry.name)"
                let identity = identity(of: entry.spec)
                guard let kept = seen[key] else {
                    seen[key] = (source.name, identity)
                    result.append(entry)
                    continue
                }
                // **両方が実体を名乗っていて、それが違うときだけ** —— 片方が名前だけで書いて
                // いるのは同じ台の粗い記述なので黙る(誤検知を出さない側に倒す)
                if let identity, let keptIdentity = kept.identity, identity != keptIdentity {
                    conflicts.append(IdentityConflict(
                        platform: entry.platform,
                        machine: DeviceMachineGrouping.display(entry.machine),
                        name: entry.name,
                        keptProfile: kept.profile, keptIdentity: keptIdentity,
                        ignoredProfile: source.name, ignoredIdentity: identity))
                }
            }
        }
        return Merged(entries: result, conflicts: conflicts)
    }

    /// 同定に使う実体だけ(udid / avd / serial)。`simulator` / `os` は入れない ——
    /// 同じ台を粗く書いた台帳(serial だけ / serial + os)が食い違いに化ける
    private static func identity(of spec: DeviceSpec) -> String? {
        if let udid = spec.udid { return "udid \(udid)" }
        if let avd = spec.avd { return "avd \(avd)" }
        if let serial = spec.serial { return "serial \(serial)" }
        return nil
    }
}
