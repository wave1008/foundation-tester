// BridgeRouter.java
// エンドポイントのディスパッチ(Runner/FTesterRunnerUITests/BridgeRouter.swift の Java 版)。
// iOS ブリッジと同一のプロトコル: パス・DTO の JSON 形状・400/404/409/500 規約。
// /snapshot /tap 等はセッションレス(uiautomator dump と同じ「今フォアグラウンドのもの」意味論)。
package com.example.ftbridge;

import android.app.Instrumentation;
import android.app.UiAutomation;
import android.graphics.Bitmap;
import android.graphics.Rect;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.view.accessibility.AccessibilityNodeInfo;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

final class BridgeRouter implements BridgeHttpServer.Handler {

    /** /session の起動待ち上限(ms)。root ウィンドウが対象パッケージに切り替わるまでの上限。
     *  超過は 500 エラー(黙って成功にしない) */
    private static final long LAUNCH_CAP_MS = 10_000;
    /** stableActivePackage() の安定待ち上限(ms)。クロスパッケージ遷移の検知用 */
    private static final long STABLE_PACKAGE_BUDGET_MS = 100;

    static final class BridgeException extends RuntimeException {
        final int status;
        BridgeException(int status, String message) {
            super(message);
            this.status = status;
        }
    }

    private final Instrumentation instrumentation;
    /** UI 整定検知(操作後の固定 sleep の代替)。構築時に UiAutomation へ1回だけ登録する */
    private final QuietWaiter quietWaiter = new QuietWaiter();
    /** 直近スナップショットの ref → 中心座標(iOS ランナーの refFrames と同じ役割) */
    private Map<Integer, double[]> refCenters = new HashMap<>();
    private Rect lastScreen = new Rect();
    private String sessionBundleID;

    BridgeRouter(Instrumentation instrumentation) {
        this.instrumentation = instrumentation;
        ua().setOnAccessibilityEventListener(quietWaiter.listener());
    }

    @Override
    public BridgeHttpServer.Response handle(BridgeHttpServer.Request request) {
        try {
            String route = request.method + " " + request.path;
            switch (route) {
                case "GET /status": return handleStatus();
                case "GET /snapshot": return handleSnapshot();
                case "POST /tap": return handleTap(body(request));
                case "POST /type": return handleType(body(request));
                case "POST /swipe": return handleSwipe(body(request));
                case "POST /press": return handlePress(body(request));
                case "GET /screenshot": return handleScreenshot();
                case "POST /session": return handleLaunch(body(request));
                case "POST /terminate": return handleTerminate();
                case "POST /locale": return handleLocale(body(request));
                default:
                    return BridgeHttpServer.Response.error(404,
                            "not found: " + request.method + " " + request.path);
            }
        } catch (BridgeException e) {
            return BridgeHttpServer.Response.error(e.status, e.getMessage());
        } catch (Exception e) {
            return BridgeHttpServer.Response.error(500, String.valueOf(e));
        }
    }

    private UiAutomation ua() {
        UiAutomation ua = instrumentation.getUiAutomation();
        if (ua == null) {
            throw new BridgeException(500,
                    "UiAutomation を取得できません(am instrument は -w 付きで起動する必要があります)");
        }
        return ua;
    }

    /** リクエストボディの JSON パース(不正は 400 — iOS の decode() と同じ) */
    private JSONObject body(BridgeHttpServer.Request request) {
        try {
            String text = new String(request.body, StandardCharsets.UTF_8);
            return text.isEmpty() ? new JSONObject() : new JSONObject(text);
        } catch (JSONException e) {
            throw new BridgeException(400, "リクエストボディの JSON が不正です: " + e);
        }
    }

    // MARK: - Handlers

    private BridgeHttpServer.Response handleStatus() throws JSONException {
        boolean ready;
        String pkg = null;
        try {
            AccessibilityNodeInfo root = ua().getRootInActiveWindow();
            ready = true;
            if (root != null && root.getPackageName() != null) {
                pkg = root.getPackageName().toString();
            }
        } catch (Exception e) {
            ready = false;
        }
        JSONObject o = new JSONObject();
        o.put("ready", ready);
        o.put("device", Build.MODEL);
        o.put("osVersion", "Android " + Build.VERSION.RELEASE);
        String session = pkg != null ? pkg : sessionBundleID;
        if (session != null) o.put("sessionBundleID", session);
        return BridgeHttpServer.Response.json(200, o.toString());
    }

