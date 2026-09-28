// Gboard が「その言語のキーボードを最初に出したとき」に1度だけ出す入力レイアウトの選択シート
// (日本語なら「ひらがな 入力レイアウトの選択 / 12 キー・QWERTY / スキップ・次へ」)を、
// **アプリを起動する前に**出して閉じておく。
//
// Wipe Data の直後・作りたての AVD では、最初のテキスト入力でこのシートがキーボードと画面の下半分を覆い、
// 入力欄の下に出る候補が隠れる(tap が「見つからない」で落ちる)・Flutter の欄へ文字が入らない。
// シートは1度出たら答えなくても次からは出ないので、症状は「Wipe した台の最初の1本だけ赤」になる。
//
// **入力の経路(handleType)では閉じない**: 閉じるのを待つ間に欄がキーボードに押されて動き、
// InputInjector が tap した座標で欄を見失う(Flutter で実測: target node not found)。
// だから自前の空の画面(KeyboardPrimerActivity)でキーボードを出して先に済ませる。
//
// 済ませた印はブリッジのデータ領域に言語ごとに置く(Wipe Data・入れ直しで消える = 出し直す条件と一致)。
//
// シートの見分け方(id は難読化されていて使えない・文言はロケールで変わる):
//   IME のウィンドウが Gboard のもので、その中に android.widget.Button が2つだけ・同じ行に並ぶ。
//   ふだんのキーは FrameLayout で、Button が出るのはこの種のシートだけ。左の Button(スキップ)を押す。
// Gboard 以外の IME では押さない(Button をキーに使う IME で誤ってキーを押さないため)。

package com.example.ftbridge;

import android.app.Instrumentation;
import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.SystemClock;
import android.util.Log;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;

import java.io.File;
import java.util.ArrayList;
import java.util.List;

final class ImeOnboarding {
    private ImeOnboarding() {}

    static final String GBOARD_PACKAGE = "com.google.android.inputmethod.latin";

    /** 画面を起こしてからキーボードが載るまで待つ上限(ms)。実測は 1 秒未満。尽きたら「キーボードは出ない
     *  構成」(ハードウェアキーボードの AVD 等)とみなし、印を置かずに戻る(次の起動でもう一度試す) */
    static final long IME_APPEAR_WAIT_MS = 4000;
    /** シート・画面が消えるのを待つ上限(ms)。尽きても先へ進む */
    static final long CLOSE_WAIT_MS = 2000;
    private static final long POLL_MS = 50;
    /** 走査の深さの上限(ループする木への備え) */
    private static final int MAX_DEPTH = 40;

    /** 失敗しても呼び手(アプリの起動)を止めない。戻り値はログ用("skipped" / "no-keyboard" / "no-sheet" / "dismissed by …" = 押したボタンの文言) */
    static String primeOnce(Instrumentation instrumentation, UiAutomation ua) {
        try {
            String locale = BridgeRouter.rawShell(ua, "settings get system system_locales").trim();
            if (locale.isEmpty() || "null".equals(locale)) locale = "default";
            File marker = new File(instrumentation.getContext().getFilesDir(),
                    "keyboard-primed-" + locale.replaceAll("[^A-Za-z0-9_-]", "_"));
            if (marker.exists()) return "skipped";

            BridgeRouter.rawShell(ua, "am start -W -n com.example.ftbridge/.KeyboardPrimerActivity");
            AccessibilityNodeInfo root = awaitImeRoot(ua);
            String outcome;
            if (root == null) {
                outcome = "no-keyboard";
            } else {
                AccessibilityNodeInfo skip = skipButton(root);
                CharSequence pressed = skip == null ? null : skip.getText();
                if (skip != null && skip.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                    awaitSheetClosed(ua);
                    outcome = "dismissed by \"" + pressed + "\"";
                } else {
                    outcome = "no-sheet";
                }
                marker.createNewFile();
            }
            finishPrimer(instrumentation);
            Log.i(BridgeInstrumentation.TAG, "keyboard primer: " + outcome + " (" + locale + ")");
            return outcome;
        } catch (Exception e) {
            Log.w(BridgeInstrumentation.TAG, "keyboard primer failed: " + e);
            try { finishPrimer(instrumentation); } catch (Exception ignored) { }
            return "failed";
        }
    }

    private static void finishPrimer(Instrumentation instrumentation) {
        // ラムダにしない(BridgeRouter.scheduleExit と同じ理由)
        instrumentation.runOnMainSync(new Runnable() {
            @Override public void run() {
                KeyboardPrimerActivity activity = KeyboardPrimerActivity.current;
                if (activity != null) activity.finish();
            }
        });
        long deadline = SystemClock.uptimeMillis() + CLOSE_WAIT_MS;
        while (KeyboardPrimerActivity.current != null && SystemClock.uptimeMillis() < deadline) {
            SystemClock.sleep(POLL_MS);
        }
    }

    private static AccessibilityNodeInfo awaitImeRoot(UiAutomation ua) {
        long deadline = SystemClock.uptimeMillis() + IME_APPEAR_WAIT_MS;
        AccessibilityNodeInfo root = imeRoot(ua);
        while (root == null && SystemClock.uptimeMillis() < deadline) {
            SystemClock.sleep(POLL_MS);
            root = imeRoot(ua);
        }
        return root;
    }

    private static void awaitSheetClosed(UiAutomation ua) {
        long deadline = SystemClock.uptimeMillis() + CLOSE_WAIT_MS;
        while (SystemClock.uptimeMillis() < deadline) {
            SystemClock.sleep(POLL_MS);
            AccessibilityNodeInfo now = imeRoot(ua);
            if (now == null || skipButton(now) == null) return;
        }
    }

    private static AccessibilityNodeInfo imeRoot(UiAutomation ua) {
        try {
            List<AccessibilityWindowInfo> windows = ua.getWindows();
            if (windows == null) return null;
            for (AccessibilityWindowInfo window : windows) {
                if (window == null || window.getType() != AccessibilityWindowInfo.TYPE_INPUT_METHOD) continue;
                AccessibilityNodeInfo root = window.getRoot();
                if (root != null) return root;
            }
        } catch (RuntimeException ignored) {
            // a11y サービス切断中などで getWindows が使えないときは「出ていない」と同じ扱い
        }
        return null;
    }

    /** シートの「スキップ」(左の Button)。シートでなければ null */
    private static AccessibilityNodeInfo skipButton(AccessibilityNodeInfo root) {
        CharSequence pkg = root.getPackageName();
        if (pkg == null || !GBOARD_PACKAGE.contentEquals(pkg)) return null;
        List<AccessibilityNodeInfo> buttons = new ArrayList<>();
        collectButtons(root, buttons, 0);
        if (buttons.size() != 2) return null;
        Rect a = new Rect();
        Rect b = new Rect();
        buttons.get(0).getBoundsInScreen(a);
        buttons.get(1).getBoundsInScreen(b);
        if (a.top != b.top || a.bottom != b.bottom) return null;
        return a.left <= b.left ? buttons.get(0) : buttons.get(1);
    }

    private static void collectButtons(AccessibilityNodeInfo node, List<AccessibilityNodeInfo> out, int depth) {
        if (node == null || depth > MAX_DEPTH) return;
        CharSequence cls = node.getClassName();
        CharSequence text = node.getText();
        if (cls != null && "android.widget.Button".contentEquals(cls) && node.isClickable()
                && node.isVisibleToUser() && text != null && text.length() > 0) {
            out.add(node);
        }
        for (int i = 0; i < node.getChildCount(); i++) {
            collectButtons(node.getChild(i), out, depth + 1);
        }
    }
}
