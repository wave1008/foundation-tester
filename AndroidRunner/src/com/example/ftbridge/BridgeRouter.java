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

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

final class BridgeRouter implements BridgeHttpServer.Handler {

    static final class BridgeException extends RuntimeException {
        final int status;
        BridgeException(int status, String message) {
            super(message);
            this.status = status;
        }
    }

    private final Instrumentation instrumentation;
    /** 直近スナップショットの ref → 中心座標(iOS ランナーの refFrames と同じ役割) */
    private Map<Integer, double[]> refCenters = new HashMap<>();
    private Rect lastScreen = new Rect();
    private String sessionBundleID;

    BridgeRouter(Instrumentation instrumentation) {
        this.instrumentation = instrumentation;
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
            android.view.accessibility.AccessibilityNodeInfo root = ua().getRootInActiveWindow();
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
        SnapshotBuilder.Result result = SnapshotBuilder.build(ua());
        refCenters = result.refCenters;
        lastScreen = result.screen;
        return BridgeHttpServer.Response.json(200, result.json);
    }

    private BridgeHttpServer.Response handleTap(JSONObject body) {
        double[] point = resolvePoint(body);
        InputInjector.tap(ua(), point[0], point[1]);
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
            SystemClock.sleep(500);
        }
        InputInjector.setTextAppending(ua(), text);
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
        return ok();
    }

    private BridgeHttpServer.Response handlePress(JSONObject body) {
        if (!body.has("ref")) {
            throw new BridgeException(400, "ref が必要です");
        }
        double[] center = centerOf(body.optInt("ref"));
        double duration = body.optDouble("duration", 1.0);
        InputInjector.press(ua(), center[0], center[1], duration);
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

    /** 互換実装(ホストの AndroidDriver は launch/terminate を adb 直で行う) */
    private BridgeHttpServer.Response handleLaunch(JSONObject body) {
        String bundleID = body.optString("bundleID");
        if (bundleID.isEmpty()) {
            throw new BridgeException(400, "bundleID が必要です");
        }
        shell("am force-stop " + bundleID);
        String output = shell("monkey -p " + bundleID + " -c android.intent.category.LAUNCHER 1");
        if (!output.contains("Events injected: 1")) {
            throw new BridgeException(500, "アプリを起動できません: " + bundleID);
        }
        sessionBundleID = bundleID;
        SystemClock.sleep(1500);
        return ok();
    }

    private BridgeHttpServer.Response handleTerminate() {
        if (sessionBundleID != null) {
            shell("am force-stop " + sessionBundleID);
            sessionBundleID = null;
        }
        return ok();
    }

    // MARK: - Helpers

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