    private BridgeHttpServer.Response handleSnapshot() throws JSONException {
        SnapshotBuilder.Result result;
        try {
            result = SnapshotBuilder.build(ua());
        } catch (IllegalStateException e) {
            // root=null が waitForRoot の 2s を超えて続く一時ストール(高負荷時の画面消灯/描画停止で
            // 実測。黒スクショと対の症状)。WAKEUP 注入で display を起こしてから1回だけ再試行する
            shell("input keyevent KEYCODE_WAKEUP");
            SystemClock.sleep(500);
            result = SnapshotBuilder.build(ua());
        }
        refCenters = result.refCenters;
        lastScreen = result.screen;
        return BridgeHttpServer.Response.json(200, result.json);
    }

    private BridgeHttpServer.Response handleTap(JSONObject body) {
        double[] point = resolvePoint(body);
        InputInjector.tap(ua(), point[0], point[1]);
        settle();
        return ok();
    }

    private BridgeHttpServer.Response handleType(JSONObject body) {
        if (!body.has("text")) {
            throw new BridgeException(400, "text が必要です");
        }
        String text = body.optString("text");
        if (body.has("ref")) {
            double[] center = centerOf(body.optInt("ref"));
            InputInjector.tap(ua(), center[0], center[1]);
            // フォーカス反映のラグ対策(固定 sleep(500) の代替)。in-process の短間隔
            // チェックのみ(50ms 粒度以下。HTTP/snapshot ポーリングではない)
            InputInjector.waitForFocusInput(ua(), 2000);
        }
        InputInjector.setTextAppending(ua(), text);
        settle();
        return ok();
    }

    private BridgeHttpServer.Response handleSwipe(JSONObject body) {
        String direction = body.optString("direction");
        double w = lastScreen.width() > 0 ? lastScreen.width() : 1080;
        double h = lastScreen.height() > 0 ? lastScreen.height() : 2400;
        double cx = w / 2, cy = h / 2;
        double[] from, to;
        switch (direction) {
            case "up": from = new double[]{cx, h * 0.7}; to = new double[]{cx, h * 0.3}; break;
            case "down": from = new double[]{cx, h * 0.3}; to = new double[]{cx, h * 0.7}; break;
            case "left": from = new double[]{w * 0.8, cy}; to = new double[]{w * 0.2, cy}; break;
            case "right": from = new double[]{w * 0.2, cy}; to = new double[]{w * 0.8, cy}; break;
            default:
                throw new BridgeException(400, "direction は up/down/left/right のいずれかです");
        }
        InputInjector.swipe(ua(), from[0], from[1], to[0], to[1], 300);
        settle();
        return ok();
    }

    private BridgeHttpServer.Response handlePress(JSONObject body) {
        if (!body.has("ref")) {
            throw new BridgeException(400, "ref が必要です");
        }
        double[] center = centerOf(body.optInt("ref"));
        double duration = body.optDouble("duration", 1.0);
        InputInjector.press(ua(), center[0], center[1], duration);
        settle();
        return ok();
    }

    private BridgeHttpServer.Response handleScreenshot() {
        Bitmap bitmap = ua().takeScreenshot();
        if (bitmap == null) {
            throw new BridgeException(500, "スクリーンショットを取得できません");
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out);
        bitmap.recycle();
        return BridgeHttpServer.Response.png(out.toByteArray());
    }

