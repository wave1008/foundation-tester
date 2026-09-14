// Android の .apk を読んで UI フレームワークとパッケージ名を決める(材料を読むだけ。
// **問い合わせの口は AppUIFrameworkQuery**)。Android のブリッジは自己申告を持たないので、答えは静的な材料だけ。
//
// 目印(2026-09-14 に E2E の SUT 4 つの APK で実測。パッケージ名は aapt2 dump packagename と突き合わせ済み):
//   flutter     … lib/<abi>/libflutter.so
//   reactNative … lib/<abi>/libreactnative.so(0.76 以降)/ libreactnativejni.so(それ以前)/
//                 assets/index.android.bundle(release)
//   compose     … dex に androidx.compose.ui.platform.AndroidComposeView がある。**「Compose を含む」であって
//                 全画面が Compose とは限らない**(View/XML の画面に Compose を混ぜた E2EAppAndroid もこちら)
//   androidView … どれも無い
// 順は flutter → reactNative → compose(Compose を同梱していても描画の本体は前2者)。.aab は読まない

import Foundation

public enum AndroidPackageInspector {
    /// 規則の版。**目印・順序を変えたら上げる**(UIFrameworkMarkers.rulesVersion と同じ役目)
    public static let rulesVersion = 1

    static let abis = ["arm64-v8a", "armeabi-v7a", "x86_64", "x86"]
    static let flutterLibraries = ["libflutter.so"]
    static let reactNativeLibraries = ["libreactnative.so", "libreactnativejni.so"]
    static let reactNativeBundle = "assets/index.android.bundle"
    static let composeDexClass = "Landroidx/compose/ui/platform/AndroidComposeView;"

    /// exists: zip 直下からの相対パスの実在 / dexContains: classes*.dex のどれかにバイト列があるか(要るときだけ呼ぶ)
    public static func framework(exists: (String) -> Bool, dexContains: (String) -> Bool) -> AppUIFramework {
        func hasLibrary(_ names: [String]) -> Bool {
            abis.contains { abi in names.contains { exists("lib/\(abi)/\($0)") } }
        }
        if hasLibrary(flutterLibraries) { return .flutter }
        if hasLibrary(reactNativeLibraries) || exists(reactNativeBundle) { return .reactNative }
        if dexContains(composeDexClass) { return .compose }
        return .androidView
    }

    static func detect(in reader: AppPackageReader) -> AppUIFramework {
        let dexes = reader.rootEntries().filter { $0.hasPrefix("classes") && $0.hasSuffix(".dex") }.sorted()
        return framework(exists: reader.exists,
                         dexContains: { needle in dexes.contains { reader.contains(needle, in: $0) == true } })
    }

    /// AndroidManifest.xml(バイナリ XML)の `<manifest package=…>`(ビルド済み APK では applicationId)。
    /// 読めなければ nil
    static func packageName(in reader: AppPackageReader) -> String? {
        reader.contents("AndroidManifest.xml").flatMap(manifestPackage(axml:))
    }

    /// バイナリ XML(ResXMLTree)から、最初の要素 `manifest` の属性 `package` の値を読む純粋関数。
    /// 構造: ResChunk_header(type u16, headerSize u16, size u32)の連なり。文字列は ResStringPool
    /// (flags の 0x100 = UTF-8、無ければ UTF-16LE)、要素は RES_XML_START_ELEMENT(0x0102)の属性表
    static func manifestPackage(axml data: Data) -> String? {
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int? {
            o >= 0 && o + 2 <= bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : nil
        }
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        func stringPool(at start: Int) -> [String]? {
            guard let headerSize = u16(start + 2), let count = u32(start + 8), count < 1_000_000,
                  let flags = u32(start + 16), let stringsStart = u32(start + 20) else { return nil }
            let utf8 = flags & 0x100 != 0
            var result: [String] = []
            for index in 0..<count {
                guard let relative = u32(start + headerSize + index * 4) else { return nil }
                var p = start + stringsStart + relative
                if utf8 {
                    // UTF-16 での長さ(1〜2 バイト)→ UTF-8 での長さ(1〜2 バイト)→ 本体
                    guard p < bytes.count else { return nil }
                    p += bytes[p] & 0x80 != 0 ? 2 : 1
                    guard p + 1 < bytes.count else { return nil }
                    var length = Int(bytes[p])
                    if length & 0x80 != 0 { length = (length & 0x7F) << 8 | Int(bytes[p + 1]); p += 2 } else { p += 1 }
                    guard p + length <= bytes.count else { return nil }
                    result.append(String(decoding: bytes[p..<p + length], as: UTF8.self))
                } else {
                    guard var length = u16(p) else { return nil }
                    p += 2
                    if length & 0x8000 != 0 {
                        guard let low = u16(p) else { return nil }
                        length = (length & 0x7FFF) << 16 | low
                        p += 2
                    }
                    guard p + length * 2 <= bytes.count else { return nil }
                    let units = (0..<length).map { UInt16(bytes[p + 2 * $0]) | UInt16(bytes[p + 2 * $0 + 1]) << 8 }
                    result.append(String(decoding: units, as: UTF16.self))
                }
            }
            return result
        }

        guard u16(0) == 0x0003, var offset = u16(2) else { return nil }
        var strings: [String] = []
        while let type = u16(offset), let chunkHeaderSize = u16(offset + 2), let size = u32(offset + 4),
              size >= 8, offset + size <= bytes.count {
            if type == 0x0001 {
                strings = stringPool(at: offset) ?? []
            } else if type == 0x0102 {
                let ext = offset + chunkHeaderSize
                guard let name = u32(ext + 4), name < strings.count, strings[name] == "manifest",
                      let attributeStart = u16(ext + 8), let attributeSize = u16(ext + 10),
                      let attributeCount = u16(ext + 12) else { return nil }
                for index in 0..<attributeCount {
                    let attribute = ext + attributeStart + index * attributeSize
                    guard let attributeName = u32(attribute + 4), let raw = u32(attribute + 8) else { return nil }
                    guard attributeName < strings.count, strings[attributeName] == "package" else { continue }
                    if raw < strings.count { return strings[raw] }
                    // 生の文字列が無い形: Res_value(size u16, res0 u8, dataType u8 = 0x03 文字列, data u32)
                    if attribute + 15 < bytes.count, bytes[attribute + 15] == 0x03,
                       let value = u32(attribute + 16), value < strings.count {
                        return strings[value]
                    }
                    return nil
                }
                return nil
            }
            offset += size
        }
        return nil
    }
}
