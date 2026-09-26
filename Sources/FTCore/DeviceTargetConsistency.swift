// platform 引数と宛先引数(iOS: udid/port・Android: serial)の食い違いを1箇所で判定する。
// MCP(fleetest-mcp)と CLI(fleetest)が共有する——別々に持つと同じ食い違いが片方でだけ弾かれる。
// **判定だけを持つ**(CLAUDE.md「共有するのは判定であって文言ではない」)——呼び手ごとに
// 引数名(MCP: udid/port/serial・CLI: --udid/--port/--serial)で文言を組む。
public enum DeviceTargetConsistency {

    public enum Mismatch: Equatable {
        /// platform が明示されていない状態で、iOS の宛先と Android の宛先が両方与えられた
        case bothPlatformsTargeted
        /// platform=ios なのに Android の宛先(serial)も与えられた
        case iosPlatformWithAndroidTarget
        /// platform=android なのに iOS の宛先(udid/port)も与えられた
        case androidPlatformWithIOSTarget
    }

    /// **空文字は「与えられていない」として扱う**——呼び手側(MCP の argsGaveIOSTarget/
    /// argsGaveAndroidTarget・CLI の Optional 未設定)が既にその判定をした上でここへ渡すこと。
    /// platform が ios/android のどちらでもない(省略・無効値)ときは、両方の宛先が
    /// 与えられている場合だけ「どちらへ行くか分からない」として食い違いにする
    public static func mismatch(
        platform: String?, gaveIOSTarget: Bool, gaveAndroidTarget: Bool
    ) -> Mismatch? {
        switch platform {
        case "ios":
            return gaveAndroidTarget ? .iosPlatformWithAndroidTarget : nil
        case "android":
            return gaveIOSTarget ? .androidPlatformWithIOSTarget : nil
        default:
            return gaveIOSTarget && gaveAndroidTarget ? .bothPlatformsTargeted : nil
        }
    }

    /// platform 省略時の既定。**Android の宛先(serial)だけが与えられたら android、それ以外は ios**。
    /// `platform ?? "ios"` に倒すと `--serial emulator-5554` だけの呼び出しが既定ポートの iOS の台
    /// (別の台)を操作する。MCP の `MCPServer.platformName` と同じ推定(片方だけ変えない)
    public static func defaultPlatform(explicit: String?, gaveIOSTarget: Bool, gaveAndroidTarget: Bool) -> String {
        if let explicit { return explicit }
        return gaveAndroidTarget && !gaveIOSTarget ? "android" : "ios"
    }
}
