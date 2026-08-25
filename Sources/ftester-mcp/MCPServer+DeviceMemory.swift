// MCPServer+DeviceMemory.swift
// 宛先(デバイス)の記憶(省略呼び出しへの適用)と、曖昧なときの拒否文言。本体は MCPServer.swift

import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    /// **ツールが device ターゲット(port/serial/udid)を受けるか**。schema 駆動(port または serial
    /// プロパティの有無)にしてあるので、ツール一覧を追加でメンテしなくても toolDefinitions と
    /// 自動的に揃う。**port だけでは見ない**: scope: .none で serial だけを個別宣言する
    /// ツール(ft_logs)が port を持たないため、port 単独判定だと fold から漏れて記憶が効かなかった。
    /// device を受けないツール(ft_doctor 等)へ記憶を適用すると、宛先と無関係な応答に
    /// 「この機を使い回しています」という誤解を招く注記が付く
    static func toolAcceptsDeviceTarget(_ tool: String) -> Bool {
        guard let definition = toolDefinitions.first(where: { $0["name"] as? String == tool }),
              let schema = definition["inputSchema"] as? [String: Any],
              let props = schema["properties"] as? [String: Any] else { return false }
        return props["port"] != nil || props["serial"] != nil
    }

    /// **省略呼び出しへ記憶した宛先を注入する**(dispatch 入口。call() 参照)。
    /// 条件は明示ターゲット述語(argsGaveIOSTarget/argsGaveAndroidTarget)と1本化してある ——
    /// ここだけ udid:"" を「指定あり」と誤読すると、記憶の適用だけが抑止されて記録は素通しする
    /// 非対称に戻る。**profile 指定時は触らない**(宛先はプロファイルが決める)。
    ///
    /// platform の決め方(2026-08-12・4欠陥修正): **udid/port か serial のどちらかが明示されて
    /// いれば、その platform だけを見る**(serial 明示に iOS の記憶を注入しない/逆も同じ)。
    /// **どちらも無ければ platform 引数 → 直近に明示された platform(lastExplicitPlatform)→
    /// 既定(ios)の順**で決める —— 契約は「udid, port, AND serial を全部省略したら同じデバイスへ」
    /// なので、Android を明示した直後の全省略呼び出しは Android の記憶へ行かなければならない
    /// (既定 "ios" に負けて iOS 分岐へ迷い込んでいた)。
    /// iOS 側は **port だけ注入し udid は注入しない**: udid を注入すると
    /// driver() の portForIOS → bridgePorts(forUDID:) が毎回 BridgeDiscovery.scan を強いられ、
    /// XCUITest quiescence(実測33.7秒)で busy なブリッジが scan に載らず reconcilePort が
    /// throw する(isBound による busy 救済が効くのは connectionLostHint の経路だけ)。
    /// 注入した呼び出しには `deviceFromMemoryKey` を立てる —— driver() 側の
    /// recordsIOSMemory/recordsAndroidMemory がこれを見て、自動注入を「利用者が選んだ」として
    /// 記憶を上書きしない(port 再利用で別デバイスに化けたときに記憶が黙って乗り換わるのを防ぐ)
    func foldInRememberedDevice(_ args: [String: Any]) -> RememberedDeviceFold {
        guard args["profile"] == nil else { return .unchanged }
        let explicitPlatform = args["platform"] as? String
        let platform: String
        if let explicitPlatform {
            platform = explicitPlatform
        } else if Self.argsGaveAndroidTarget(args) {
            platform = "android"
        } else if Self.argsGaveIOSTarget(args) {
            platform = "ios"
        } else {
            platform = lastExplicitPlatform ?? Self.platformName(args)
        }
        switch platform {
        case "ios":
            let iosOther = Self.platformWasInferred(args)
                && !seenExplicitAndroidSerials.isEmpty ? "Android" : nil
            guard let remembered = Self.iosExplicitWithMemory(
                argsGaveTarget: Self.argsGaveIOSTarget(args), remembered: lastExplicitIOSTarget)
            else {
                return lostTargetFold(gaveTarget: Self.argsGaveIOSTarget(args),
                                      everNamed: everNamedIOSTarget,
                                      survivors: seenExplicitIOSPorts.map(String.init),
                                      apply: { label in
                                          var out = args
                                          out["port"] = Int(label) ?? 0
                                          if explicitPlatform == nil { out["platform"] = "ios" }
                                          return out
                                      },
                                      deviceNoun: "iOS devices", unitNoun: "ports",
                                      otherPlatform: iosOther)
            }
            var out = args
            out["port"] = Int(remembered.port)
            if explicitPlatform == nil { out["platform"] = "ios" }
            // **ログは適用が決まってから**(2026-08-13 のレビュー指摘): 先に出すと、
            // 曖昧で拒否した呼び出しまで「その機へ行った」と読める痕跡を stderr に残す
            let iosFold = Self.finishingFold(out, chosen: "port \(remembered.port)",
                                      allSeenLabels: seenExplicitIOSPorts.map(String.init),
                                      deviceNoun: "iOS devices", unitNoun: "ports",
                                      otherPlatform: Self.platformWasInferred(args)
                                          && !seenExplicitAndroidSerials.isEmpty ? "Android" : nil,
                                      noteKey: "rememberedDevice:ios:\(remembered.port)",
                                      firstTime: firstTime)
            if case .applied = iosFold {
                Self.logStderr("no udid/port given — reusing this session's earlier target"
                    + " (port \(remembered.port), udid \(remembered.udid ?? "unknown"))")
            }
            return iosFold
        case "android":
            let androidOther = Self.platformWasInferred(args)
                && !seenExplicitIOSPorts.isEmpty ? "iOS" : nil
            guard let remembered = Self.androidExplicitWithMemory(
                argsGaveTarget: Self.argsGaveAndroidTarget(args), remembered: lastExplicitAndroidSerial)
            else {
                return lostTargetFold(gaveTarget: Self.argsGaveAndroidTarget(args),
                                      everNamed: everNamedAndroidTarget,
                                      survivors: Array(seenExplicitAndroidSerials),
                                      apply: { label in
                                          var out = args
                                          out["serial"] = label
                                          if explicitPlatform == nil { out["platform"] = "android" }
                                          return out
                                      },
                                      deviceNoun: "Android devices", unitNoun: "serials",
                                      otherPlatform: androidOther)
            }
            var out = args
            out["serial"] = remembered
            if explicitPlatform == nil { out["platform"] = "android" }
            let androidFold = Self.finishingFold(out, chosen: "serial \(remembered)",
                                      allSeenLabels: Array(seenExplicitAndroidSerials),
                                      deviceNoun: "Android devices", unitNoun: "serials",
                                      otherPlatform: Self.platformWasInferred(args)
                                          && !seenExplicitIOSPorts.isEmpty ? "iOS" : nil,
                                      noteKey: "rememberedDevice:android:\(remembered)",
                                      firstTime: firstTime)
            if case .applied = androidFold {
                Self.logStderr("no serial given — reusing this session's earlier Android target"
                    + " (serial \(remembered))")
            }
            return androidFold
        default:
            return .unchanged
        }
    }

    /// 記憶した宛先が**失敗で消えた後**の省略呼び出し(2026-08-13 の監査。セッションの形 = OS 跨ぎ)。
    ///
    /// **実測した事故**: ①port 8138 を明示して成功 → ②存在しない port 8999 を明示して失敗 →
    /// ③宛先を省いた呼び出しが、**8138 でも 8999 でもない別のシミュレータ**(ホーム画面が返った)
    /// へ黙って行った。記憶は**解決時**に書かれるので ② が 8138 を 8999 で上書きし、
    /// 失敗の後始末(`forgetConnection`)が 8999 を消して**記憶を空にする**。空になると
    /// 「まだ1台も指していない新しいセッション」と同じ扱いになり、`resolveIOSPort(explicit: nil)`
    /// = **ブリッジ探索**へ落ちて、このセッションが一度も名指ししていない機を拾う。
    /// 曖昧さのガードは記憶を見るので、記憶が空ではそもそも働かない。
    ///
    /// 規則: **一度でも宛先を名指ししたセッションでは、省略呼び出しを探索へ落とさない**。
    /// 生き残りが1つならそこへ戻し(= ③ は 8138 へ行く)、0 か複数なら断る。
    func lostTargetFold(gaveTarget: Bool, everNamed: Bool, survivors: [String],
                        apply: (String) -> [String: Any],
                        deviceNoun: String, unitNoun: String,
                        otherPlatform: String?) -> RememberedDeviceFold {
        guard !gaveTarget, everNamed else { return .unchanged }
        // **「候補が2台以上」はここで数えない** —— 曖昧さの判定は `isAmbiguousMemory` の1箇所に
        // あり、下の `finishingFold` が同じ規則で断る。ここで先に数えると規則が2箇所になり、
        // しかも**片方を壊しても何も落ちない**(変異で実証した)
        guard let survivor = survivors.first else {
            return .ambiguous(message: Self.lostTargetRefusal(
                survivors: survivors, deviceNoun: deviceNoun, unitNoun: unitNoun,
                otherPlatform: otherPlatform))
        }
        return Self.finishingFold(apply(survivor), chosen: "\(unitNoun.dropLast()) \(survivor)",
                                  allSeenLabels: survivors, deviceNoun: deviceNoun,
                                  unitNoun: unitNoun, otherPlatform: otherPlatform,
                                  noteKey: "lostTarget:\(deviceNoun):\(survivor)",
                                  firstTime: firstTime)
    }

    /// `lostTargetFold` が断るときの文。**探索へ落ちない理由を言う** —— 「見つからない」とだけ
    /// 返すと、読み手は宛先を渡すのではなくブリッジを建て直しにいく
    static func lostTargetRefusal(survivors: [String], deviceNoun: String, unitNoun: String,
                                  otherPlatform: String?) -> String {
        let sorted = survivors.sorted()
        let left = sorted.isEmpty
            ? " The \(deviceNoun) this session had targeted are no longer reachable."
            : " This session still has \(sorted.count) reachable \(unitNoun)"
                + " (\(sorted.prefix(rememberedDeviceListCap).joined(separator: ", ")))."
        let crossed = otherPlatform.map {
            " This session has also driven \($0), and no platform was given either."
        } ?? ""
        return "no udid/port/serial given, and this session's earlier target is gone.\(left)\(crossed)"
            + " Refusing to fall back to whichever bridge happens to be running: that would operate"
            + " a device you never named, and unlike a bad answer that is not something you can take"
            + " back. Pass udid or port (iOS) / serial (Android) to say which."
    }

    /// `foldInRememberedDevice` の結果。**曖昧なら適用せず拒否する**。
    /// 以前は「2台以上を触っていたら毎回注記しつつ直近の1台へ流す」だったが、
    /// **注記は事故を1件も止めなかった** —— 監査19(serial だけの呼び出しが黙って iOS へ)・
    /// 監査20(キャッシュ命中で記憶が更新されない)・udid 2台の記憶混線は**3件とも
    /// 「2台以上を触ったセッション」でだけ起きている**。逆に1台しか触っていないセッションは
    /// 原理的に外しようがないので、そこは従来どおり黙って適用してよい。
    /// 「記憶が安全なのは、それが一意なときちょうど」が規則の本体
    enum RememberedDeviceFold {
        case unchanged
        case applied(args: [String: Any], note: String)
        /// 宛先が一意に決まらない省略呼び出し。**推測せず call() が MCPError にする**
        case ambiguous(message: String)
    }

    /// 記憶した宛先が一意でないか。**判定はここ1箇所**(注記側と拒否側で条件がずれると、
    /// 「注記は出さないが拒否はする」のような食い違いが生まれる)
    static func isAmbiguousMemory(allSeenLabels: [String], otherPlatform: String?) -> Bool {
        allSeenLabels.count >= 2 || otherPlatform != nil
    }

    /// 曖昧な省略呼び出しを断る文(純粋関数。デバイスも走査も要らない)。
    /// **候補を名指しする** —— 断るだけだと読み手は何を渡せばよいか分からず、
    /// 総当たりで udid を試して結局どれかの機を操作することになる。
    /// 上限は `rememberedDeviceListCap`(注記側と同じ。超えたら件数だけ)
    static func rememberedDeviceRefusal(
        allSeenLabels: [String], deviceNoun: String, unitNoun: String, otherPlatform: String?
    ) -> String {
        let sorted = allSeenLabels.sorted()
        var driven = ""
        if sorted.count >= 2 {
            let list = sorted.count > rememberedDeviceListCap
                ? "\(sorted.count) \(unitNoun)"
                : "\(unitNoun) \(sorted.joined(separator: ", "))"
            driven = " This session has driven \(sorted.count) \(deviceNoun) (\(list))."
        }
        let crossed = otherPlatform.map {
            " This session has also driven \($0), and no platform was given either."
        } ?? ""
        return "no udid/port/serial given, and the target is not unique.\(driven)\(crossed)"
            + " Refusing to guess: picking the most recently used device silently would run this"
            + " on the wrong one, and unlike a bad answer that is not something you can take back."
            + " Pass udid or port (iOS) / serial (Android) to say which."
            + " (While only one device had been targeted, it was reused automatically.)"
    }

    /// **platform 自体が推測されたか**(= 呼び出しが platform も宛先も1つも渡していない)。
    /// この形だけが `lastExplicitPlatform` に落ちるので、両 platform を触っていれば
    /// 「どちらの機へ行くか」自体が曖昧になる。platform か宛先のどちらかが明示されていれば
    /// 行き先の platform は確定しているので、跨ぎの曖昧さは無い
    static func platformWasInferred(_ args: [String: Any]) -> Bool {
        args["platform"] as? String == nil
            && !argsGaveAndroidTarget(args) && !argsGaveIOSTarget(args)
    }

    /// 名指しする候補の上限本数。超えたら一覧を並べず件数だけ言う(rememberedDeviceNote)
    static let rememberedDeviceListCap = 6

    /// 省略呼び出しへ記憶した宛先を注入したときの注記の本文(純粋関数。デバイスも走査も要らない)。
    /// **ここへ来るのは宛先が一意なときだけ** —— 曖昧な形は `rememberedDeviceRefusal` が
    /// 断るので、この文が「どちらへ行ったか分からない」状況を説明することはもう無い。
    ///
    /// - `chosen`: 実際に注入した宛先の表示形("port 8123" / "serial emulator-5554")
    /// - `firstTime`: セッションで初回だけ出す(同じ1台を使い続ける間、毎回言う価値は無い)
    static func rememberedDeviceNote(chosen: String, firstTime: Bool) -> String {
        guard firstTime else { return "" }
        return "(reusing this session's earlier device: \(chosen)"
            + " — pass udid/port/serial to target another)\n"
    }
}
