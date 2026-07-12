// dylib ロード時に Swift 側エントリを呼ぶだけの構成子。
// Swift のトップレベル初期化は遅延評価のため、確実に走らせる起点として ObjC constructor を使う。
// FTInAppBridgeStart は InAppBridge.swift の @_cdecl。

extern void FTInAppBridgeStart(void);

__attribute__((constructor))
static void ft_inapp_bridge_boot(void) {
    FTInAppBridgeStart();
}
