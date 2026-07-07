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
    private int port = 8123;

    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        if (arguments != null && arguments.getString("port") != null) {
            port = Integer.parseInt(arguments.getString("port"));
        }
        start();
    }

    @Override
    public void onStart() {
        Log.i(TAG, "bridge starting on 127.0.0.1:" + port);
        BridgeRouter router = new BridgeRouter(this);
        // iOS ランナーと同じく逐次処理(1接続ずつ)。UI 操作が自然に直列化される。
        // finish() は呼ばない = 常駐(停止は am force-stop com.example.ftbridge)
        BridgeHttpServer.run(port, router);
        Log.i(TAG, "bridge stopped");
    }
}