    /** アプリ起動(ホストの AndroidDriver.launch() はこのエンドポイントに一本化されている) */
    private BridgeHttpServer.Response handleLaunch(JSONObject body) {
        String bundleID = body.optString("bundleID");
        if (bundleID.isEmpty()) {
            throw new BridgeException(400, "bundleID が必要です");
        }
        shell("am force-stop " + bundleID);
        String output = shell("monkey -p " + bundleID + " -c android.intent.category.LAUNCHER 1");
        if (!output.contains("Events injected: 1")) {
            // monkey はプロビジョニング直後の AVD などで理由なく失敗することがある(実測 exit 251。
            // ホスト側 AndroidDriver.launch() に同じロジックがあった=移植して一本化)。
            // LAUNCHER アクティビティを解決して am start で起動するフォールバック
            String resolve = shell("cmd package resolve-activity --brief "
                    + "-c android.intent.category.LAUNCHER " + bundleID);
            String component = null;
            for (String line : resolve.split("\n")) {
                line = line.trim();
                if (line.contains("/")) component = line;
            }
            String start = component == null ? null : shell("am start -n " + component);
            if (component == null || start == null || start.contains("Error")) {
                throw new BridgeException(500,
                        "アプリを起動できません: " + bundleID + "(インストール済みか確認してください)");
            }
        }
        sessionBundleID = bundleID;

        // root ウィンドウが対象パッケージに切り替わるまで待つ(in-process の短間隔チェック。
        // 50ms 粒度以下。HTTP/snapshot ポーリングではない)。上限超過は黙って進まずエラーにする
        long deadline = SystemClock.uptimeMillis() + LAUNCH_CAP_MS;
        while (true) {
            AccessibilityNodeInfo root = ua().getRootInActiveWindow();
            String pkg = root != null && root.getPackageName() != null
                    ? root.getPackageName().toString() : null;
            if (bundleID.equals(pkg)) break;
            if (SystemClock.uptimeMillis() >= deadline) {
                throw new BridgeException(500, "アプリの画面が表示されませんでした: " + bundleID);
            }
            SystemClock.sleep(50);
        }
        long remaining = Math.max(0, deadline - SystemClock.uptimeMillis());
        quietWaiter.quietWait(bundleID, QuietWaiter.QUIET_MS, remaining);
        return ok();
    }

    private BridgeHttpServer.Response handleTerminate() {
        if (sessionBundleID != null) {
            shell("am force-stop " + sessionBundleID);
            sessionBundleID = null;
        }
        return ok();
    }

    /**
     * システムロケールの永続変更(Play イメージは root/setprop/-change-locale が全滅のため、
     * shell 権限借用(CHANGE_CONFIGURATION)+ IActivityManager.updatePersistentConfiguration
     * が唯一の非 root 手段。fastlane screengrab と同方式)。
     * 隠し API 反射のため、ホスト側 AndroidBridge.swift(同期相手)がブリッジ起動時に
     * `settings put global hidden_api_policy 1` を設定していることが前提。
     * userSetLocale=true が永続化(再起動後も保持)の鍵。
     * 応答: {"changed": bool, "locale": "<BCP-47>"}(iOS ブリッジに本エンドポイントは無い)
     */
    private BridgeHttpServer.Response handleLocale(JSONObject body) throws JSONException {
        String tag = body.optString("locale", "").replace('_', '-');
        if (tag.isEmpty()) throw new BridgeException(400, "locale がありません");
        java.util.Locale target = java.util.Locale.forLanguageTag(tag);
        if (target.getLanguage().isEmpty()) {
            throw new BridgeException(400, "locale を解釈できません: " + tag);
        }
        java.util.Locale current = android.content.res.Resources.getSystem()
                .getConfiguration().getLocales().get(0);
        JSONObject o = new JSONObject();
        if (current.toLanguageTag().equalsIgnoreCase(target.toLanguageTag())) {
            o.put("changed", false);
            o.put("locale", current.toLanguageTag());
            return BridgeHttpServer.Response.json(200, o.toString());
        }
        if (Build.VERSION.SDK_INT < 29) {
            throw new BridgeException(500, "ロケール変更は API 29 以上のみ対応です");
        }
        UiAutomation ua = ua();
        ua.adoptShellPermissionIdentity();
        try {
            Object am = Class.forName("android.app.ActivityManager")
                    .getMethod("getService").invoke(null);
            android.content.res.Configuration config = new android.content.res.Configuration();
            config.setLocales(new android.os.LocaleList(target));
            config.getClass().getField("userSetLocale").setBoolean(config, true);
            am.getClass().getMethod("updatePersistentConfiguration",
                    android.content.res.Configuration.class).invoke(am, config);
        } catch (ReflectiveOperationException e) {
            throw new BridgeException(500, "ロケール変更に失敗(hidden_api_policy=1 が必要): " + e);
        } finally {
            ua.dropShellPermissionIdentity();
        }
        o.put("changed", true);
        o.put("locale", target.toLanguageTag());
        return BridgeHttpServer.Response.json(200, o.toString());
    }

