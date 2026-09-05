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
        String lastState = "target node not found";
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
                            rejectMaskedAppend(masked, current);
                            combined = current + text;
                        }
                        Bundle args = new Bundle();
                        args.putCharSequence(
                                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, combined);
                        if (target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                            if (firstFireAt == 0) firstFireAt = SystemClock.uptimeMillis();
                            lastState = focused ? "ACTION_SET_TEXT was accepted but the value did not change"
                                                : "ACTION_SET_TEXT on an unfocused field did not take effect";
                            if (!focused) blindFired = true;
                        } else {
                            lastState = "ACTION_SET_TEXT refused (the input connection may not be established yet)";
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
                        lastState = "not focused (requesting focus with ACTION_CLICK)";
                    }
                }
            } catch (BridgeRouter.BridgeException e) {
                throw e;   // 撃たずに弾いた判断(rejectMaskedAppend 等)は再試行の対象ではない
            } catch (RuntimeException e) {
                // レイアウト変化中のノードは内部で NPE 等を投げる → 次周回で取り直す
                lastState = "the node became stale (" + e.getClass().getSimpleName() + ")";
            }
            if (SystemClock.uptimeMillis() >= deadline) {
                throw new BridgeRouter.BridgeException(500,
                        "cannot type into the field that was tapped (" + lastState + ", "
                        + timeoutMs + "ms waited; giving up rather than typing into the wrong field)");
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
        if (!ua.injectInputEvent(e, true)) {
            // 口が死んでいれば 503 + exit(BridgeRouter.assertConnectionAlive)。生きていて拒否なら 500
            BridgeRouter.assertConnectionAlive(ua);
            throw new BridgeRouter.BridgeException(500, "injectInputEvent (key) was refused");
        }
    }

    /**
     * **中身のあるマスク欄への追記は撃たずに弾く**(2026-08-06 に実害を観測)。
     *
     * 追記は `既存の読み + text` を SET_TEXT で書き戻す形だが、**パスワード欄の読みは伏せ字**
     * (`••••`)なので、そのまま書き戻すと**伏せ字そのものが本文になる**。
     * 実測: 空欄へ "abc" → 続けて "def" で、アプリ側の echo が `•••def` になった。
     * ツールは "Typed" と成功を返すため、値が壊れたことは後段の検証まで分からない。
     *
     * setTextAppendingAt の「combined を**作り直す**と伏せ字を書く」規律は**初回構築にも効く**。
     * 読める術が無い以上ここは追記できない —— 置換したいなら呼び手が先に clearInput する
     * (それは冪等で安全)。空欄への1回目は `current` が "" なので通る。
     */
    private static void rejectMaskedAppend(boolean masked, String current) {
        if (!masked || current.isEmpty()) return;
        throw new BridgeRouter.BridgeException(422,
                "cannot append to a password field (its value reads back masked, so appending would write the mask "
                + "as real text). Call clearInput first if you meant to replace it");
    }

    /** 適用確認。マスク欄(パスワード)は読みが伏せ字になるため長さ一致で見る */
    private static boolean applied(String current, String combined, boolean masked) {
        if (combined.equals(current)) return true;
        return masked && current.length() == combined.length();
    }

    /**
     * resource-id(短縮形)優先でノードを探す。**id は画面内で一意とは限らない**
     * (Google マップの時刻ピッカーで時/分の EditText が同じ id を持つ)ので、一致が
     * 複数あるときは**先頭を採らず ref の座標で選び分ける**。1件目を採ると ref で指した欄と
     * 別の欄を操作する(実測: 分を clear したら時が消えた)。
     * 選び分けは「点を含む → 中心が最も近い」の順: **座標そのものへは落とさない** ——
     * IME の開閉でダイアログが数百 px 動くので、点一致だけだと "target node not found" になる。
     * setTextAppendingAt/clearTextAt の両方がここを通るので分岐を2箇所に書かない。
     */
    private static AccessibilityNodeInfo findEditable(AccessibilityNodeInfo root, String shortId,
                                                      int x, int y, Rect tmp) {
        if (shortId != null) {
            java.util.List<AccessibilityNodeInfo> matches = new java.util.ArrayList<>();
            AccessibilityNodeInfo containing = collectEditableById(root, shortId, x, y, tmp, matches);
            if (containing != null) return containing;
            if (matches.size() == 1) return matches.get(0);
            if (matches.size() > 1) return nearest(matches, x, y, tmp);
        }
        return editableAt(root, x, y, tmp);
    }

    /**
     * 同じ id の候補から ref の点で中心が最も近いものを選ぶ。**包含一致は collectEditableById
     * が走査中に確定して返す**ので、ここに来る候補はいずれも点を含まない(判定軸はここでは
     * 中心距離だけ)。
     */
    private static AccessibilityNodeInfo nearest(java.util.List<AccessibilityNodeInfo> matches,
                                                 int x, int y, Rect tmp) {
        AccessibilityNodeInfo best = null;
        double bestDistance = Double.MAX_VALUE;
        for (AccessibilityNodeInfo node : matches) {
            node.getBoundsInScreen(tmp);
            double dx = tmp.centerX() - x;
            double dy = tmp.centerY() - y;
            double distance = dx * dx + dy * dy;
            if (distance < bestDistance) {
                bestDistance = distance;
                best = node;
            }
        }
        return best;
    }

    /**
     * 短縮 resource-id が一致する editable ノードを集める(SnapshotBuilder.shortResourceId
     * と同じ規則)。**点 (x,y) を含む一致は走査中に確定してその場で返す**(件数上限と無関係。
     * 一致が何件並んでいても対象は必ず見つかる)。含む一致が最後まで無かったときは
     * nearest() が matches 全件から中心距離で選ぶので、**matches の収集数に上限を付けない**
     * ——IME の開閉でダイアログが数百 px 動き点がどの欄にも乗らないケースがあり、上限を切ると
     * 対象が上限より後ろにあるとき別の欄を選んでしまう。
     */
    private static AccessibilityNodeInfo collectEditableById(AccessibilityNodeInfo node, String shortId,
                                            int x, int y, Rect tmp, java.util.List<AccessibilityNodeInfo> matches) {
        if (node == null) return null;
        String id = node.getViewIdResourceName();
        if (id != null && node.isEditable()) {
            int idx = id.indexOf("id/");
            String shortened = idx >= 0 ? id.substring(idx + 3) : id;
            if (shortId.equals(shortened)) {
                node.getBoundsInScreen(tmp);
                if (tmp.contains(x, y)) return node;
                matches.add(node);
            }
        }
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo found = collectEditableById(node.getChild(i), shortId, x, y, tmp, matches);
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
        String lastState = "target node not found";
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
                            lastState = focused ? "ACTION_SET_TEXT was accepted but the value is still there"
                                                : "ACTION_SET_TEXT on an unfocused field did not take effect";
                            if (!focused) blindFired = true;
                        } else {
                            lastState = "ACTION_SET_TEXT refused (the input connection may not be established yet)";
                        }
                    } else if (!focused && SystemClock.uptimeMillis() - lastClickAt >= 200) {
                        if (!target.isVisibleToUser()) {
                            target.performAction(AccessibilityNodeInfo.AccessibilityAction
                                    .ACTION_SHOW_ON_SCREEN.getId(), null);
                        }
                        target.performAction(AccessibilityNodeInfo.ACTION_CLICK);
                        lastClickAt = SystemClock.uptimeMillis();
                        lastState = "not focused (requesting focus with ACTION_CLICK)";
                    }
                }
            } catch (BridgeRouter.BridgeException e) {
                throw e;   // 撃たずに弾いた判断は再試行の対象ではない(上のコメント参照)
            } catch (RuntimeException e) {
                lastState = "the node became stale (" + e.getClass().getSimpleName() + ")";
            }
            if (SystemClock.uptimeMillis() >= deadline) {
                throw new BridgeRouter.BridgeException(409,
                        "cannot clear the field that was tapped (" + lastState + ", "
                        + timeoutMs + "ms waited)");
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
        String lastState = "no-input-focus: nothing has input focus (tap the field by ref first)";
        String combined = null;
        boolean masked = false;
        while (true) {
            try {
                AccessibilityNodeInfo root = SnapshotBuilder.waitForRoot(ua, 500);
                // 入れ物へ倒れた findFocus から combined を作ると空読み + 拒否で 2 秒待って 500
                // (focusedEditable の doc)
                AccessibilityNodeInfo focus = root == null ? null : focusedEditable(root);
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
                        rejectMaskedAppend(masked, current);
                        combined = current + text;
                    }
                    Bundle args = new Bundle();
                    args.putCharSequence(
                            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, combined);
                    if (focus.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                        lastState = "ACTION_SET_TEXT was accepted but the value did not change";
                    } else {
                        lastState = "this field does not accept ACTION_SET_TEXT (a WebView, for example)";
                    }
                }
            } catch (BridgeRouter.BridgeException e) {
                throw e;   // 撃たずに弾いた判断は再試行の対象ではない(上のコメント参照)
            } catch (RuntimeException e) {
                lastState = "the node became stale (" + e.getClass().getSimpleName() + ")";
            }
            if (SystemClock.uptimeMillis() >= deadline) {
                throw new BridgeRouter.BridgeException(500, lastState + "(2000ms waited)");
            }
            SystemClock.sleep(20);
        }
    }

    /**
     * 入力フォーカスを持つ**編集可能な**ノード(ref なしの clear / IME Enter の対象)。
     * `findFocus(FOCUS_INPUT)` は Flutter で半分の確率でフォーカス中の欄ではなく FlutterView の
     * 入れ物(FrameLayout・editable=false・text=null・子 1 つ)を返す(実機 Pixel 4a・2026-09-06 の
     * logcat プローブ。Flutter の a11y ブリッジが入力フォーカスのセマンティクスノードを持って
     * いない瞬間は、フレームワークがフォーカスを持つ View 自体へ倒す)。入れ物を「空」と読めば
     * 黙って成功、SET_TEXT を撃てば拒否(409)になる —— 10 周中 5 周がこれだった。
     * 編集可能でなければ木から `isFocused && isEditable` を探し、無ければ null
     * (呼び手が期限まで引き直す)。
     */
    private static AccessibilityNodeInfo focusedEditable(AccessibilityNodeInfo root) {
        AccessibilityNodeInfo focus = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        if (focus != null && focus.isEditable()) return focus;
        return findFocusedEditable(root);
    }

    private static AccessibilityNodeInfo findFocusedEditable(AccessibilityNodeInfo node) {
        if (node == null) return null;
        if (node.isEditable() && node.isFocused()) return node;
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo hit = findFocusedEditable(node.getChild(i));
            if (hit != null) return hit;
        }
        return null;
    }

    /**
     * フォーカス中の入力欄を空文字へ全置換する(/clear の ref なし経路)。
     * **ref あり(clearTextAt)と同じ再試行の規律**: フォーカスは毎回引き直し、読む前に refresh、
     * 空を読めたら成功(ACTION_SET_TEXT の true は受理であって反映ではない)、期限まで撃ち直す。
     * 1 発の performAction の false をそのまま 409 にしていた版は、Flutter のパスワード欄で
     * 2 回に 1 回落ちた(実機 Pixel 4a・2026-09-05。直前の type は通っているので入力欄は生きて
     * いる = 一瞬の拒否を確定失敗にしていた)。
     * 対象なし/期限切れは 409(setTextAppending の 500 とは意図的に異なる。
     * BridgeDTO.ClearRequest の記載どおりホストの typeDriver フォールバックの合図とする)。
     */
    static void clearFocused(UiAutomation ua, long timeoutMs) {
        long deadline = SystemClock.uptimeMillis() + timeoutMs;
        String lastState = "no-input-focus: nothing has input focus (tap the field by ref first)";
        while (true) {
            try {
                AccessibilityNodeInfo root = ua.getRootInActiveWindow();
                AccessibilityNodeInfo focus = root == null ? null : focusedEditable(root);
                if (focus != null) {
                    focus.refresh();   // 読む前に取り直す(clearTextAt と同じ理由)
                    CharSequence remaining = focus.isShowingHintText() ? "" : focus.getText();
                    if (remaining == null || remaining.length() == 0) {
                        return;
                    }
                    Bundle args = new Bundle();
                    args.putCharSequence(
                            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "");
                    lastState = focus.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                            ? "ACTION_SET_TEXT was accepted but the value is still there"
                            : "this field does not accept ACTION_SET_TEXT (a WebView, for example)";
                }
            } catch (RuntimeException e) {
                lastState = "the node became stale (" + e.getClass().getSimpleName() + ")";
            }
            if (SystemClock.uptimeMillis() >= deadline) {
                throw new BridgeRouter.BridgeException(409, lastState + " (" + timeoutMs + "ms waited)");
            }
            SystemClock.sleep(20);
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
        // 入れ物へ倒れた findFocus に ACTION_IME_ENTER を撃つと必ず失敗する(focusedEditable の doc)
        AccessibilityNodeInfo focus = root == null ? null : focusedEditable(root);
        if (focus == null) {
            throw new BridgeRouter.BridgeException(409,
                    "no-input-focus: nothing has input focus (tap the field by ref first)");
        }
        // ホストがキーイベント経路へフォールバックできるよう、失敗は 409 で返す(500 にしない)
        if (!focus.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.getId())) {
            throw new BridgeRouter.BridgeException(409, "the IME Enter action could not be performed");
        }
    }

    /**
     * ダブルタップ。2回のタップは**同じ downTime を共有しない**(別ストローク)が、
     * GestureDetector は「1回目の UP から DOUBLE_TAP_TIMEOUT(既定 300ms)以内の DOWN」を
     * ダブルタップと見なすので、間隔は固定 60ms にする。**ホストから2回 /tap を撃つ形にはできない**
     * (HTTP の往復だけで 300ms を超えることがあり、単タップ2回に化ける)。
     * 座標は動かさない(タップスロップを超えると別ジェスチャになる)。
     */
    static void doubleTap(UiAutomation ua, double x, double y) {
        tap(ua, x, y);
        SystemClock.sleep(60);
        tap(ua, x, y);
    }

    /**
     * 2本指のピンチ。(centerX, centerY) を中心に、対角線上へ startSpan → endSpan まで
     * 2点を同時に動かす(span = 2点間の距離)。
     *
     * 規律:
     * - **ACTION_POINTER_DOWN/UP は pointer index を action へ埋める**(<< 8)。埋め忘れると
     *   1本目の指の DOWN として解釈され、ピンチにならない
     * - **MOVE は必ず2点ぶんの座標を1イベントに載せる**(2本のストロークを交互に注入する形だと
     *   ScaleGestureDetector が距離変化を取れない)
     * - 45度方向へ開く(水平だと横スクロール、垂直だと縦スクロールと競合しやすい)
     */
    static void pinch(UiAutomation ua, double centerX, double centerY,
                      double startSpan, double endSpan, long durationMs) {
        double axis = Math.sqrt(0.5);   // 45度: 各軸への射影は span/2 * cos45
        long downTime = SystemClock.uptimeMillis();
        double[] a = new double[]{centerX - startSpan / 2 * axis, centerY - startSpan / 2 * axis};
        double[] b = new double[]{centerX + startSpan / 2 * axis, centerY + startSpan / 2 * axis};
        inject(ua, event(downTime, downTime, MotionEvent.ACTION_DOWN, a[0], a[1]));
        inject(ua, multiEvent(downTime, downTime,
                MotionEvent.ACTION_POINTER_DOWN | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                a, b));
        int steps = Math.max(1, (int) (durationMs / 16));
        for (int i = 1; i <= steps; i++) {
            double t = (double) i / steps;
            double span = startSpan + (endSpan - startSpan) * t;
            double[] p1 = new double[]{centerX - span / 2 * axis, centerY - span / 2 * axis};
            double[] p2 = new double[]{centerX + span / 2 * axis, centerY + span / 2 * axis};
            inject(ua, multiEvent(downTime, downTime + (long) (t * durationMs),
                    MotionEvent.ACTION_MOVE, p1, p2));
            SystemClock.sleep(16);
        }
        double[] e1 = new double[]{centerX - endSpan / 2 * axis, centerY - endSpan / 2 * axis};
        double[] e2 = new double[]{centerX + endSpan / 2 * axis, centerY + endSpan / 2 * axis};
        long upTime = downTime + durationMs;
        inject(ua, multiEvent(downTime, upTime,
                MotionEvent.ACTION_POINTER_UP | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                e1, e2));
        inject(ua, event(downTime, upTime, MotionEvent.ACTION_UP, e1[0], e1[1]));
    }

    /** 2点ぶんの座標を載せた MotionEvent(pointer id は 0 と 1 固定) */
    private static MotionEvent multiEvent(long downTime, long eventTime, int action,
                                          double[] p1, double[] p2) {
        MotionEvent.PointerProperties[] props = new MotionEvent.PointerProperties[2];
        MotionEvent.PointerCoords[] coords = new MotionEvent.PointerCoords[2];
        double[][] points = new double[][]{p1, p2};
        for (int i = 0; i < 2; i++) {
            MotionEvent.PointerProperties p = new MotionEvent.PointerProperties();
            p.id = i;
            p.toolType = MotionEvent.TOOL_TYPE_FINGER;
            props[i] = p;
            MotionEvent.PointerCoords c = new MotionEvent.PointerCoords();
            c.x = (float) points[i][0];
            c.y = (float) points[i][1];
            c.pressure = 1;
            c.size = 1;
            coords[i] = c;
        }
        MotionEvent e = MotionEvent.obtain(downTime, eventTime, action, 2, props, coords,
                0, 0, 1, 1, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
        return e;
    }

    private static MotionEvent event(long downTime, long eventTime, int action, double x, double y) {
        MotionEvent e = MotionEvent.obtain(downTime, eventTime, action, (float) x, (float) y, 0);
        e.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        return e;
    }

    private static void inject(UiAutomation ua, MotionEvent e) {
        try {
            if (!ua.injectInputEvent(e, true)) {
                // 口が死んでいれば 503 + exit(BridgeRouter.assertConnectionAlive)。生きていて拒否なら 500
                BridgeRouter.assertConnectionAlive(ua);
                throw new BridgeRouter.BridgeException(500, "injectInputEvent was refused");
            }
        } finally {
            e.recycle();
        }
    }
}
