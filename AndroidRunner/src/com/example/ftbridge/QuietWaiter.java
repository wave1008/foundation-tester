// QuietWaiter.java
// UI 整定(quiescence)検知。ホスト側の固定 sleep(操作後 800ms 等)の代替。
// UiAutomation.setOnAccessibilityEventListener を BridgeRouter 構築時に1回だけ登録し、
// 「対象パッケージ由来の最後の関連イベントから QUIET_MS 経過」を synchronized+wait/notify で
// 待つ(busy-wait・HTTP・snapshot ポーリングは一切しない。リスナ側が notify する)。
package com.example.ftbridge;

import android.os.SystemClock;
import android.view.accessibility.AccessibilityEvent;
import android.app.UiAutomation;

import java.util.HashMap;
import java.util.Map;

final class QuietWaiter {

    /** 静穏しきい値(ms)。この時間、関連イベントが来なければ「整定した」とみなす。
     *  ベンチで調整するための定数(一箇所に集約)。 */
    static final long QUIET_MS = 200;
    /** /tap /type /swipe /press の静穏待ち上限(ms)。この時間で必ず抜ける。 */
    static final long ACTION_CAP_MS = 2000;

    private final Object lock = new Object();
    /** パッケージ名 → 最後に観測した関連イベントの uptimeMillis。未観測は 0 扱い */
    private final Map<String, Long> lastEventByPackage = new HashMap<>();
    /** パッケージを問わない直近イベントの uptimeMillis(pkg==null クエリ用) */
    private long lastEventAny = 0;

    /** BridgeRouter 構築時に UiAutomation へ1回だけ渡すリスナ。
     *  javac -source/-target 8 + android.jar 単独 bootclasspath ではメソッド参照/ラムダが
     *  LambdaMetafactory 未解決でコンパイルできない(build.sh 参照)ため匿名クラスで書く */
    UiAutomation.OnAccessibilityEventListener listener() {
        return new UiAutomation.OnAccessibilityEventListener() {
            @Override
            public void onAccessibilityEvent(AccessibilityEvent event) {
                onEvent(event);
            }
        };
    }

    private void onEvent(AccessibilityEvent event) {
        CharSequence pkgSeq = event.getPackageName();
        String pkg = pkgSeq == null ? null : pkgSeq.toString();
        long now = SystemClock.uptimeMillis();
        synchronized (lock) {
            lastEventAny = now;
            if (pkg != null) lastEventByPackage.put(pkg, now);
            lock.notifyAll();
        }
    }

    /**
     * pkg(null なら全パッケージ)由来の最後の関連イベントから quietMs 経過するまで待つ。
     * 呼び出し開始時刻も「関連イベント」の下限として扱う(注入直後はまだイベントが
     * リスナに届いていないことがあるため。副作用のない操作でも quietMs は必ず待つ =
     * デバウンス)。capMs 経過したら整定未確認でも必ず抜ける(呼び出し側が上限超過を
     * エラーにしたい場合は別途チェックすること。quietWait 自体は例外を投げない)。
     */
    void quietWait(String pkg, long quietMs, long capMs) {
        long callStart = SystemClock.uptimeMillis();
        long deadline = callStart + Math.max(0, capMs);
        synchronized (lock) {
            while (true) {
                long last = Math.max(callStart,
                        pkg == null ? lastEventAny : lastEventByPackage.getOrDefault(pkg, 0L));
                long now = SystemClock.uptimeMillis();
                long quietElapsed = now - last;
                if (quietElapsed >= quietMs) return;
                long remaining = deadline - now;
                if (remaining <= 0) return;
                long waitFor = Math.min(quietMs - quietElapsed, remaining);
                try {
                    lock.wait(Math.max(1, waitFor));
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        }
    }
}