    // MARK: - Helpers

    /** 静穏待ちの対象パッケージ(操作時点のアクティブウィンドウ優先、無ければ現在セッション) */
    private String activePackage() {
        AccessibilityNodeInfo root = ua().getRootInActiveWindow();
        String pkg = root != null && root.getPackageName() != null
                ? root.getPackageName().toString() : null;
        return pkg != null ? pkg : sessionBundleID;
    }

    /**
     * /tap /type /swipe /press 共通の整定待ち(操作後の固定 sleep の代替)。
     * 操作直後のアクティブパッケージ(stableActivePackage())を初期の静穏対象として
     * quietWaiter.quietWait() を1回呼ぶ。クロスパッケージ遷移(例: 設定→Google サービス
     * のような別パッケージへのハンドオフ)は、QuietWaiter がウィンドウ切替イベント
     * (TYPE_WINDOW_STATE_CHANGED)を検知した瞬間に静穏対象を遷移先パッケージへ追従させる
     * ため、この1回の呼び出しの中で自然に扱われる(多段遷移にも追従する。詳細は
     * QuietWaiter.java 参照)
     */
    private void settle() {
        String startPackage = stableActivePackage(STABLE_PACKAGE_BUDGET_MS);
        quietWaiter.quietWait(startPackage, QuietWaiter.QUIET_MS, QuietWaiter.ACTION_CAP_MS);
    }

    /**
     * activePackage() が安定するまで待ってから返す(最大 budgetMs)。タップ直後はアクティブ
     * ウィンドウのパッケージがまだ遷移中のことがある(例: 検索のハンドオフ・外部アプリ起動で
     * 別パッケージへ切り替わる)。その瞬間を静穏待ちの対象に選ぶと遷移元パッケージの静穏を
     * 見てしまい、遷移先の描画完了を待たずに早期リターンする。短い間隔で2回連続同じ値を
     * 観測できたら確定させる(in-process の短間隔チェックのみ。50ms 粒度以下。
     * HTTP/snapshot ポーリングではない)。
     */
    private String stableActivePackage(long budgetMs) {
        long deadline = SystemClock.uptimeMillis() + budgetMs;
        String previous = activePackage();
        String current = activePackage();
        // 大半(同一パッケージ内タップ)はここで即確定(sleep なし)。2 回連続で違う場合だけ
        // 遷移中とみなし、間隔を空けて再確認する
        while (!(current == null ? previous == null : current.equals(previous))
                && SystemClock.uptimeMillis() < deadline) {
            previous = current;
            SystemClock.sleep(30);
            current = activePackage();
        }
        return current;
    }

    private double[] resolvePoint(JSONObject body) {
        if (body.has("ref")) {
            return centerOf(body.optInt("ref"));
        }
        if (body.has("x") && body.has("y")) {
            return new double[]{body.optDouble("x"), body.optDouble("y")};
        }
        throw new BridgeException(400, "ref または x/y が必要です");
    }

    private double[] centerOf(int ref) {
        double[] center = refCenters.get(ref);
        if (center == null) {
            throw new BridgeException(404,
                    "参照番号 [" + ref + "] は未知です。先に GET /snapshot を実行してください");
        }
        return center;
    }

    private String shell(String command) {
        try {
            ParcelFileDescriptor pfd = ua().executeShellCommand(command);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try (InputStream in = new ParcelFileDescriptor.AutoCloseInputStream(pfd)) {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            }
            return out.toString("UTF-8");
        } catch (Exception e) {
            throw new BridgeException(500, "shell 実行に失敗: " + command + " (" + e + ")");
        }
    }

    private static BridgeHttpServer.Response ok() {
        return BridgeHttpServer.Response.json(200, "{\"ok\":true}");
    }
}
