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
    private Map<Integer, String> refIds = new HashMap<>();
    private Rect lastScreen = new Rect();
    private String sessionBundleID;
    /** 自 APK の versionCode(/status で申告)。取得失敗時は 0 = 申告しない */
    private final int versionCode;

    BridgeRouter(Instrumentation instrumentation) {
        this.instrumentation = instrumentation;
        this.versionCode = resolveVersionCode(instrumentation);
        UiAutomation ua = ua();
        ua.setOnAccessibilityEventListener(quietWaiter.listener());
        // getWindows() は既定でこのフラグが立っていないと空を返す(IME ウィンドウの bounds が
        // 拾えない=keyboardFrame が常に省略される)。SnapshotBuilder.keyboardBounds 参照
        android.accessibilityservice.AccessibilityServiceInfo info = ua.getServiceInfo();
        if (info != null) {
            info.flags |= android.accessibilityservice.AccessibilityServiceInfo
                    .FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
            ua.setServiceInfo(info);
        }
    }

    /** インストール済み APK の実 versionCode(build.sh の VERSION_CODE と手動同期しないため実物を引く) */
    private static int resolveVersionCode(Instrumentation instrumentation) {
        try {
            android.content.Context ctx = instrumentation.getContext();
            return ctx.getPackageManager().getPackageInfo(ctx.getPackageName(), 0).versionCode;
        } catch (Exception e) {
            return 0;
        }
    }

    @Override
    public BridgeHttpServer.Response handle(BridgeHttpServer.Request request) {
        try {
            String route = request.method + " " + request.path;
            switch (route) {
                case "GET /status": return handleStatus();
                case "GET /snapshot": return handleSnapshot(request);
                case "POST /tap": return handleTap(body(request));
                case "POST /type": return handleType(body(request));
                case "POST /clear": return handleClear(body(request));
                case "POST /swipe": return handleSwipe(body(request));
                case "POST /doubletap": return handleDoubleTap(body(request));
                case "POST /pinch": return handlePinch(body(request));
                case "POST /press": return handlePress(body(request));
                case "POST /pressEnter": return handlePressEnter();
                case "GET /screenshot": return handleScreenshot();
                case "POST /session": return handleLaunch(body(request));
                case "POST /terminate": return handleTerminate();
                case "POST /locale": return handleLocale(body(request));
                case "POST /settle": return handleSettle();
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
                    "cannot obtain UiAutomation (am instrument must be started with -w)");
        }
        return ua;
    }

    /** リクエストボディの JSON パース(不正は 400 — iOS の decode() と同じ) */
    private JSONObject body(BridgeHttpServer.Request request) {
        try {
            String text = new String(request.body, StandardCharsets.UTF_8);
            return text.isEmpty() ? new JSONObject() : new JSONObject(text);
        } catch (JSONException e) {
            throw new BridgeException(400, "the request body is not valid JSON: " + e);
        }
    }

    /** "a=1&b=2" 形式から key を1つ引く。"?" が無い/値が無い/複数パラメータでも例外を投げない */
    private static String queryParam(String query, String key) {
        if (query == null || query.isEmpty()) return null;
        for (String pair : query.split("&")) {
            if (pair.isEmpty()) continue;
            int eq = pair.indexOf('=');
            String k = eq >= 0 ? pair.substring(0, eq) : pair;
            if (!k.equals(key)) continue;
            return eq >= 0 ? pair.substring(eq + 1) : "";
        }
        return null;
    }

    private static boolean isTruthy(String value) {
        return "1".equals(value) || "true".equalsIgnoreCase(value);
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
        // 稼働中プロセスの版をホストが照合できるように申告(AndroidBridge.swift probeBridge が
        // expectedBridgeVersionCode と比較し、不一致なら再インストール+再起動する)
        if (versionCode > 0) o.put("bridgeVersionCode", versionCode);
        String session = pkg != null ? pkg : sessionBundleID;
        if (session != null) o.put("sessionBundleID", session);
        // 起動元の自己申告(doctor の診断用。BridgeDTO.StatusResponse の同名フィールド参照)
        if (BridgeInstrumentation.ownerRepo != null) o.put("ownerRepo", BridgeInstrumentation.ownerRepo);
        o.put("idleSeconds", BridgeHttpServer.lastIdleSeconds);
        // 画面が進んでいるかの計器(DisplayHeartbeat 参照)。負値 = 計器が動いていない = 申告しない
        double displayIdle = DisplayHeartbeat.idleSeconds();
        if (displayIdle >= 0) o.put("displayIdleSeconds", displayIdle);
        // 所要内訳ログの状態。起動時にしか切り替わらないので、ホストは希望と違えば起動し直す
        // (同期相手: Sources/FTAndroid/AndroidBridge.swift の startBridge)
        if (BridgeInstrumentation.timingEnabled) o.put("timingEnabled", true);
        return BridgeHttpServer.Response.json(200, o.toString());
    }

    /**
     * 画面の静穏を待つだけのエンドポイント(状態は変えない)。
     *
     * ホストが adb/gRPC でブリッジを経由せずに画面を変える経路(activate の monkey intent、
     * KEYCODE_HOME / APP_SWITCH / ENTER の keyevent)は、このブリッジの settle() を通らないため
     * 従来はホスト側で固定 800ms 待っていた。固定待ちはマシン性能・負荷・アニメーション長で
     * 過不足が出るので、a11y イベント駆動の QuietWaiter をホストから呼べるようにする。
     */
    private BridgeHttpServer.Response handleSettle() {
        settle();
        return ok();
    }

    private BridgeHttpServer.Response handleSnapshot(BridgeHttpServer.Request request) throws JSONException {
        // クエリ `refresh=1`(または `true`)は「タイムアウト直前の1回だけ全ノード refresh() する」
        // 契約(ホスト側と同期。SnapshotBuilder.collect のコメント参照)。無指定は従来どおり false
        boolean forceRefresh = isTruthy(queryParam(request.query, "refresh"));
        SnapshotBuilder.Result result;
        try {
            result = SnapshotBuilder.build(ua(), instrumentation.getContext(), forceRefresh);
        } catch (IllegalStateException e) {
            // root=null が waitForRoot の 2s を超えて続く一時ストール(高負荷時の画面消灯/描画停止で
            // 実測。黒スクショと対の症状)。WAKEUP 注入で display を起こしてから1回だけ再試行する
            shell("input keyevent KEYCODE_WAKEUP");
            SystemClock.sleep(500);
            result = SnapshotBuilder.build(ua(), instrumentation.getContext(), forceRefresh);
        }
        refCenters = result.refCenters;
        refIds = result.refIds;
        lastScreen = result.screen;
        return BridgeHttpServer.Response.json(200, result.json);
    }

    private BridgeHttpServer.Response handleTap(JSONObject body) {
        long t0 = SystemClock.uptimeMillis();
        double[] point = resolvePoint(body);
        InputInjector.tap(ua(), point[0], point[1]);
        long t1 = SystemClock.uptimeMillis();
        settle("tap");
        if (BridgeInstrumentation.timingEnabled) {
            android.util.Log.i(BridgeInstrumentation.TAG, "tapTiming inject=" + (t1 - t0)
                    + " settle=" + (SystemClock.uptimeMillis() - t1));
        }
        return ok();
    }

    private BridgeHttpServer.Response handleType(JSONObject body) {
        if (!body.has("text")) {
            throw new BridgeException(400, "text is required");
        }
        String text = body.optString("text");
        if (body.has("ref")) {
            int ref = body.optInt("ref");
            double[] center = centerOf(ref);
            InputInjector.tap(ua(), center[0], center[1]);
            // 確認と注入を統合した経路(InputInjector.setTextAppendingAt のコメント参照)。
            // resource-id を渡す: キーボードの開閉で座標がズレても同じ要素を追跡し直すため
            InputInjector.setTextAppendingAt(ua(), center[0], center[1], refIds.get(ref), text, 4000);
        } else {
            InputInjector.setTextAppending(ua(), text);
        }
        settle();
        return ok();
    }

    /** ref あり = その要素を空文字へ全置換(BridgeDTO.ClearRequest 参照)。ref なしはフォーカス欄。
     *  対象なし/SET_TEXT 拒否は 409(ホストの typeDriver フォールバックの合図。500 にしない) */
    private BridgeHttpServer.Response handleClear(JSONObject body) {
        if (body.has("ref")) {
            int ref = body.optInt("ref");
            double[] center = centerOf(ref);
            InputInjector.tap(ua(), center[0], center[1]);
            InputInjector.clearTextAt(ua(), center[0], center[1], refIds.get(ref), 4000);
        } else {
            InputInjector.clearFocused(ua());
        }
        settle();
        return ok();
    }

    private BridgeHttpServer.Response handleSwipe(JSONObject body) {
        String direction = body.optString("direction");
        double w = lastScreen.width() > 0 ? lastScreen.width() : 1080;
        double h = lastScreen.height() > 0 ? lastScreen.height() : 2400;
        double cx = w / 2, cy = h / 2;
        boolean vertical = direction.equals("up") || direction.equals("down");
        // 可変パラメータはホストが用途(FTSwipeIntent)に応じて送る(契約は FTCore/BridgeDTO.SwipeRequest)。
        // distance の既定は**軸で違う**(縦 0.4 = 0.7→0.3 / 横 0.6 = 0.8→0.2。v40 までの固定値と同一)。
        // 一律 0.4 にすると、何も送らない gesture / search の横スワイプまで黙って狭くなる。
        // 明示値は既定と同値でも必ず計算に使う(「既定と同じなら無視」だと、既定を変えた瞬間に
        // ホストの指定が黙って無視される)
        double span = body.optDouble("distance", vertical ? 0.4 : 0.6);
        long strokeMs = body.optLong("durationMs", 300);
        boolean syntheticUp = body.optBoolean("fling", false);
        double half = Math.min(Math.max(span, 0.05), 0.9) / 2;
        double[] from, to;
        // **スクロール領域を指定されたときはホストが計算した実座標を使う**(FTCore/ScrollGeometry)。
        // ここで軸別既定や distance を混ぜてはいけない —— 領域内の座標として計算済みで、
        // 比率で作り直すと画面中央基準に戻ってしまう
        JSONObject path = body.optJSONObject("path");
        if (path != null) {
            InputInjector.swipe(ua(), path.optDouble("fromX"), path.optDouble("fromY"),
                    path.optDouble("toX"), path.optDouble("toY"), strokeMs, syntheticUp);
            settle();
            return ok();
        }
        switch (direction) {
            case "up": from = new double[]{cx, h * (0.5 + half)}; to = new double[]{cx, h * (0.5 - half)}; break;
            case "down": from = new double[]{cx, h * (0.5 - half)}; to = new double[]{cx, h * (0.5 + half)}; break;
            case "left": from = new double[]{w * (0.5 + half), cy}; to = new double[]{w * (0.5 - half), cy}; break;
            case "right": from = new double[]{w * (0.5 - half), cy}; to = new double[]{w * (0.5 + half), cy}; break;
            default:
                throw new BridgeException(400, "direction must be one of up/down/left/right");
        }
        InputInjector.swipe(ua(), from[0], from[1], to[0], to[1], strokeMs, syntheticUp);
        settle();
        return ok();
    }

    /** ダブルタップ(ref または x/y。iOS ブリッジと同じ受理形) */
    private BridgeHttpServer.Response handleDoubleTap(JSONObject body) {
        double[] point = resolvePoint(body);
        InputInjector.doubleTap(ua(), point[0], point[1]);
        settle();
        return ok();
    }

    /**
     * 2本指のピンチ。**ホストが送る frame の中心**で開閉する(nil = 画面全体)。
     * PinchRequest.identifier は iOS 専用(XCUITest は座標指定の多点ジェスチャを持たないため)で、
     * こちらは読まない —— 座標を作れるので frame の方が正確。
     *
     * span は**倍率が正確に出る側から決める**: 拡大なら「広い方 = 短辺の 90%」を終点にして
     * 始点を span/scale に、縮小ならその逆。先に始点を決めて scale 倍すると領域からはみ出し、
     * クランプで倍率が黙って目減りする(短辺の 90% を超える点は容器の外 = 別のビューが受け取る)。
     * 指を 16px より近付けることはできない(タッチスロップ)ので、極端な scale では倍率が落ちる。
     */
    private BridgeHttpServer.Response handlePinch(JSONObject body) {
        double scale = body.optDouble("scale", 0);
        if (!(scale > 0) || scale == 1 || Double.isInfinite(scale)) {
            throw new BridgeException(400, "scale must be positive and not 1 (received: " + scale + ")");
        }
        double left = lastScreen.left, top = lastScreen.top;
        double width = lastScreen.width() > 0 ? lastScreen.width() : 1080;
        double height = lastScreen.height() > 0 ? lastScreen.height() : 2400;
        JSONObject frame = body.optJSONObject("frame");
        if (frame != null) {
            left = frame.optDouble("x", left);
            top = frame.optDouble("y", top);
            width = frame.optDouble("width", width);
            height = frame.optDouble("height", height);
        }
        double maxSpan = Math.min(width, height) * 0.9;
        double startSpan, endSpan;
        if (scale > 1) {
            endSpan = maxSpan;
            startSpan = Math.max(maxSpan / scale, 16);
        } else {
            startSpan = maxSpan;
            endSpan = Math.max(maxSpan * scale, 16);
        }
        long durationMs = Math.min(Math.max(
                (long) (body.optDouble("durationSeconds", 0.5) * 1000), 50), 10000);
        InputInjector.pinch(ua(), left + width / 2, top + height / 2, startSpan, endSpan, durationMs);
        settle();
        return ok();
    }

    private BridgeHttpServer.Response handlePress(JSONObject body) {
        // ref または x/y(iOS ブリッジと同じ受理形。ホストは ref を自前解決して x/y で送る)
        double[] center = resolvePoint(body);
        double duration = body.optDouble("duration", 1.0);
        InputInjector.press(ua(), center[0], center[1], duration);
        settle();
        return ok();
    }

    /**
     * フォーカス中の入力欄へ IME の Enter アクションを直接発火する(ACTION_IME_ENTER、API 30+)。
     * ソフトキーボード表示中の View/XML EditText では keyevent 66 が IME に吸われ届かないため、
     * ホスト側 AndroidDriver.pressEnter() はこのエンドポイントを優先し、404/409/501 でだけ
     * 既存のキーイベント経路へフォールバックする(実装は InputInjector.pressImeEnter 参照)。
     */
    private BridgeHttpServer.Response handlePressEnter() {
        if (Build.VERSION.SDK_INT < 30) {
            throw new BridgeException(501, "ACTION_IME_ENTER is not supported below API 30");
        }
        InputInjector.pressImeEnter(ua());
        settle();
        return ok();
    }

    private BridgeHttpServer.Response handleScreenshot() {
        Bitmap bitmap = ua().takeScreenshot();
        if (bitmap == null) {
            throw new BridgeException(500, "cannot take a screenshot");
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out);
        bitmap.recycle();
        return BridgeHttpServer.Response.png(out.toByteArray());
    }

    /** 1回分の起動試行。前面判定タイムアウトは例外ではなく false */
    private boolean attemptLaunch(String bundleID) {
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
                        "cannot launch the app: " + bundleID + " (check that it is installed)");
            }
        }
        sessionBundleID = bundleID;

        // root ウィンドウが対象パッケージに切り替わるまで待つ(in-process の短間隔チェック。
        // 50ms 粒度以下。HTTP/snapshot ポーリングではない)。上限超過は例外にせず false を返す
        // (呼び出し元 handleLaunch が前面掃除つきで1回だけ再試行する)
        long deadline = SystemClock.uptimeMillis() + LAUNCH_CAP_MS;
        while (true) {
            AccessibilityNodeInfo root = ua().getRootInActiveWindow();
            String pkg = root != null && root.getPackageName() != null
                    ? root.getPackageName().toString() : null;
            if (bundleID.equals(pkg)) break;
            if (SystemClock.uptimeMillis() >= deadline) {
                return false;
            }
            SystemClock.sleep(50);
        }
        long remaining = Math.max(0, deadline - SystemClock.uptimeMillis());
        quietWaiter.quietWait(bundleID, QuietWaiter.QUIET_MS, remaining);
        return true;
    }

    /** アプリ起動(ホストの AndroidDriver.launch() はこのエンドポイントに一本化されている) */
    private BridgeHttpServer.Response handleLaunch(JSONObject body) {
        String bundleID = body.optString("bundleID");
        if (bundleID.isEmpty()) {
            throw new BridgeException(400, "bundleID is required");
        }
        if (attemptLaunch(bundleID)) return ok();
        // 前面判定が別パッケージの居座りで詰んだ。前面を掃除して1回だけ再試行する。
        // force-stop が bundleID しか殺さないと以後の launchApp が全滅する既知の罠(design.md §8.7)。
        // 掃除対象は bundleID 自身・ブリッジ自身・HOME ランチャーを除いた前面パッケージのみ。
        String stuck = activePackage();
        String self = instrumentation.getContext().getPackageName();
        String home = resolveHomePackage();
        if (stuck != null && !stuck.equals(bundleID) && !stuck.equals(self) && !stuck.equals(home)) {
            shell("am force-stop " + stuck);
            shell("input keyevent KEYCODE_HOME");
        }
        if (attemptLaunch(bundleID)) return ok();
        throw new BridgeException(500, "the app never came to the foreground: " + bundleID);
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
        if (tag.isEmpty()) throw new BridgeException(400, "locale is required");
        java.util.Locale target = java.util.Locale.forLanguageTag(tag);
        if (target.getLanguage().isEmpty()) {
            throw new BridgeException(400, "cannot parse the locale: " + tag);
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
            throw new BridgeException(500, "changing the locale requires API 29 or newer");
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
            throw new BridgeException(500, "changing the locale failed (hidden_api_policy=1 is required): " + e);
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

    /** HOME ランチャーのパッケージ名(復旧時の前面掃除で除外するため)。解決不能なら null */
    private String resolveHomePackage() {
        String resolve = shell("cmd package resolve-activity --brief "
                + "-c android.intent.category.HOME");
        String component = null;
        for (String line : resolve.split("\n")) {
            line = line.trim();
            if (line.contains("/")) component = line;
        }
        return component == null ? null : component.substring(0, component.indexOf('/'));
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
        settle("-");
    }

    /** settle() の内訳を logcat に出す版。tag は呼び出し元(計測時にホスト側 actionMs と突き合わせる)。
     *  ACTION_CAP_MS を超える値が出るなら待ちは quietWait の外にある。 */
    private void settle(String tag) {
        long t0 = SystemClock.uptimeMillis();
        String startPackage = stableActivePackage(STABLE_PACKAGE_BUDGET_MS);
        long t1 = SystemClock.uptimeMillis();
        quietWaiter.quietWait(startPackage, QuietWaiter.QUIET_MS, QuietWaiter.ACTION_CAP_MS);
        long t2 = SystemClock.uptimeMillis();
        if (BridgeInstrumentation.timingEnabled) {
            android.util.Log.i(BridgeInstrumentation.TAG, "settleTiming " + tag
                    + " stablePkg=" + (t1 - t0) + " quiet=" + (t2 - t1));
        }
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
        throw new BridgeException(400, "ref or x/y is required");
    }

    private double[] centerOf(int ref) {
        double[] center = refCenters.get(ref);
        if (center == null) {
            throw new BridgeException(404,
                    "reference number [" + ref + "] is unknown. Run GET /snapshot first");
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
            throw new BridgeException(500, "the shell command failed: " + command + " (" + e + ")");
        }
    }

    private static BridgeHttpServer.Response ok() {
        return BridgeHttpServer.Response.json(200, "{\"ok\":true}");
    }
}
