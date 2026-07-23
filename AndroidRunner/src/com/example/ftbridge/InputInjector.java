// InputInjector.java
// UiAutomation.injectInputEvent による MotionEvent 合成と、ACTION_SET_TEXT によるテキスト入力。
// adb input(呼び出し毎に app_process 起動 ~0.5s)と違いミリ秒オーダーで反応する。
package com.example.ftbridge;

import android.app.UiAutomation;
import android.graphics.Rect;
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
        // 過大値/NaN で単スレッドの accept スレッドを長時間ブロックしブリッジが無応答になるのを防ぐため
        // 0〜10s にクランプ(iOS 側 handlePress と同契約)。
        double clamped = Double.isFinite(durationSeconds) ? Math.min(Math.max(durationSeconds, 0), 10) : 0;
        long downTime = SystemClock.uptimeMillis();
        inject(ua, event(downTime, downTime, MotionEvent.ACTION_DOWN, x, y));
        SystemClock.sleep((long) (clamped * 1000));
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
     * タップした点(x,y)にある **editable ノードそのもの** へ追記する(ACTION_SET_TEXT は全置換
     * なので既存テキストと連結)。findFocus には依存しない:
     * - 「何かしらのフォーカス」待ち(v9)は、別フィールドが既にフォーカスを持つ場合に即通過して
     *   旧フィールドへ誤追記した(hello123secret42 事故)
     * - 「点を含むフォーカスノードへ注入」(v10/v11)でも再発した。Compose の a11y フォーカス報告は
     *   実フォーカスと非同期にずれることがあり、フォーカスノード経由である限り誤配のレースが残る
     * 点にあるノードを毎試行フレッシュに解決して直接 SET_TEXT するため、誤爆は構造的に起きない。
     * フォーカス到達を優先して待つが、期限の半分を過ぎたらフォーカス未報告でも対象ノードへ
     * SET_TEXT を試みる(SetText は semantics ノード直アクションでフォーカス必須ではない)。
     * 期限内に成功しなければ 500(他フィールドへは決して書かない)。
     */
    static void setTextAppendingAt(UiAutomation ua, double x, double y, String text, long timeoutMs) {
        long start = SystemClock.uptimeMillis();
        long deadline = start + timeoutMs;
        long focusGraceUntil = start + timeoutMs / 2;
        String lastState = "対象ノード未発見";
        Rect bounds = new Rect();
        while (true) {
            AccessibilityNodeInfo root = ua.getRootInActiveWindow();
            AccessibilityNodeInfo target = root == null ? null : editableAt(root, (int) x, (int) y, bounds);
            if (target != null) {
                boolean focused = target.isFocused();
                if (focused || SystemClock.uptimeMillis() >= focusGraceUntil) {
                    CharSequence existing = target.isShowingHintText() ? "" : target.getText();
                    String combined = (existing == null ? "" : existing.toString()) + text;
                    Bundle args = new Bundle();
                    args.putCharSequence(
                            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, combined);
                    if (target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                        return;
                    }
                    lastState = "SET_TEXT 拒否(input connection 未確立の可能性)";
                } else {
                    lastState = "対象ノードは未フォーカス";
                }
            }
            if (SystemClock.uptimeMillis() >= deadline) {
                throw new BridgeRouter.BridgeException(500,
                        "タップしたフィールドへ入力できませんでした(" + lastState + "、"
                        + timeoutMs + "ms 待機。他のフィールドへ誤入力しないため中止します)");
            }
            SystemClock.sleep(20);
        }
    }

    /** 点(x,y)を bounds に含む editable ノード(最深一致)。無ければ null。 */
    private static AccessibilityNodeInfo editableAt(AccessibilityNodeInfo root, int x, int y, Rect tmp) {
        AccessibilityNodeInfo best = null;
        java.util.ArrayDeque<AccessibilityNodeInfo> queue = new java.util.ArrayDeque<>();
        queue.add(root);
        while (!queue.isEmpty()) {
            AccessibilityNodeInfo node = queue.poll();
            if (node == null) continue;
            node.getBoundsInScreen(tmp);
            // 子は親の bounds に含まれるとは限らない(スクロール等)ため枝刈りはしない
            if (node.isEditable() && tmp.contains(x, y)) best = node;  // BFS 後勝ち = より深い一致
            for (int i = 0; i < node.getChildCount(); i++) queue.add(node.getChild(i));
        }
        return best;
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
