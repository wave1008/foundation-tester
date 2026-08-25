package com.example.ftbridge;

import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Choreographer;

/**
 * 画面が「進んでいるか」を計る計器(/status の displayIdleSeconds)。
 *
 * <p><b>ホストは凍結判定に使わない。採り直さないこと</b> —— 「静止画面(tick あり)と wedge
 * (tick なし)を画像なしで分離できる」という前提は iOS 側で反証されている(wedge 中でも
 * vsync コールバックは来る。実測は docs/verification.md)。計器を残してあるのは、撤去が
 * ブリッジ版上げ = 全台の建て直しを伴うため(次の版上げに便乗する)。
 *
 * <p>iOS 側の対(InAppBridge/Sources/DisplayHeartbeat.swift と Runner/.../DisplayHeartbeat.swift)。
 * **片方だけ変えない**。
 *
 * <p><b>交絡の注意</b>: 表示を触り続ける処理そのものが凍結を緩和しうる。発生条件の対照実験では
 * この計器の有無を条件間で必ず揃えること。
 */
final class DisplayHeartbeat {
    private static final Object LOCK = new Object();
    /** 最後に vsync コールバックが来た時刻(SystemClock.uptimeMillis)。0 = 未着 */
    private static long lastTickMs = 0;
    /** start() を呼んだ時刻。1回も来ていない間の基準 */
    private static long startedAtMs = 0;
    private static boolean started = false;

    private DisplayHeartbeat() {}

    /**
     * メインルーパー上で自分自身を再登録し続ける。**postFrameCallback は1回ぶんしか効かない**ので、
     * コールバックの中で必ず次を登録する(ここを落とすと1回で止まり、恒久的に「凍結」を申告する)。
     */
    static void start() {
        synchronized (LOCK) {
            if (started) return;
            started = true;
            startedAtMs = SystemClock.uptimeMillis();
        }
        new Handler(Looper.getMainLooper()).post(new Runnable() {
            @Override public void run() {
                Choreographer.getInstance().postFrameCallback(new Choreographer.FrameCallback() {
                    @Override public void doFrame(long frameTimeNanos) {
                        synchronized (LOCK) { lastTickMs = SystemClock.uptimeMillis(); }
                        Choreographer.getInstance().postFrameCallback(this);
                    }
                });
            }
        });
    }

    /**
     * 最後に画面が進んでからの秒数。計器が動いていなければ負値を返し、呼び出し側は申告しない。
     */
    static double idleSeconds() {
        synchronized (LOCK) {
            if (!started) return -1;
            long base = lastTickMs > 0 ? lastTickMs : startedAtMs;
            return Math.max(0, (SystemClock.uptimeMillis() - base) / 1000.0);
        }
    }
}
