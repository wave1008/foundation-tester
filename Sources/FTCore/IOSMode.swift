// iOS のモード(実行プロファイルの `iosMode` / `devices[].mode`。ブリッジの種類とは別の語彙)。
// inapp = in-app ブリッジを主に使い、撃てない操作だけ XCUITest ブリッジへ回すハイブリッド構成 /
// xcuitest = XCUITest ブリッジだけ。in-app ブリッジ単独の構成は選べない

public enum IOSMode {
    public static let inapp = "inapp"
    public static let xcuitest = "xcuitest"
    public static let all: Set<String> = [inapp, xcuitest]
}
