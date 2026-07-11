// QuietWaiter.java
// UI 整定(quiescence)検知。ホスト側の固定 sleep(操作後 800ms 等)の代替。
// UiAutomation.setOnAccessibilityEventListener を BridgeRouter 構築時に1回だけ登録し、
// 「対象パッケージ由来の最後の関連イベントから QUIET_MS 経過」を synchronized+wait/notify で
// 待つ(busy-wait・HTTP・snapshot ポーリングは一切しない。リスナ側が notify する)。
//
// クロスパッケージ遷移(例: 設定→Google サービスのような別パッケージへのハンドオフ)対応:
// TYPE_WINDOW_STATE_CHANGED イベントは送信元パッケージを問わず常に「関連イベント」として
// 静穏タイマーを延長し、かつ(除外パッケージでなければ)その瞬間に静穏対象を追従させる。
// これにより「タップ→旧画面の押下アニメ静穏→新ウィンドウ出現(追従)→新画面描画→静穏」が
// 1回の quietWait 呼び出しの中で自然に完結する(多段遷移(スプラッシュ→本画面)にも追従する)。
package com.example.ftbridge;

import android.os.SystemClock;
import android.view.accessibility.AccessibilityEvent;
import android.app.UiAutomation;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

final class QuietWaiter {

    /** 静穏しきい値(ms)。この時間、関連イベントが来なければ「整定した」とみなす。
     *  ベンチで調整するための定数(一箇所に集約)。 */
    static final long QUIET_MS = 200;
    /** /tap /type /swipe /press の静穏待ち上限(ms)。この時間で必ず抜ける。 */
    static final long ACTION_CAP_MS = 2000;

    /** ウィンドウ追従(静穏対象パッケージの切替)から除外するパッケージ。
     *  TYPE_WINDOW_STATE_CHANGED は送信元パッケージを問わず常に「関連イベント」として
     *  静穏タイマーは延長するが、これらのパッケージへは静穏対象を切り替えない
     *  (遷移先アプリそのものではなく、付随的に紛れ込むウィンドウのため)。
     *  実機E2E の logcat 観測で確認した上で追加すること。 */
    private static final Set<String> RETARGET_EXCLUDED_PACKAGES = new HashSet<>(Arrays.asList(
            "com.android.systemui"
    ));

    private final Object lock = new Object();
    /** 現在アクティブな quietWait() 呼び出しの静穏対象パッケージ(null なら全パッケージ関連)。
     *  quietWait() 開始時に呼び出し引数で設定し、TYPE_WINDOW_STATE_CHANGED イベントの送信元
     *  (除外パッケージでない場合)へ追従して書き換わる。ブリッジは単一スレッドなので同時に
     *  1回の quietWait() しか走らない(BridgeRouter 参照)。 */
    private String target;
    /** target(またはウィンドウ切替全般)に関する最後の関連イベントの uptimeMillis。未観測は 0 */
    private long lastRelevantEventMs = 0;

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
        boolean windowStateChanged =
                event.getEventType() == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED;
        long now = SystemClock.uptimeMillis();
        synchronized (lock) {
            if (windowStateChanged) {
                // ウィンドウ切替は送信元パッケージを問わず常に関連(静穏タイマーを延長)。
                // 除外パッケージでなければ、その瞬間に静穏対象をこのパッケージへ追従させる
                lastRelevantEventMs = now;
                if (pkg != null && !RETARGET_EXCLUDED_PACKAGES.contains(pkg)) {
                    target = pkg;
                }
                lock.notifyAll();
            } else if (target == null || target.equals(pkg)) {
                // それ以外のイベント種別は現在の対象パッケージ由来のときだけ関連
                // (対象未確定=null のときは全イベント関連)
                lastRelevantEventMs = now;
                lock.notifyAll();
            }
        }
    }

    /**
     * pkg(null なら全パッケージ)を初期の静穏対象として、最後の関連イベントから quietMs
     * 経過するまで待つ。呼び出し開始時刻も「関連イベント」の下限として扱う(注入直後は
     * まだイベントがリスナに届いていないことがあるため。副作用のない操作でも quietMs は
     * 必ず待つ = デバウンス)。静穏対象はクロスパッケージ遷移(TYPE_WINDOW_STATE_CHANGED)
     * を検知するたびに追従する(onEvent 参照)。capMs 経過したら整定未確認でも必ず抜ける
     * (呼び出し側が上限超過をエラーにしたい場合は別途チェックすること。quietWait 自体は
     * 例外を投げない)。
     */
    void quietWait(String pkg, long quietMs, long capMs) {
        long callStart = SystemClock.uptimeMillis();
        long deadline = callStart + Math.max(0, capMs);
        synchronized (lock) {
            target = pkg;
            while (true) {
                long last = Math.max(callStart, lastRelevantEventMs);
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
