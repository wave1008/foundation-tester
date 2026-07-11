// InputInjector.java
// UiAutomation.injectInputEvent による MotionEvent 合成と、ACTION_SET_TEXT によるテキスト入力。
// adb input(呼び出し毎に app_process 起動 ~0.5s)と違いミリ秒オーダーで反応する。
package com.example.ftbridge;

import android.app.UiAutomation;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityNodeInfo;

final class InputInjector {

    private InputInjector() {}

    static void tap(UiAutomation ua, double x, double y) {
        long downTime = SystemClock.uptimeMillis();
        inject(ua, event(downTime, downTime, MotionEvent.ACTION_DOWN, x, y));
        inject(ua, event(downTime, SystemClock.uptimeMillis() + 20, MotionEvent.ACTION_UP, x, y));
    }

    static void press(UiAutomation ua, double x, double y, double durationSeconds) {
        long downTime = SystemClock.uptimeMillis();
        inject(ua, event(downTime, downTime, MotionEvent.ACTION_DOWN, x, y));
        SystemClock.sleep((long) (durationSeconds * 1000));
        inject(ua, event(downTime, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y));
    }

    static void swipe(UiAutomation ua, double fromX, double fromY, double toX, double toY,
                      long durationMs) {
        long downTime = SystemClock.uptimeMillis();
        inject(ua, event(downTime, downTime, MotionEvent.ACTION_DOWN, fromX, fromY));
        int steps = Math.max(1, (int) (durationMs / 16));
        for (int i = 1; i <= steps; i++) {
            double t = (double) i / steps;
            inject(ua, event(downTime, downTime + (long) (t * durationMs), MotionEvent.ACTION_MOVE,
                    fromX + (toX - fromX) * t, fromY + (toY - fromY) * t));
            SystemClock.sleep(16);
        }
        inject(ua, event(downTime, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, toX, toY));
    }

    /**
     * フォーカス中の入力要素(FOCUS_INPUT)が現れるまで待つ(ref タップ直後、フォーカス反映の
     * ラグ対策。固定 sleep(500) の代替)。in-process の短間隔チェックのみ(50ms 粒度以下。
     * HTTP/snapshot ポーリングではない)。見つからないまま timeoutMs 経過しても例外は投げない
     * (最終判定は setTextAppending 側の findFocus に委ねる)。
     */
    static void waitForFocusInput(UiAutomation ua, long timeoutMs) {
        long deadline = SystemClock.uptimeMillis() + timeoutMs;
        while (true) {
            AccessibilityNodeInfo root = ua.getRootInActiveWindow();
            AccessibilityNodeInfo focus = root == null ? null
                    : root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
            if (focus != null) return;
            if (SystemClock.uptimeMillis() >= deadline) return;
            SystemClock.sleep(20);
        }
    }

    /**
     * フォーカス中の入力フィールドへ追記する(iOS の typeText / adb input text と同じ追記意味論)。
     * ACTION_SET_TEXT は全置換なので既存テキストと連結して渡す。日本語などの非 ASCII も入る。
     */
    static void setTextAppending(UiAutomation ua, String text) {
        AccessibilityNodeInfo root = SnapshotBuilder.waitForRoot(ua, 2000);
        AccessibilityNodeInfo focus = root == null ? null
                : root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        if (focus == null) {
            throw new BridgeRouter.BridgeException(500,
                    "入力フォーカスを持つ要素がありません(先に ref 指定でタップしてください)");
        }
        CharSequence existing = focus.isShowingHintText() ? "" : focus.getText();
        String combined = (existing == null ? "" : existing.toString()) + text;
        Bundle args = new Bundle();
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, combined);
        if (!focus.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
            throw new BridgeRouter.BridgeException(500,
                    "ACTION_SET_TEXT を受け付けないフィールドです(WebView 等)");
        }
    }

    private static MotionEvent event(long downTime, long eventTime, int action, double x, double y) {
        MotionEvent e = MotionEvent.obtain(downTime, eventTime, action, (float) x, (float) y, 0);
        e.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        return e;
    }

    private static void inject(UiAutomation ua, MotionEvent e) {
        try {
            if (!ua.injectInputEvent(e, true)) {
                throw new BridgeRouter.BridgeException(500, "injectInputEvent が拒否されました");
            }
        } finally {
            e.recycle();
        }
    }
}
