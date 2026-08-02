// InputInjector.java
// UiAutomation.injectInputEvent による MotionEvent 合成と、ACTION_SET_TEXT によるテキスト入力。
// adb input(呼び出し毎に app_process 起動 ~0.5s)と違いミリ秒オーダーで反応する。
package com.example.ftbridge;

import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;

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

    /**
     * syntheticUpTime=true のとき ACTION_UP の eventTime を MOVE と同じ合成時刻
     * (downTime + durationMs)にする。**false(実時計)だと sleep(16) とイベント注入の
     * オーバーヘッドぶん UP が遅れ、VelocityTracker が「最後は止まっていた」と読んで
     * フリングが出ない** —— 飛距離が指の移動距離を下回る(実測 969px 動かして 690px)。
     * ストロークを短くするほど悪化し、150ms では [120, 780, 105, 714, 120] と
     * 「UP が間に合うか」のレースになる。**View/Compose だけの現象で Flutter は影響を受けない**。
     *
     * 既定を true にしていないのは、探索(scrollTo)の1回の移動量がビューポート高を超えると
     * 要素を飛び越すため。用途ごとの使い分けは FTCore/BridgeDTO の FTSwipeIntent を見ること
     */
    static void swipe(UiAutomation ua, double fromX, double fromY, double toX, double toY,
                      long durationMs, boolean syntheticUpTime) {
        long downTime = SystemClock.uptimeMillis();
        inject(ua, event(downTime, downTime, MotionEvent.ACTION_DOWN, fromX, fromY));
        int steps = Math.max(1, (int) (durationMs / 16));
        for (int i = 1; i <= steps; i++) {
            double t = (double) i / steps;
            inject(ua, event(downTime, downTime + (long) (t * durationMs), MotionEvent.ACTION_MOVE,
                    fromX + (toX - fromX) * t, fromY + (toY - fromY) * t));
            SystemClock.sleep(16);
        }
        long upTime = syntheticUpTime ? downTime + durationMs : SystemClock.uptimeMillis();
        inject(ua, event(downTime, upTime, MotionEvent.ACTION_UP, toX, toY));
    }

    /**
     * タップした点(x,y)にある editable ノードへ追記する。追跡は resource-id 優先
     * (shortId が null のときだけ点)。**キーボードの開閉で adjustResize が走ると座標は
     * 当てにならない**ため、点だけを頼ると別ノードに化ける。
     *
     * 規律(2026-07-31 の実測から。破ると値が壊れる):
     * - **combined は最初の確定読みから1回だけ作る**。再発火は常に同じ値(構造的に冪等)。
     *   後の読みから作り直すと、パスワード欄のマスク文字列を値として書き込む・遅延適用と
     *   重なって二重追記する(どちらも実害を観測した)
     * - **SET_TEXT はフォーカスが立っているときだけ撃つ**。未フォーカスの Compose 欄は
     *   受理(true)しても反映しない。立たないときは座標でなく ACTION_CLICK で立て直す
     *   (座標ズレと無縁)。猶予後の未フォーカス発火は最後の1回だけ・検証付き
     * - **パスワード欄の読みはマスクされる**ので、適用確認は長さ一致で行う
     * - performAction / ノード読みは try/catch で「取り直し」に変換する(レイアウト変化中の
     *   ノードは内部で NPE を投げる。ACTION_FOCUS 事件と同じ機構)
     * 期限内に確認できなければ 500(他フィールドへは決して書かない)。
     */
    static void setTextAppendingAt(UiAutomation ua, double x, double y, String shortId,
                                   String text, long timeoutMs) {
        long start = SystemClock.uptimeMillis();
        long deadline = start + timeoutMs;
        long focusGraceUntil = start + timeoutMs / 2;
        long lastClickAt = 0;
        long firstFireAt = 0;         // 最初に SET_TEXT を受理させた時刻(未反映の張り直し判定用)
        String lastState = "対象ノード未発見";
        String combined = null;       // 最初の確定読みから1回だけ作る(上記の規律)
        boolean masked = false;
        boolean blindFired = false;   // 猶予後の未フォーカス発火は1回だけ
        Rect bounds = new Rect();
        while (true) {
            try {
                AccessibilityNodeInfo root = ua.getRootInActiveWindow();
                AccessibilityNodeInfo target = root == null ? null
                        : findEditable(root, shortId, (int) x, (int) y, bounds);
                if (target != null) {
                    // **読む前に必ず取り直す**。a11y ノードはキャッシュから供給され、とくに
                    // WebView(Chromium)は DOM 変更のイベントを遅れて出すため、取り直さないと
                    // getText() が**変更前の値を返し続ける**(SnapshotBuilder.collect の
                    // insideWebView refresh と同じ事情・同じ対策)。これが無いと
                    // 「SET_TEXT は効いているのに読みが古く、期限切れで 500」になる
                    // (2026-07-31 実測: WebView 入力欄で 20%。値は実際には入っていた)。
                    // 1ノード1 IPC。通常経路は 1〜2 周で終わるのでコストは無視できる
                    target.refresh();
                    CharSequence existing = target.isShowingHintText() ? "" : target.getText();
                    String current = existing == null ? "" : existing.toString();
                    if (combined != null && applied(current, combined, masked)) {
                        return;
                    }
                    boolean focused = target.isFocused();
                    // フォーカス済みでも受理→未反映が続くことがある(高負荷で観測)。原因は
                    // **前のアプリインスタンスに紐づいた IME セッションの残留**で、focused でも
                    // semantic action が捨てられる。700ms 反映されなければ IME を閉じて
                    // (BACK。IME window が見えているときだけ = 画面を戻さない)最新 bounds の
                    // 中心を実タップし、セッションを張り直す。ACTION_CLICK では張り直らない(実測)
                    if (focused && firstFireAt != 0
                            && SystemClock.uptimeMillis() - firstFireAt >= 700
                            && SystemClock.uptimeMillis() - lastClickAt >= 700) {
                        reconnectInput(ua, target);
                        lastClickAt = SystemClock.uptimeMillis();
                        firstFireAt = 0;
                    }
                    if (focused || (SystemClock.uptimeMillis() >= focusGraceUntil && !blindFired)) {
                        if (combined == null) {
                            masked = target.isPassword();
                            combined = current + text;
                        }
                        Bundle args = new Bundle();
                        args.putCharSequence(
                                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, combined);
                        if (target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                            if (firstFireAt == 0) firstFireAt = SystemClock.uptimeMillis();
                            lastState = focused ? "SET_TEXT は受理されたが値が反映されない"
                                                : "未フォーカスの SET_TEXT が反映されない";
                            if (!focused) blindFired = true;
                        } else {
                            lastState = "SET_TEXT 拒否(input connection 未確立の可能性)";
                        }
                    } else if (!focused && SystemClock.uptimeMillis() - lastClickAt >= 200) {
                        // フォーカスが立たない(タップがキーボードに吸われた等)。ACTION_CLICK は
                        // ノード直アクションなので座標ズレと無縁にフォーカスを要求できる
                        if (!target.isVisibleToUser()) {
                            target.performAction(AccessibilityNodeInfo.AccessibilityAction
                                    .ACTION_SHOW_ON_SCREEN.getId(), null);
                        }
                        target.performAction(AccessibilityNodeInfo.ACTION_CLICK);
                        lastClickAt = SystemClock.uptimeMillis();
                        lastState = "未フォーカス(ACTION_CLICK でフォーカス要求中)";
                    }
                }
            } catch (RuntimeException e) {
                // レイアウト変化中のノードは内部で NPE 等を投げる → 次周回で取り直す
                lastState = "ノードが無効化された(" + e.getClass().getSimpleName() + ")";
            }
            if (SystemClock.uptimeMillis() >= deadline) {
                throw new BridgeRouter.BridgeException(500,
                        "タップしたフィールドへ入力できませんでした(" + lastState + "、"
                        + timeoutMs + "ms 待機。他のフィールドへ誤入力しないため中止します)");
            }
            SystemClock.sleep(20);
        }
    }

    /**
     * 腐った input connection の張り直し: IME window が**見えているときだけ** BACK で閉じ
     * (見えていないのに撃つと画面が戻る)、対象の**最新 bounds** の中心を実タップする。
     * 残留 IME セッション(前のアプリインスタンス由来)は ACTION_CLICK では張り直らない(実測)。
     */
    private static void reconnectInput(UiAutomation ua, AccessibilityNodeInfo target) {
        if (imeWindowVisible(ua)) {
            long downTime = SystemClock.uptimeMillis();
            injectKey(ua, new KeyEvent(downTime, downTime, KeyEvent.ACTION_DOWN,
                    KeyEvent.KEYCODE_BACK, 0));
            injectKey(ua, new KeyEvent(downTime, SystemClock.uptimeMillis(),
                    KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK, 0));
            SystemClock.sleep(150);
        }
        target.refresh();   // BACK 直後は IME 折り畳みでレイアウトが動く → bounds を取り直す
        Rect fresh = new Rect();
        target.getBoundsInScreen(fresh);
        tap(ua, fresh.exactCenterX(), fresh.exactCenterY());
    }

    private static boolean imeWindowVisible(UiAutomation ua) {
        for (AccessibilityWindowInfo w : ua.getWindows()) {
            if (w.getType() == AccessibilityWindowInfo.TYPE_INPUT_METHOD) return true;
        }
        return false;
    }

    private static void injectKey(UiAutomation ua, KeyEvent e) {
        ua.injectInputEvent(e, true);
    }

    /** 適用確認。マスク欄(パスワード)は読みが伏せ字になるため長さ一致で見る */
    private static boolean applied(String current, String combined, boolean masked) {
        if (combined.equals(current)) return true;
        return masked && current.length() == combined.length();
    }

    /** resource-id(短縮形)優先でノードを探す。id が無い/見つからないときだけ点で探す */
    private static AccessibilityNodeInfo findEditable(AccessibilityNodeInfo root, String shortId,
                                                      int x, int y, Rect tmp) {
        if (shortId != null) {
            AccessibilityNodeInfo byId = editableById(root, shortId);
            if (byId != null) return byId;
        }
        return editableAt(root, x, y, tmp);
    }

    /** 短縮 resource-id が一致する editable ノード(SnapshotBuilder.shortResourceId と同じ規則) */
    private static AccessibilityNodeInfo editableById(AccessibilityNodeInfo node, String shortId) {
        if (node == null) return null;
        String id = node.getViewIdResourceName();
        if (id != null && node.isEditable()) {
            int idx = id.indexOf("id/");
            String shortened = idx >= 0 ? id.substring(idx + 3) : id;
            if (shortId.equals(shortened)) return node;
        }
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo found = editableById(node.getChild(i), shortId);
            if (found != null) return found;
        }
        return null;
    }

    /**
     * タップした点(x,y)にある editable ノードを空文字へ全置換する(/clear の ref 経路)。
     * 追跡・フォーカスゲート・try/catch の規律は setTextAppendingAt と同一(そちらのコメント参照)。
     * 空への置換は冪等なので combined の1回構築は不要。マスク欄も「空」の読みは "" になる。
     * 期限内に確認できなければ 409(ホストの typeDriver フォールバックの合図。
     * setTextAppendingAt の 500 とは意図的に異なる)。
     */
    static void clearTextAt(UiAutomation ua, double x, double y, String shortId, long timeoutMs) {
        long start = SystemClock.uptimeMillis();
        long deadline = start + timeoutMs;
        long focusGraceUntil = start + timeoutMs / 2;
        long lastClickAt = 0;
        long firstFireAt = 0;
        String lastState = "対象ノード未発見";
        boolean blindFired = false;
        Rect bounds = new Rect();
        while (true) {
            try {
                AccessibilityNodeInfo root = ua.getRootInActiveWindow();
                AccessibilityNodeInfo target = root == null ? null
                        : findEditable(root, shortId, (int) x, (int) y, bounds);
                if (target != null) {
                    // 読む前に取り直す(理由は setTextAppendingAt の同じ位置のコメント)。
                    // **この経路の破損は再現していない**(2026-07-31 に refresh 有無で A/B: どちらも
                    // 40/40 成功)。それでも入れるのは、ここの失敗モードが**沈黙**だから ——
                    // 古い空文字を読むと「消えていないのに成功」を返し、後段の別の検証まで
                    // 行かないと分からない。type/フォーカス経路と形を揃える意味もある。コストは
                    // 1ノード1 IPC(A/B の実測差 317ms 対 328ms = 誤差)
                    target.refresh();
                    CharSequence remaining = target.isShowingHintText() ? "" : target.getText();
                    if (remaining == null || remaining.length() == 0) {
                        return;
                    }
                    boolean focused = target.isFocused();
                    if (focused && firstFireAt != 0
                            && SystemClock.uptimeMillis() - firstFireAt >= 700
                            && SystemClock.uptimeMillis() - lastClickAt >= 700) {
                        reconnectInput(ua, target);   // setTextAppendingAt と同じ張り直し
                        lastClickAt = SystemClock.uptimeMillis();
                        firstFireAt = 0;
                    }
                    if (focused || (SystemClock.uptimeMillis() >= focusGraceUntil && !blindFired)) {
                        Bundle args = new Bundle();
                        args.putCharSequence(
                                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "");
                        if (target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                            if (firstFireAt == 0) firstFireAt = SystemClock.uptimeMillis();
                            lastState = focused ? "SET_TEXT は受理されたが値が残っている"
                                                : "未フォーカスの SET_TEXT が反映されない";
                            if (!focused) blindFired = true;
                        } else {
                            lastState = "SET_TEXT 拒否(input connection 未確立の可能性)";
                        }
                    } else if (!focused && SystemClock.uptimeMillis() - lastClickAt >= 200) {
                        if (!target.isVisibleToUser()) {
                            target.performAction(AccessibilityNodeInfo.AccessibilityAction
                                    .ACTION_SHOW_ON_SCREEN.getId(), null);
                        }
                        target.performAction(AccessibilityNodeInfo.ACTION_CLICK);
                        lastClickAt = SystemClock.uptimeMillis();
                        lastState = "未フォーカス(ACTION_CLICK でフォーカス要求中)";
                    }
                }
            } catch (RuntimeException e) {
                lastState = "ノードが無効化された(" + e.getClass().getSimpleName() + ")";
            }
            if (SystemClock.uptimeMillis() >= deadline) {
                throw new BridgeRouter.BridgeException(409,
                        "タップしたフィールドをクリアできませんでした(" + lastState + "、"
                        + timeoutMs + "ms 待機)");
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
     * フォーカス中の入力欄へ追記する(/type の ref なし経路)。
     * combined の1回構築・マスク長さ判定・try/catch は setTextAppendingAt と同じ規律
     * (そちらのコメント参照。読みから作り直すとマスク文字列の書き込み・二重追記になる)。
     */
    static void setTextAppending(UiAutomation ua, String text) {
        long deadline = SystemClock.uptimeMillis() + 2000;
        String lastState = "入力フォーカスを持つ要素がありません(先に ref 指定でタップしてください)";
        String combined = null;
        boolean masked = false;
        while (true) {
            try {
                AccessibilityNodeInfo root = SnapshotBuilder.waitForRoot(ua, 500);
                AccessibilityNodeInfo focus = root == null ? null
                        : root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
                if (focus != null) {
                    // 読む前に取り直す(理由は setTextAppendingAt の同じ位置のコメント)
                    focus.refresh();
                    CharSequence existing = focus.isShowingHintText() ? "" : focus.getText();
                    String current = existing == null ? "" : existing.toString();
                    if (combined != null && applied(current, combined, masked)) {
                        return;
                    }
                    if (combined == null) {
                        masked = focus.isPassword();
                        combined = current + text;
                    }
                    Bundle args = new Bundle();
                    args.putCharSequence(
                            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, combined);
                    if (focus.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                        lastState = "SET_TEXT は受理されたが値が反映されない";
                    } else {
                        lastState = "ACTION_SET_TEXT を受け付けないフィールドです(WebView 等)";
                    }
                }
            } catch (RuntimeException e) {
                lastState = "ノードが無効化された(" + e.getClass().getSimpleName() + ")";
            }
            if (SystemClock.uptimeMillis() >= deadline) {
                throw new BridgeRouter.BridgeException(500, lastState + "(2000ms 待機)");
            }
            SystemClock.sleep(20);
        }
    }

    /**
     * フォーカス中の入力欄を空文字へ全置換する(/clear の ref なし経路)。
     * 対象なし/SET_TEXT 拒否は 409(setTextAppending の 500 とは意図的に異なる。
     * BridgeDTO.ClearRequest の記載どおりホストの typeDriver フォールバックの合図とする)。
     */
    static void clearFocused(UiAutomation ua) {
        AccessibilityNodeInfo root = SnapshotBuilder.waitForRoot(ua, 2000);
        AccessibilityNodeInfo focus = root == null ? null
                : root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        if (focus == null) {
            throw new BridgeRouter.BridgeException(409,
                    "入力フォーカスを持つ要素がありません(先に ref 指定でタップしてください)");
        }
        Bundle args = new Bundle();
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "");
        if (!focus.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
            throw new BridgeRouter.BridgeException(409,
                    "ACTION_SET_TEXT を受け付けないフィールドです(WebView 等)");
        }
    }

    /**
     * フォーカス中の入力欄へ IME の「実行」アクションを直接発火する(ACTION_IME_ENTER、API 30+)。
     * keyevent 66 はソフトキーボード表示中の View/XML EditText では IME に吸われ
     * OnEditorActionListener に届かない(Compose は独自のキーイベント処理経路のため keyevent でも
     * 発火する。実機実測で確認済み)。呼び出し元 BridgeRouter が API レベルを判定してから呼ぶこと
     * (この関数自体は SDK_INT を見ない)。
     */
    static void pressImeEnter(UiAutomation ua) {
        AccessibilityNodeInfo root = SnapshotBuilder.waitForRoot(ua, 2000);
        AccessibilityNodeInfo focus = root == null ? null
                : root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        if (focus == null) {
            throw new BridgeRouter.BridgeException(409,
                    "入力フォーカスを持つ要素がありません(先に ref 指定でタップしてください)");
        }
        // ホストがキーイベント経路へフォールバックできるよう、失敗は 409 で返す(500 にしない)
        if (!focus.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.getId())) {
            throw new BridgeRouter.BridgeException(409, "IME の Enter アクションを実行できませんでした");
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
