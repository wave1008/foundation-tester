// BridgeInstrumentation.java
// ftester の Android ブリッジ本体。iOS の XCUITest ランナー(FTesterBridgeTests)と対。
// 起動:
//   adb shell "am instrument -w -e port 8123 com.example.ftbridge/.BridgeInstrumentation \
//              </dev/null >/dev/null 2>&1 &"
// 重要: UiAutomationConnection は am プロセス側に生成されるため -w が必須。
// デバイス内でバックグラウンド化することで adb 切断後も常駐する(ホスト側プロセス不要)。
package com.example.ftbridge;

import android.app.Instrumentation;
import android.os.Bundle;
import android.util.Log;

public class BridgeInstrumentation extends Instrumentation {
    static final String TAG = "FTBridge";
    // 無通信 TTL の既定値(秒)。同期相手: Sources/FTCore/BridgeDTO.swift の
    // BridgeAPI.bridgeTTLSecondsDefault(AndroidBridgeVersionSyncTests が不一致を検出)
    static final int TTL_DEFAULT_SECONDS = 7200;
    /** 起動元リポジトリ(-e owner)。/status の ownerRepo として申告する(doctor の診断用)。
     *  未指定 = 申告しない(旧ホスト起動) */
    static String ownerRepo;
    /** 所要内訳ログ(tapTiming/settleTiming/reqTiming)を出すか。既定 false = 1行も出さない */
    static boolean timingEnabled;
    private int port = 8123;
    private int ttlSeconds = TTL_DEFAULT_SECONDS;

    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        if (arguments != null && arguments.getString("port") != null) {
            port = Integer.parseInt(arguments.getString("port"));
        }
        if (arguments != null) {
            ttlSeconds = parseTTL(arguments.getString("ttl"));
            ownerRepo = arguments.getString("owner");
            // 所要内訳ログの on/off(既定 off)。ホストの FT_BRIDGE_TIMING=1 が
            // `-e timing 1` として届く(同期相手: Sources/FTAndroid/AndroidBridge.swift)
            timingEnabled = "1".equals(arguments.getString("timing"));
        }
        start();
    }

    // Swift 側 BridgeAPI.resolvedBridgeTTLSeconds と同じ規則:
    // 0 = 無効(無期限)、未指定・非整数・負 = 既定値
    static int parseTTL(String raw) {
        if (raw == null) return TTL_DEFAULT_SECONDS;
        try {
            int value = Integer.parseInt(raw);
            return value >= 0 ? value : TTL_DEFAULT_SECONDS;
        } catch (NumberFormatException e) {
            return TTL_DEFAULT_SECONDS;
        }
    }

    @Override
    public void onStart() {
        Log.i(TAG, "bridge starting on 127.0.0.1:" + port
                + " ttl=" + (ttlSeconds > 0 ? ttlSeconds + "s" : "off"));
        BridgeRouter router = new BridgeRouter(this);
        // iOS ランナーと同じく逐次処理(1接続ずつ)。UI 操作が自然に直列化される。
        // finish() は呼ばない = 常駐(停止は am force-stop com.example.ftbridge、
        // または無通信 TTL の自主終了)
        BridgeHttpServer.run(port, ttlSeconds, router);
        // run が戻るのは TTL 満了かソケット死。onStart の return だけでは
        // プロセスが残る(サーバ無しのゾンビ)ため exit で確実に終わらせる
        Log.i(TAG, "bridge stopped");
        System.exit(0);
    }
}
