package com.example.ftbridge;

import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Choreographer;

/**
 * 画面が「進んでいるか」を計る計器(/status の displayIdleSeconds)。
 *
 * <p>凍結の判定はこれまで「絵が一様(白/黒ベタ)か」という代理指標だけだった。これは blank 型しか
 * 捕まえず、**最後のフレームが残る固着型**(sleep/wake で ~4s 修復できるあの型)は非一様なので
 * 原理的に当たらない。Choreographer のフレームコールバックは vsync 由来なので、**画面の中身が
 * 変わらなくても呼ばれる** —— 静止画面(tick あり)と表示スタックの wedge(tick なし)を、
 * 画像を一切見ずに分離できる。
 *
 * <p>iOS 側の対(InAppBridge/Sources/DisplayHeartbeat.swift と Runner/.../DisplayHeartbeat.swift)。
 * **片方だけ変えない** —— しきい値の意味が OS で割れるとホストの判定が別物になる。
 *
 * <p><b>未検証</b>(2026-08-11): この wedge のときに本当に止まるかは実測前。ホストは
 * FrozenEvidence.noPresent を単独では確定根拠にしない(警告のみ)。
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
