// A11yCacheStalenessGuard.swift
// キャッシュを迂回して読み直した(`refresh=1`)後の素取得が、読み直す前の古い木を返していないかの判定(純粋)。
//
// ブリッジの読み直しは各ノードを `refresh()` するだけでキャッシュを更新しない。Compose は親の配置だけがずれた変化
// (縮むヘッダ)を a11y のイベントで知らせないので、次の素取得が払う前の木を返し続け、探索の直後のタップが
// 黙って別の行に当たった(E2EY-CMP の折りたたみヘッダ。Pixel 3a・API 32 で 4/4)。ブリッジ v86 は API 34+ で
// `clearCache()` するが、34 未満はここで受ける。
//
// 規則: 読み直したら、その木の署名を控える(疑う)。疑っている間の素取得は控えと比べ、
// - 一致 → その木を使い、疑いを解く(追加の読みは無し)
// - 不一致 → 読み直して確かめる。読み直しが素取得と一致すれば画面が正当に変わっただけ(疑いを解く)、
//   一致しなければキャッシュが古い(読み直しの木を使い、控えを差し替えて疑い続ける)
// 費用は「疑っていて、かつ画面が変わった」素取得の1回ぶんだけ(API 34+ では読み直しで捨てたキャッシュから
// 素取得が作り直されるので、最初の素取得で一致して解ける)

import FTCore

struct A11yCacheStalenessGuard {
    /// 直近の読み直しの木の署名。nil = 疑っていない
    private(set) var lastRefreshedSignature: String?

    mutating func noteRefreshed(_ signature: String) {
        lastRefreshedSignature = signature
    }

    /// 素取得の木を確かめるために読み直すべきか(一致すれば疑いを解く)
    mutating func plainReadNeedsConfirmation(_ signature: String) -> Bool {
        guard let last = lastRefreshedSignature else { return false }
        if signature == last {
            lastRefreshedSignature = nil
            return false
        }
        return true
    }

    /// 確かめの読み直しの結果。true = 素取得の木は古かった(読み直しの木を使う)
    mutating func confirm(plain: String, refreshed: String) -> Bool {
        if plain == refreshed {
            lastRefreshedSignature = nil
            return false
        }
        lastRefreshedSignature = refreshed
        return true
    }

    /// 比べる署名。座標・文言・状態が同じなら同じ木(ref は読みごとに振り直されるので含めない)
    static func signature(_ elements: [ElementInfo]) -> String {
        var text = ""
        text.reserveCapacity(elements.count * 48)
        for element in elements {
            let frame = element.frame
            text += "\(element.type)|\(element.identifier ?? "")|\(element.label ?? "")"
            text += "|\(element.value ?? "")|\(element.enabled)|\(element.checked ?? false)"
            text += "|\(Int(frame.x)),\(Int(frame.y)),\(Int(frame.width)),\(Int(frame.height));"
        }
        return text
    }
}
