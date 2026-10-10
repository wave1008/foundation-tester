// BridgeRouter.java
// エンドポイントのディスパッチ(Runner/FleetestRunnerUITests/BridgeRouter.swift の Java 版)。
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

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

final class BridgeRouter implements BridgeHttpServer.Handler {

    /** type/clear の確認期限(ms)。Android は値をまとめて注入して読み返す(xcuitest は1キーずつ打鍵して読み返すため 8s) */
    private static final long TEXT_INPUT_CONFIRM_BUDGET_MS = 4000;
    /** swipe の durationMs 未指定時の所要(ms) */
    private static final long SWIPE_DEFAULT_STROKE_MS = 300;
    /** press の duration 未指定時の長押し秒数(s) */
    private static final double PRESS_DEFAULT_SECONDS = 1.0;
    /** プロセス終了要求の応答を返し切るための猶予(ms)。経過後に System.exit */
    private static final long EXIT_GRACE_MS = 500;
    /** snapshot 再試行前の KEYCODE_WAKEUP 後に display が起きるのを待つ時間(ms) */
    private static final long WAKEUP_SETTLE_MS = 500;
    /** 起動後に対象が前面に来るのを待つ間のポーリング間隔(ms) */
    private static final long FOREGROUND_POLL_MS = 50;
    /** stableActivePackage() の再確認の間隔(ms)。遷移中とみなした2回連続不一致のときだけ空ける */
    private static final long PACKAGE_RECHECK_MS = 30;
    /** /session の起動待ち上限(ms)。root ウィンドウが対象パッケージに切り替わるまでの上限。
     *  超過は 500 エラー(黙って成功にしない) */
    private static final long LAUNCH_CAP_MS = 10_000;
    /** stableActivePackage() の安定待ち上限(ms)。クロスパッケージ遷移の検知用 */
    private static final long STABLE_PACKAGE_BUDGET_MS = 100;
    /**
     * ジェスチャ(POST /gesture・POST /pinch)全体の絶対上限(秒)。InputInjector.press の
     * クランプと同じ 60s(= BridgeAPI.gestureSecondsCeiling)。
     * **gesture/pinch は丸めず拒否する** —— press は単純な往復なのでクランプの実害が小さいが、
     * 指ごとの経路は形そのものが意味を持つので丸めると別物になる(pinch もホストが組んだ経路を
     * 再生するので同じ)。
     */
    private static final double GESTURE_SECONDS_CEILING = 60;
    /** 指の本数上限。Sources/FTCore/BridgeDTO.swift の BridgeAPI.gestureMaxFingers と同じ値
     *  (片方だけ変えない。cross-language な値の一致は GestureLimitsSyncTests が固定する) */
    private static final int MAX_GESTURE_FINGERS = 5;
    /** 1本の指に置ける点の上限。同じく BridgeAPI.gestureMaxPointsPerFinger と同じ値 */
    private static final int MAX_GESTURE_POINTS_PER_FINGER = 625;
    /**
     * アプリの上に乗る「システムのダイアログ」のパッケージ。**force-stop の対象にしない**
     * (殺すと権限フローが壊れ、systemui なら端末ごと巻き添え)。handleLaunch の前面判定が
     * これらで詰まったときは「アプリは前面に居て、その上にダイアログが乗っている」として成功を
     * 返す(以後はホストの system-alert 処理が引き取る)。
     * 先頭5つは Sources/fleetest-mcp/MCPServer+Driver.swift の `systemDialogPackages` と同じ集合
     * (同期相手。片方だけ変えない = BridgeRouterGuardsJavaSyncTests)。
     * com.android.chrome はこちらだけの追加: Custom Tab はアプリの上に別プロセスの全画面が乗る形で、
     * force-stop するとアプリ側の遷移が壊れる。
     */
    static final Set<String> SYSTEM_DIALOG_PACKAGES = new HashSet<>(Arrays.asList(
            "com.google.android.permissioncontroller", "com.android.permissioncontroller",
            "com.android.packageinstaller", "com.google.android.packageinstaller",
            "com.android.systemui",
            "com.android.chrome"
    ));

    static final class BridgeException extends RuntimeException {
        final int status;
        BridgeException(int status, String message) {
            super(message);
            this.status = status;
        }
    }

    /**
     * handleSnapshot が「a11y 根が無い」で断るときの本文接頭辞(422)。
     * 同期相手: Sources/FTCore/BridgeDTO.swift の BridgeAPI.androidNoActiveWindowRootPrefix
     * (片方だけ変えない。AndroidNoReadableWindowSyncTests が固定)。
     * status は 422 —— 400/404/409/500 は既に別の意味で使用中(表は docs/design.md §4.3)。
     * 409 は Android では「対象なし/SET_TEXT 拒否 = ホストの typeDriver フォールバックの合図」
     * なので使えない。422 は InputInjector.rejectMaskedAppend が /type で使っているが、
     * エンドポイントが違うので衝突しない。
     */
    static final String NO_ACTIVE_WINDOW_ROOT = "no-active-window-root:";

    private final Instrumentation instrumentation;
    /** UI 整定検知(操作後の固定 sleep の代替)。構築時に UiAutomation へ1回だけ登録する。
     *  既定 IME の読み出しに context が要るのでコンストラクタで作る(フィールド初期化子では
     *  instrumentation がまだ null) */
    private final QuietWaiter quietWaiter;
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
        this.quietWaiter = new QuietWaiter(instrumentation.getContext());
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

    /** 処理中のリクエストが `X-FT-Settle: 0` を持つか(handle の冒頭で毎回入れ直す。リクエストは1本ずつ処理)。
     *  true の間は settle() と awaitScrollSettled を飛ばす。検証の待ち(回転到達等)は対象外 */
    private volatile boolean skipSettle = false;
    /** `X-FT-Settle-Mode: image` なら true。settle() を画面の静止判定(settleByImage)に差し替える。handle の冒頭で入れ直す */
    private volatile boolean imageSettle = false;
    /** 直近の settleByImage が上限で打ち切ったときの note(整定したら null)。handle の冒頭で消し、ok() / scrollAction の応答が載せる */
    private volatile String lastSettleNote = null;
    /** この要求で settleByImage が判定まで回ったときの結果(FALSE = 止まった / TRUE = 上限)。回っていなければ null。
     *  handle の冒頭で消し、ok() が `imageSettleCapped` として載せる(同期相手: BridgeDTO.swift の OKResponse.imageSettleCapped。
     *  ホストはこれが載ったときだけ木の整定を省ける) */
    private volatile Boolean lastImageSettleCapped = null;

    /** 画像整定の既定の上限(ms)= ホストが `X-FT-Settle-Cap-Ms` を送らない(UI フレームワークが分からない)とき。
     *  Android の表の最大(RN 2.3 s。表と根拠は FTCore.ImageSettleCap。片方だけ変えない)。尽きたら動いたまま返し、応答の note に残す */
    private static final long IMAGE_SETTLE_DEFAULT_CAP_MS = 2300;
    /** この要求の画像整定の上限(ms)。handle の冒頭でヘッダ(なければ既定)から入れ直す */
    private volatile long imageSettleCapMs = IMAGE_SETTLE_DEFAULT_CAP_MS;
    /** この要求の画像整定の静止窓(ms)。handle の冒頭でヘッダ(なければ IMAGE_SETTLE_QUIET_MS)から入れ直す */
    private volatile long imageSettleQuietMs = IMAGE_SETTLE_QUIET_MS;
    /**
     * 画像整定の静止窓(ms): 最後に前フレームと違った撮影からこの時間一致が続いたら整定。
     * 値はユーザー決定。根拠: 内容の動き中の描画間隔の実測最大 295 ms(CMP の画面遷移・エミュレータ・CPU 100% 負荷。
     * 150 ms では負荷時の画面遷移で 42 回中 2 回、動きの途中で返った)。スワイプは比較範囲を枠の内側 80% に絞るので、
     * 縁のスクロールバーのフェード(停止の 300 ms 後)は窓が長くても待たない。短いと動きの途中で返り、長いと全操作がその分待つ
     */
    private static final long IMAGE_SETTLE_QUIET_MS = 320;
    /**
     * エミュレータか。撮影の負担の行き先で撮り方を分ける: エミュレータの撮影はホストの CPU を使う(1枚約 22 ms・連続で
     * 1台約 1.5 コア。並列の E2E で積み上がる)ので枚数を抑える。実機は端末内で済み、撮影自体(Pixel 4a 約 50 ms)が間隔になる
     */
    private static final boolean IS_EMULATOR = "ranchu".equals(Build.HARDWARE) || "goldfish".equals(Build.HARDWARE)
            || Build.PRODUCT.startsWith("sdk_");
    /** エミュレータ: 1枚目から2枚目までの間隔(ms)。タップの描画は約 100 ms 以内に終わるので早めに2枚目で捉える */
    private static final long IMAGE_SETTLE_FIRST_GAP_MS = 50;
    /** エミュレータ: 変化が続く間の間隔の上限(ms)。50 → 100 と広げる。広げすぎると動きの終わりの検出がその分遅れる */
    private static final long IMAGE_SETTLE_MAX_INTERVAL_MS = 100;
    /** スクロール容器の枠を比べるとき各辺を削る割合(100×200 なら内側 80×160)。同期相手: BridgeDTO.swift の BridgeAPI.imageSettleRegionInsetRatio */
    private static final double IMAGE_SETTLE_REGION_INSET = 0.1;

    @Override
    public BridgeHttpServer.Response handle(BridgeHttpServer.Request request) {
        skipSettle = request.skipSettle;
        imageSettle = "image".equals(request.settleMode);
        imageSettleCapMs = request.settleCapMs > 0 ? request.settleCapMs : IMAGE_SETTLE_DEFAULT_CAP_MS;
        imageSettleQuietMs = request.settleQuietMs > 0 ? request.settleQuietMs : IMAGE_SETTLE_QUIET_MS;
        lastSettleNote = null;
        lastImageSettleCapped = null;
        try {
            String route = request.method + " " + request.path;
            switch (route) {
                case "GET /status": return handleStatus();
                case "GET /snapshot": return handleSnapshot(request);
                case "POST /tap": return handleTap(body(request));
                case "POST /type": return handleType(body(request));
                case "POST /clear": return handleClear(body(request));
                case "POST /swipe": return handleSwipe(body(request));
                case "POST /scrollAction": return handleScrollAction(body(request));
                case "POST /doubletap": return handleDoubleTap(body(request));
                case "POST /pinch": return handlePinch(body(request));
                case "POST /gesture": return handleGesture(body(request));
                case "POST /press": return handlePress(body(request));
                case "POST /pressEnter": return handlePressEnter();
                case "POST /hold": return handleHold(body(request));
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

    /** UiAutomationConnection が生きているか(handleStatus の doc)。echo が戻れば生きている */
    static boolean uiAutomationConnectionAlive(UiAutomation ua) {
        try {
            return rawShell(ua, "echo ft-alive").contains("ft-alive");
        } catch (Exception e) {
            return false;
        }
    }

    /** 応答を書き切ってから終了する(即時 exit だと ready:false の応答自体が届かない) */
    private static void scheduleExit() {
        // ラムダにしない: build.sh は android.jar を bootclasspath に -source 8 で javac するので
        // LambdaMetafactory が解決できずビルドが落ちる
        Thread t = new Thread(new Runnable() {
            @Override public void run() {
                SystemClock.sleep(EXIT_GRACE_MS);
                System.exit(0);
            }
        });
        t.setDaemon(true);
        t.start();
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
        // UiAutomationConnection(shell / screenshot / 入力注入の口)の死活。adbd の再起動
        // (adb tcpip / adb usb)でこの binder だけ死に、a11y は生きたまま = 上の root は取れる。
        // executeShellCommand は RemoteException を握って空のパイプを返す(例外にならない)ので、
        // エコーが戻るかで見る。実測 2026-09-05・Pixel 4a: DeadObjectException ×47 のまま
        // /status が ready:true を返し続け、launch/screenshot が全部 500 になった
        boolean connectionAlive = uiAutomationConnectionAlive(ua());
        JSONObject o = new JSONObject();
        o.put("ready", ready && connectionAlive);
        if (!connectionAlive) {
            o.put("reason", "uiautomation-dead");
            // 死んだ口は戻らない。自ら終了してホストに connection refused を返し、
            // AndroidBridge.ensureBridge の再セットアップ(force-stop + am instrument)へ倒す
            scheduleExit();
        }
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
        // クエリ `max=<n>` は「この1回だけ要素上限を引き上げる」契約(ホスト側 BridgeAPI の
        // resolvedSnapshotElementLimit と同じ規則: 0以下・非整数=既定、天井超え=天井へ丸める)。
        // web ページのように候補が数百ある画面で、間引きが本文テキストを丸ごと落とすのを
        // 呼び手が回避するためのもの
        int maxElements = SnapshotBuilder.resolveElementLimit(queryParam(request.query, "max"));
        // **読み直しはキャッシュごと捨てる**(API 34+)。node.refresh() はキャッシュを更新しないので、読み直した直後の
        // 素取得が古い木を返し続ける —— Compose は親の配置だけがずれた変化(縮むヘッダ)を a11y のイベントで知らせず、
        // キャッシュが払う前のまま残った(E2EY-CMP の折りたたみヘッダ: 次のタブのタップがヘッダの開いた位置を撃った)。
        // 34 未満(手元の実機 API 32/33)はホストの A11yCacheStalenessGuard(FTAndroid)が素取得を確かめて受ける
        if (forceRefresh && Build.VERSION.SDK_INT >= 34) ua().clearCache();
        SnapshotBuilder.Result result;
        try {
            result = SnapshotBuilder.build(ua(), instrumentation.getContext(), forceRefresh, maxElements);
        } catch (IllegalStateException first) {
            // root=null が waitForRoot の 2s を超えて続く一時ストール(高負荷時の画面消灯/描画停止で
            // 実測。黒スクショと対の症状)。WAKEUP 注入で display を起こしてから1回だけ再試行する
            shell("input keyevent KEYCODE_WAKEUP");
            SystemClock.sleep(WAKEUP_SETTLE_MS);
            try {
                result = SnapshotBuilder.build(ua(), instrumentation.getContext(), forceRefresh, maxElements);
            } catch (IllegalStateException second) {
                // 再試行も root=null のまま。実測 Pixel 3a/Android 12: 13〜37 秒 null が続き
                // 自然に回復した(全 4 ラウンド中 1 回再現)。生の Java 例外(BridgeRouter.handle の
                // 総括 catch → 500)ではなく、事実だけを 422 で申告する(SnapshotBuilder.java の
                // IllegalStateException 自体は内部合図として変えない)
                throw new BridgeException(422, NO_ACTIVE_WINDOW_ROOT
                        + " the device reports no accessibility root for the active window, so the UI"
                        + " tree cannot be read right now (the app switcher, a screen that is turning"
                        + " off, and a window transition all do this). It clears on its own once an"
                        + " app is in the foreground again.");
            }
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
            tapUnlessAlreadyFocused(center, refIds.get(ref));
            // 確認と注入を統合した経路(InputInjector.setTextAppendingAt のコメント参照)。
            // resource-id を渡す: キーボードの開閉で座標がズレても同じ要素を追跡し直すため
            InputInjector.setTextAppendingAt(ua(), center[0], center[1], refIds.get(ref), text, TEXT_INPUT_CONFIRM_BUDGET_MS);
        } else {
            InputInjector.setTextAppending(ua(), text);
        }
        settle();
        return ok();
    }

    /**
     * 入力の前のタップ。**対象の欄が既にフォーカスを持っていれば撃たない**: 自動でフォーカスを取る欄
     * (ダイアログの autofocus)はキーボードが上がる間に動くので、snapshot の座標を撃つと欄の外
     * (ダイアログの枠の外 = 閉じる)に当たる(実測 Flutter: prompt=cancel で閉じていた)。
     * 判定は id で引けた欄だけ(点で引いた欄は、座標が古いと別の欄でありうる)
     */
    private void tapUnlessAlreadyFocused(double[] center, String shortId) {
        if (shortId != null && InputInjector.isFocusedEditable(ua(), center[0], center[1], shortId)) return;
        InputInjector.tap(ua(), center[0], center[1]);
    }

    /** ref あり = その要素を空文字へ全置換(BridgeDTO.ClearRequest 参照)。ref なしはフォーカス欄。
     *  対象なし/SET_TEXT 拒否は 409(ホストの typeDriver フォールバックの合図。500 にしない) */
    private BridgeHttpServer.Response handleClear(JSONObject body) {
        if (body.has("ref")) {
            int ref = body.optInt("ref");
            double[] center = centerOf(ref);
            tapUnlessAlreadyFocused(center, refIds.get(ref));
            InputInjector.clearTextAt(ua(), center[0], center[1], refIds.get(ref), TEXT_INPUT_CONFIRM_BUDGET_MS);
        } else {
            InputInjector.clearFocused(ua(), TEXT_INPUT_CONFIRM_BUDGET_MS);
        }
        settle();
        return ok();
    }

    private BridgeHttpServer.Response handleSwipe(JSONObject body) {
        String direction = body.optString("direction");
        Rect screen = screenRect();
        double w = screen.width();
        double h = screen.height();
        double cx = screen.left + w / 2, cy = screen.top + h / 2;
        boolean vertical = direction.equals("up") || direction.equals("down");
        // 可変パラメータはホストが用途(FTSwipeIntent)に応じて送る(契約は FTCore/BridgeDTO.SwipeRequest)。
        // distance の既定は**軸で違う**(縦 0.4 = 0.7→0.3 / 横 0.6 = 0.8→0.2。v40 までの固定値と同一)。
        // 一律 0.4 にすると、何も送らない gesture / search の横スワイプまで黙って狭くなる。
        // 明示値は既定と同値でも必ず計算に使う(「既定と同じなら無視」だと、既定を変えた瞬間に
        // ホストの指定が黙って無視される)
        double span = body.optDouble("distance", vertical ? 0.4 : 0.6);
        long strokeMs = body.optLong("durationMs", SWIPE_DEFAULT_STROKE_MS);
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
            // path.region(任意・px・画面座標 {x,y,width,height})= 画像整定の比較範囲。無ければ画面全体。
            // どちらも settleByImage が各辺 IMAGE_SETTLE_REGION_INSET を削る(縁のスクロールバーを外す)
            Rect region = new Rect(screen);
            JSONObject r = path.optJSONObject("region");
            if (r != null) {
                int rx = (int) Math.round(r.optDouble("x")), ry = (int) Math.round(r.optDouble("y"));
                int rw = (int) Math.round(r.optDouble("width")), rh = (int) Math.round(r.optDouble("height"));
                if (rw > 0 && rh > 0) region = new Rect(rx, ry, rx + rw, ry + rh);
            }
            settle("swipe", region);
            return ok();
        }
        switch (direction) {
            case "up": from = new double[]{cx, screen.top + h * (0.5 + half)}; to = new double[]{cx, screen.top + h * (0.5 - half)}; break;
            case "down": from = new double[]{cx, screen.top + h * (0.5 - half)}; to = new double[]{cx, screen.top + h * (0.5 + half)}; break;
            case "left": from = new double[]{screen.left + w * (0.5 + half), cy}; to = new double[]{screen.left + w * (0.5 - half), cy}; break;
            case "right": from = new double[]{screen.left + w * (0.5 - half), cy}; to = new double[]{screen.left + w * (0.5 + half), cy}; break;
            default:
                throw new BridgeException(400, "direction must be one of up/down/left/right");
        }
        InputInjector.swipe(ua(), from[0], from[1], to[0], to[1], strokeMs, syntheticUp);
        settle("swipe", new Rect(screen));  // 容器の枠が無いスワイプも画面全体の内側で比べる
        return ok();
    }

    /**
     * 端送りの1本を a11y のスクロール操作で送る(契約は BridgeDTO.ScrollActionRequest / ScrollActionResponse)。
     * 指のドラッグは端を越えた余りが入れ子の親(SwipeRefreshLayout・PullToRefresh)へ渡り、上端へ戻す最後の1本が
     * 引っ張って更新に化ける。a11y の操作は容器の中だけを動かすので親へ渡らない。
     * 宛先は (x, y) を含み**軸が指の向きと一致する**最小の scrollable(ホストの scrollContainerElement と同じ
     * 「最小」の規則。軸を見るのは、中央に横のカルーセルがある縦の一覧で横へ送らないため)。
     * - 軸が分からない容器は候補にしない(汎用の backward/forward は軸を言わない)
     * - 候補はあるが送る向きの操作を申告していない = もう端 → atEdge:true(ドラッグを撃たせない)
     * - 候補が無い・performAction が false → performed:false(ホストは従来のドラッグへ落ちる)
     */
    private BridgeHttpServer.Response handleScrollAction(JSONObject body) throws JSONException {
        String finger = body.optString("finger");
        boolean vertical;
        switch (finger) {
            case "up": case "down": vertical = true; break;
            case "left": case "right": vertical = false; break;
            default: throw new BridgeException(400, "finger must be one of up/down/left/right");
        }
        if (!body.has("x") || !body.has("y")) throw new BridgeException(400, "x/y is required");
        int x = (int) Math.round(body.optDouble("x"));
        int y = (int) Math.round(body.optDouble("y"));
        AccessibilityNodeInfo root = ua().getRootInActiveWindow();
        JSONObject o = new JSONObject();
        AccessibilityNodeInfo target = root == null ? null : smallestScrollableOnAxis(root, x, y, vertical, 0);
        if (target == null) {
            o.put("performed", false);
            return BridgeHttpServer.Response.json(200, o.toString());
        }
        AccessibilityNodeInfo.AccessibilityAction action = scrollActionFor(target, finger, vertical);
        if (action == null) {
            // **最小の容器が端でも、それを包む容器がまだ送れることがある**: 伸縮するヘッダ(AppBarLayout)は
            // 一覧が先頭に着いた後も縮んだままで、開く操作は外側(CoordinatorLayout)が申告する。
            // 引っ張って更新の親は送る操作を申告しないので、ここで拾っても更新は引かない
            AccessibilityNodeInfo outer = enclosingScrollableWithAction(target, finger, vertical);
            if (outer != null) {
                target = outer;
                action = scrollActionFor(outer, finger, vertical);
            }
        }
        if (action == null) {
            o.put("performed", false);
            o.put("atEdge", true);
            return BridgeHttpServer.Response.json(200, o.toString());
        }
        boolean performed = target.performAction(action.getId());
        if (performed) {
            // 画像整定は a11y の矩形ポーリングを包含するので二重に待たない
            if (!skipSettle && !imageSettle) awaitScrollSettled(target);
            settle("scrollAction", screenRect());  // スクロールなので画面全体の内側で比べる(容器の枠は届かない)
        }
        o.put("performed", performed);
        if (lastSettleNote != null) o.put("note", lastSettleNote);
        return BridgeHttpServer.Response.json(200, o.toString());
    }

    /** 読み直しの間隔(ms)。Compose の a11y スクロールはアニメーション(実測 数百 ms)なので、1 フレームより長く・
     *  アニメーションより十分短く */
    private static final long SCROLL_SETTLE_POLL_MS = 60;
    /** 待ちの上限(ms)。尽きたら動いている途中のまま返す(ホストの整定待ちと署名の比較が後を受ける) */
    private static final long SCROLL_SETTLE_CAP_MS = 1500;

    /**
     * a11y のスクロールが**止まるまで**待つ。Compose は performAction の後にアニメーションで動かし、settle()
     * (a11y イベントの静穏)はその途中で返る。途中の木を読むとスクロール操作の申告が欠け、ホストが「もう端」と
     * 誤って打ち切った(実測: E2EX-CMP の scrollToTop が 0.29 秒で止まり先頭行に届かなかった)。
     * 子の矩形が2回続けて同じになったら止まったとみなす
     */
    private static void awaitScrollSettled(AccessibilityNodeInfo node) {
        long deadline = SystemClock.uptimeMillis() + SCROLL_SETTLE_CAP_MS;
        String previous = null;
        while (SystemClock.uptimeMillis() < deadline) {
            SystemClock.sleep(SCROLL_SETTLE_POLL_MS);
            if (!node.refresh()) return;
            String current = childBoundsSignature(node);
            if (current.equals(previous)) return;
            previous = current;
        }
    }

    private static String childBoundsSignature(AccessibilityNodeInfo node) {
        StringBuilder sb = new StringBuilder();
        Rect bounds = new Rect();
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            child.refresh();
            child.getBoundsInScreen(bounds);
            sb.append(bounds.toShortString());
        }
        return sb.toString();
    }

    /** 深さの上限。木の実測は深くても 40 段台(ループする木への備えで、届く画面は無い) */
    private static final int SCROLL_ACTION_MAX_DEPTH = 96;

    private static AccessibilityNodeInfo smallestScrollableOnAxis(AccessibilityNodeInfo node, int x, int y,
                                                                  boolean vertical, int depth) {
        if (node == null || depth > SCROLL_ACTION_MAX_DEPTH) return null;
        AccessibilityNodeInfo best = null;
        long bestArea = Long.MAX_VALUE;
        Rect bounds = new Rect();
        node.getBoundsInScreen(bounds);
        if (node.isScrollable() && bounds.contains(x, y)) {
            // **操作の申告はキャッシュから読まない**: 直前のスクロールの後、キャッシュのノードは送れる向きが
            // 古いままのことがあり、動かせる一覧を「もう端」と答える(Compose の a11y キャッシュ遅れと同じ型)
            node.refresh();
            node.getBoundsInScreen(bounds);
            int axis = scrollAxis(node);
            if (axis == (vertical ? 1 : 2)) {
                best = node;
                bestArea = (long) bounds.width() * bounds.height();
            }
        }
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo found = smallestScrollableOnAxis(node.getChild(i), x, y, vertical, depth + 1);
            if (found == null) continue;
            Rect b = new Rect();
            found.getBoundsInScreen(b);
            long area = (long) b.width() * b.height();
            if (area <= bestArea) {
                best = found;
                bestArea = area;
            }
        }
        return best;
    }

    /** node を包む祖先のうち、軸が一致して送る向きの操作を申告している最も近いもの。無ければ null */
    private static AccessibilityNodeInfo enclosingScrollableWithAction(AccessibilityNodeInfo node, String finger,
                                                                       boolean vertical) {
        AccessibilityNodeInfo parent = node.getParent();
        for (int depth = 0; parent != null && depth < SCROLL_ACTION_MAX_DEPTH; depth++) {
            if (parent.isScrollable() && parent.refresh()
                    && scrollAxis(parent) == (vertical ? 1 : 2)
                    && scrollActionFor(parent, finger, vertical) != null) {
                return parent;
            }
            parent = parent.getParent();
        }
        return null;
    }

    /**
     * 容器の軸: 1 = 縦 / 2 = 横 / 0 = 分からない。方向つきの操作(API 23)を申告していればそれで決まる。
     * RecyclerView は汎用の backward/forward しか申告しないので CollectionInfo(縦の一覧は列 1・横は行 1)、
     * ScrollView 系はクラス名で決める。グリッド(行も列も 2 以上)は分からない側
     */
    private static int scrollAxis(AccessibilityNodeInfo node) {
        List<AccessibilityNodeInfo.AccessibilityAction> actions = node.getActionList();
        boolean v = actions.contains(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_UP)
                || actions.contains(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_DOWN);
        boolean h = actions.contains(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT)
                || actions.contains(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT);
        if (v != h) return v ? 1 : 2;
        AccessibilityNodeInfo.CollectionInfo info = node.getCollectionInfo();
        if (info != null) {
            if (info.getColumnCount() <= 1 && info.getRowCount() > 1) return 1;
            if (info.getRowCount() <= 1 && info.getColumnCount() > 1) return 2;
        }
        CharSequence cls = node.getClassName();
        String name = cls == null ? "" : cls.toString();
        if (name.endsWith("HorizontalScrollView")) return 2;
        if (name.endsWith("ScrollView")) return 1;
        return 0;
    }

    /**
     * 指の向きに中身を動かす操作。**指と中身は逆向き**(指を下へ = 先頭側 = UP / BACKWARD。
     * FTCore.ScrollActionAvailability と同じ対応。片方だけ変えない)。方向つきを先に採り、
     * 汎用は軸が一致している容器(呼び手が保証)でだけ使う。RTL の横送りは考えない
     */
    private static AccessibilityNodeInfo.AccessibilityAction scrollActionFor(AccessibilityNodeInfo node,
                                                                             String finger, boolean vertical) {
        List<AccessibilityNodeInfo.AccessibilityAction> actions = node.getActionList();
        AccessibilityNodeInfo.AccessibilityAction directional;
        AccessibilityNodeInfo.AccessibilityAction generic;
        switch (finger) {
            case "down":
                directional = AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_UP;
                generic = AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_BACKWARD; break;
            case "up":
                directional = AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_DOWN;
                generic = AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD; break;
            case "right":
                directional = AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT;
                generic = AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_BACKWARD; break;
            default:
                directional = AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT;
                generic = AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD; break;
        }
        if (actions.contains(directional)) return directional;
        if (actions.contains(generic)) return generic;
        return null;
    }

    /** ダブルタップ(ref または x/y。iOS ブリッジと同じ受理形) */
    private BridgeHttpServer.Response handleDoubleTap(JSONObject body) {
        double[] point = resolvePoint(body);
        InputInjector.doubleTap(ua(), point[0], point[1]);
        settle();
        return ok();
    }

    /**
     * gesture / pinch が共有する「fingers の JSON → 検査済み double[i][j] = {x,y,t}」変換。
     * 本数上限・点数上限は MAX_GESTURE_FINGERS / MAX_GESTURE_POINTS_PER_FINGER
     * (Swift の BridgeAPI.gestureMaxFingers / .gestureMaxPointsPerFinger と同じ値。
     * cross-language なので GestureLimitsSyncTests が Swift 側の値との一致を固定する)。
     * 本数の**下限**は呼び手ごとに違う(gesture は1本から・pinch はちょうど2本)ので、
     * ここでは「空でない」だけを見て、下限は呼び手が別途検査する。
     */
    private static double[][][] parseFingers(JSONArray fingersJson) {
        if (fingersJson == null || fingersJson.length() == 0) {
            throw new BridgeException(400, "a gesture needs at least one finger");
        }
        if (fingersJson.length() > MAX_GESTURE_FINGERS) {
            throw new BridgeException(400, "a gesture can use at most " + MAX_GESTURE_FINGERS
                    + " fingers (got " + fingersJson.length() + ")");
        }
        double[][][] fingers = new double[fingersJson.length()][][];
        for (int i = 0; i < fingersJson.length(); i++) {
            JSONObject fingerObj = fingersJson.optJSONObject(i);
            JSONArray pointsJson = fingerObj == null ? null : fingerObj.optJSONArray("points");
            if (pointsJson == null || pointsJson.length() < 2) {
                throw new BridgeException(400, "finger " + (i + 1)
                        + " needs at least two points (where it touches down and where it lifts)");
            }
            if (pointsJson.length() > MAX_GESTURE_POINTS_PER_FINGER) {
                throw new BridgeException(400, "finger " + (i + 1) + " has " + pointsJson.length()
                        + " points; at most " + MAX_GESTURE_POINTS_PER_FINGER + " are allowed");
            }
            double[][] points = new double[pointsJson.length()][3];
            double previousT = -1;
            for (int j = 0; j < pointsJson.length(); j++) {
                JSONObject p = pointsJson.optJSONObject(j);
                double x = p == null ? Double.NaN : p.optDouble("x", Double.NaN);
                double y = p == null ? Double.NaN : p.optDouble("y", Double.NaN);
                double t = p == null ? Double.NaN : p.optDouble("t", Double.NaN);
                if (!Double.isFinite(x) || !Double.isFinite(y) || !Double.isFinite(t)) {
                    throw new BridgeException(400, "finger " + (i + 1) + ", point " + (j + 1)
                            + ": x/y/t must be finite numbers");
                }
                if (t < 0 || t < previousT) {
                    throw new BridgeException(400, "finger " + (i + 1) + ", point " + (j + 1)
                            + ": t must not go backwards (got " + t + " after " + previousT + ")");
                }
                previousT = t;
                points[j][0] = x;
                points[j][1] = y;
                points[j][2] = t;
            }
            if (!(points[points.length - 1][2] > points[0][2])) {
                throw new BridgeException(400, "finger " + (i + 1) + " lifts at the moment it touches down");
            }
            fingers[i] = points;
        }
        return fingers;
    }

    /** 全指の中で最後に離れる時刻(秒)。gesture の総所要 = pinch の総所要 */
    private static double totalSeconds(double[][][] fingers) {
        double total = 0;
        for (double[][] finger : fingers) {
            total = Math.max(total, finger[finger.length - 1][2]);
        }
        return total;
    }

    /**
     * 2本指のピンチ。**指の置き方はホストが決める**(`FTCore.PinchGesture`。1つの規則を OS ごとに
     * 持つのは BridgeDTO.PinchRequest.fingers のドキュメント参照)—— ここは指を組まず、host が
     * 組んだ2本指の経路(fingers)をそのまま `InputInjector.gesture` へ渡して再生するだけ。
     * PinchRequest.identifier は iOS 専用(XCUITest は座標指定の多点ジェスチャを持たないため
     * 要素を掴むしかない)で、こちらは読まない。
     */
    private BridgeHttpServer.Response handlePinch(JSONObject body) {
        double scale = body.optDouble("scale", 0);
        if (!(scale > 0) || scale == 1 || Double.isInfinite(scale)) {
            throw new BridgeException(400, "scale must be positive and not 1 (received: " + scale + ")");
        }
        double[][][] fingers = parseFingers(body.optJSONArray("fingers"));
        if (fingers.length != 2) {
            throw new BridgeException(400, "pinch needs exactly 2 fingers (got " + fingers.length + ")");
        }
        double totalSeconds = totalSeconds(fingers);
        if (totalSeconds > GESTURE_SECONDS_CEILING) {
            throw new BridgeException(400, "the total duration of pinch must be "
                    + GESTURE_SECONDS_CEILING + " seconds or less (got " + totalSeconds + ")");
        }
        InputInjector.gesture(ua(), fingers);
        settle();
        return ok();
    }

    /**
     * 指ごとの時刻つき経路を1回の多点タッチ列として再生する(DSL の gesture / MCP の ft_gesture)。
     * 契約は Sources/FTCore/BridgeDTO.swift の GestureRequest(座標は px・t はジェスチャ開始からの秒)。
     * **ホストは FTCore/TouchGesture.validate を通した形だけを送るが、ここでも同じ上限で断る**
     * (古いホスト・直叩きから InputInjector.press と同じ理由で守る最後の砦。parseFingers を pinch と共有)。
     * 点の間の補間・タッチの合成は InputInjector.gesture に委ねる(ここは検査と JSON→配列の変換だけ)。
     */
    private BridgeHttpServer.Response handleGesture(JSONObject body) {
        double[][][] fingers = parseFingers(body.optJSONArray("fingers"));
        double totalSeconds = totalSeconds(fingers);
        if (totalSeconds > GESTURE_SECONDS_CEILING) {
            throw new BridgeException(400, "the total duration of gesture must be "
                    + GESTURE_SECONDS_CEILING + " seconds or less (got " + totalSeconds + ")");
        }
        InputInjector.gesture(ua(), fingers);
        settle();
        return ok();
    }

    private BridgeHttpServer.Response handlePress(JSONObject body) {
        // ref または x/y(iOS ブリッジと同じ受理形。ホストは ref を自前解決して x/y で送る)
        double[] center = resolvePoint(body);
        double duration = body.optDouble("duration", PRESS_DEFAULT_SECONDS);
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

    /**
     * 指を置いたら応答を返し、duration 秒後に別スレッドが離す(契約は FTCore/BridgeDTO.HoldRequest)。
     * このブリッジは要求を1本ずつ処理するので、/press のように離すまで待つと、押している間は木も
     * スクショも返せない(押している間だけ出る部品を検証できない)。
     * **同時に置ける指は1本**: 前の指が離れる前の /hold は 409(2本目の DOWN は別のジェスチャに化ける)
     */
    private BridgeHttpServer.Response handleHold(JSONObject body) {
        if (!body.has("x") || !body.has("y") || !body.has("duration")) {
            throw new BridgeException(400, "x, y and duration are required");
        }
        if (!InputInjector.holdWithoutWaiting(ua(), body.optDouble("x"), body.optDouble("y"),
                body.optDouble("duration"))) {
            throw new BridgeException(409, "a finger placed by an earlier hold is still down");
        }
        return ok();
    }

    private BridgeHttpServer.Response handleScreenshot() {
        Bitmap bitmap = ua().takeScreenshot();
        if (bitmap == null) {
            assertConnectionAlive(ua());
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
            // monkey はプロビジョニング直後の AVD などで理由なく失敗することがある(実測 exit 251)。
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
            // アクティブウィンドウはシステムのダイアログだが、その下にアプリのウィンドウが見えている
            // = アプリは前面に来ている(権限ダイアログが起動直後に出る形)。上限まで待たずに成功
            if (pkg != null && SYSTEM_DIALOG_PACKAGES.contains(pkg) && hasWindowOf(bundleID)) {
                android.util.Log.i(BridgeInstrumentation.TAG, "launch: " + bundleID
                        + " is in front under a system dialog (" + pkg + ")");
                break;
            }
            if (SystemClock.uptimeMillis() >= deadline) {
                return false;
            }
            SystemClock.sleep(FOREGROUND_POLL_MS);
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
        // attemptLaunch が shell("am force-stop " + bundleID) 等へ連結する。executeShellCommand は sh を
        // 通さず空白で区切るので、空白入りの名前は別の引数に化ける(sessionBundleID にも残る)
        if (!isShellSafePackageName(bundleID)) {
            throw new BridgeException(400, "not a valid Android package name: \"" + bundleID
                    + "\" (letters, digits, '_' and '.' only, starting with a letter)");
        }
        // キーボードの初回シートを、アプリを出す前に済ませる(言語ごとに1回。ImeOnboarding の冒頭コメント)
        ImeOnboarding.primeOnce(instrumentation, ua());
        if (attemptLaunch(bundleID)) return ok();
        // 前面判定が別パッケージの居座りで詰んだ。前面を掃除して1回だけ再試行する。
        // force-stop が bundleID しか殺さないと以後の launchApp が全滅する既知の罠(design.md §8.7)。
        // 掃除対象は bundleID 自身・ブリッジ自身・HOME ランチャー・システムのダイアログ
        // (SYSTEM_DIALOG_PACKAGES)を除いた前面パッケージのみ。
        String stuck = activePackage();
        if (stuck != null && SYSTEM_DIALOG_PACKAGES.contains(stuck) && hasWindowOf(bundleID)) {
            // 権限ダイアログ・Custom Tab 等がアプリの上に乗っている(アプリの窓は見えている)。
            // 殺すとアプリの権限フローが壊れ、再試行の force-stop がアプリごと畳んで「前面に来ない」を
            // 作る。前面として成功を返し、ダイアログの扱いはホスト(system-alert の注記・操作)に委ねる。
            // **アプリの窓が見えない全画面の居座り**(設定の上の SafetyCenter = design.md §8.7)は
            // 従来どおり下の掃除+再試行へ落とす
            android.util.Log.i(BridgeInstrumentation.TAG, "launch: " + bundleID
                    + " reported as in front under a system dialog (" + stuck + "); not force-stopping");
            return ok();
        }
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

    /** bundleID のウィンドウが可視ウィンドウ一覧(getWindows。FLAG_RETRIEVE_INTERACTIVE_WINDOWS 前提)に
     *  居るか。全画面で覆われたアクティビティは一覧に載らないので「ダイアログ越しに見えている」の証拠になる */
    private boolean hasWindowOf(String bundleID) {
        try {
            List<android.view.accessibility.AccessibilityWindowInfo> windows = ua().getWindows();
            if (windows == null) return false;
            for (android.view.accessibility.AccessibilityWindowInfo window : windows) {
                AccessibilityNodeInfo root = window.getRoot();
                if (root != null && root.getPackageName() != null
                        && bundleID.equals(root.getPackageName().toString())) {
                    return true;
                }
            }
        } catch (RuntimeException ignored) {
            // 一覧が取れない環境では証拠なし(上限まで待つ従来の経路へ)
        }
        return false;
    }

    /**
     * 既定スワイプ・ピンチの基準矩形。直近の /snapshot が報告した screen があればそれ、無ければ
     * (ブリッジ起動後まだ撮っていない `launchApp → swipe` の形)ディスプレイの実寸を引く。
     * 固定の既定値は置かない —— 1080x2400 を仮定すると別解像度の端末で座標が画面外へ出て
     * 黙って空振りしていた。取り方は SnapshotBuilder.displayBounds と同じ
     * (API 30+: getMaximumWindowMetrics / 未満: getRealMetrics。minSdk 26)。どちらも取れなければ
     * アクティブウィンドウの根の矩形、それも無ければ 500(推測で撃たない)。
     */
    private Rect screenRect() {
        if (lastScreen.width() > 0 && lastScreen.height() > 0) return lastScreen;
        try {
            android.content.Context ctx = instrumentation.getContext();
            android.view.WindowManager wm = ctx == null ? null
                    : (android.view.WindowManager) ctx.getSystemService(android.content.Context.WINDOW_SERVICE);
            if (wm != null) {
                if (Build.VERSION.SDK_INT >= 30) {
                    Rect bounds = wm.getMaximumWindowMetrics().getBounds();
                    if (bounds.width() > 0 && bounds.height() > 0) return bounds;
                } else {
                    android.view.Display display = wm.getDefaultDisplay();
                    if (display != null) {
                        android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
                        display.getRealMetrics(metrics);
                        if (metrics.widthPixels > 0 && metrics.heightPixels > 0) {
                            return new Rect(0, 0, metrics.widthPixels, metrics.heightPixels);
                        }
                    }
                }
            }
        } catch (RuntimeException ignored) {
            // 取れなければウィンドウの根へ
        }
        AccessibilityNodeInfo root = ua().getRootInActiveWindow();
        if (root != null) {
            Rect bounds = new Rect();
            root.getBoundsInScreen(bounds);
            if (bounds.width() > 0 && bounds.height() > 0) return bounds;
        }
        throw new BridgeException(500,
                "cannot determine the display size for the gesture. Run GET /snapshot first");
    }

    /**
     * 先頭が英字・残りが英数字 / `_` / `.` だけ。**同期相手: Sources/FTAndroid/AndroidPackageName.swift の
     * isShellSafe**(AndroidPackageNameTests.testBridgeLaunchUsesTheSameGrammar が正規表現の一致を見る)
     */
    static boolean isShellSafePackageName(String name) {
        return name.matches("[A-Za-z][A-Za-z0-9_.]*");
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
        settle(tag, null);
    }

    /** region は画像整定の比較範囲(スクロール容器の px 矩形)。従来の整定では使わない */
    private void settle(String tag, Rect region) {
        if (skipSettle) return;  // X-FT-Settle: 0(POST /settle 自身もここで即返る)
        if (imageSettle) {
            settleByImage(tag, region);
            return;
        }
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

    /** a11y イベントの静穏待ち(stableActivePackage + quietWait)。settle() と画像整定の並走スレッドが共有する */
    private void a11yQuietWait() {
        String startPackage = stableActivePackage(STABLE_PACKAGE_BUDGET_MS);
        quietWaiter.quietWait(startPackage, QuietWaiter.QUIET_MS, QuietWaiter.ACTION_CAP_MS);
    }

    /**
     * スクリーンショットを連続で撮り続け、直近の「前フレームと違った撮影」から imageSettleQuietMs 経つまで
     * 一致が続いたら整定とみなす(連続2枚一致では足りない: 2枚が表示1フレーム内に収まりうる・動きの出だしが遅れる)。
     * 撮影の開始時刻は nextCaptureAt(実機は連続・エミュレータは間引く)。Bitmap 同士で比べ(閾値0)、PNG エンコードは挟まない。
     * 上限(imageSettleCapMs)まで動き続けたら返し lastSettleNote を立てる。Bitmap は必ず recycle する。
     * a11y の静穏待ち(a11yQuietWait)を別スレッドで並走させ、両方終わってから返す: 画像の静止はピクセルが止まった証明で
     * しかなく、アクセシビリティ木が画面に追いついた保証は無い(Compose は木がピクセルより遅れる。iOS CMP の E2E 失敗で確認)。
     * 静穏待ちの静穏期間 200 ms は静止窓 320 ms に収まるので並走の追加コストはほぼ無く、上限は ACTION_CAP_MS で抑えられる。
     * スレッド安全: QuietWaiter は lock の内側でだけ target / lastRelevantEventMs を触り、同時に走る quietWait は
     * 要求が直列なので常に1本。並走スレッドは ua() の IPC(getRootInActiveWindow)だけで、撮影スレッドの takeScreenshot と
     * 状態を共有しない。撮れない(null)ときは並走中の静穏待ちを待って返す。
     * region 非null(スクロール容器の px 矩形)ならその範囲だけ比べる: スクロールは容器の中身が止まれば
     * よく、容器外で動き続ける要素(バナー・スピナー)に整定を握らせない。矩形は撮影サイズへ丸める
     */
    private void settleByImage(String tag, Rect region) {
        long t0 = SystemClock.uptimeMillis();
        long lastChangeAt = t0;
        long firstAt = t0;
        long lastAt = t0;
        int changeStreak = 0;
        boolean lastChanged = false;
        int frames = 0;
        boolean settled = false;
        Bitmap prev = null;
        final long quietMs = imageSettleQuietMs;
        Thread quietThread = new Thread(new Runnable() {
            @Override public void run() {
                try { a11yQuietWait(); } catch (RuntimeException ignored) { /* 待ちが取れないだけ。画像側の判定は続ける */ }
            }
        }, "ft-a11y-quiet");
        quietThread.start();
        long loopEnd = t0;
        try {
            while (true) {
                if (frames > 0) {
                    long target = Math.min(nextCaptureAt(IS_EMULATOR, frames, firstAt, lastAt, lastChangeAt,
                            changeStreak, lastChanged, quietMs), t0 + imageSettleCapMs);
                    long wait = target - SystemClock.uptimeMillis();
                    if (wait > 0) SystemClock.sleep(wait);
                }
                Bitmap full = ua().takeScreenshot();
                if (full == null) {
                    if (prev != null) { prev.recycle(); prev = null; }
                    joinQuietThread(quietThread);
                    return;
                }
                long now = SystemClock.uptimeMillis();
                Bitmap b = full;
                if (region != null) {
                    // 縁のスクロールバー(止まった後もフェードで変わる)を外すため、各辺を IMAGE_SETTLE_REGION_INSET だけ内側へ削る
                    int dx = (int) Math.round(region.width() * IMAGE_SETTLE_REGION_INSET);
                    int dy = (int) Math.round(region.height() * IMAGE_SETTLE_REGION_INSET);
                    int x = Math.max(0, Math.min(region.left + dx, full.getWidth() - 1));
                    int y = Math.max(0, Math.min(region.top + dy, full.getHeight() - 1));
                    int w = Math.max(1, Math.min(region.width() - 2 * dx, full.getWidth() - x));
                    int h = Math.max(1, Math.min(region.height() - 2 * dy, full.getHeight() - y));
                    b = Bitmap.createBitmap(full, x, y, w, h);
                    if (b != full) full.recycle();  // 全面一致の矩形は同一インスタンスが返る
                }
                frames++;
                lastAt = now;
                if (frames == 1) {
                    firstAt = now;
                    lastChangeAt = now;
                    lastChanged = false;
                } else if (!prev.sameAs(b)) {
                    lastChangeAt = now;
                    lastChanged = true;
                    changeStreak++;
                } else {
                    lastChanged = false;
                    changeStreak = 0;
                }
                if (prev != null) prev.recycle();
                prev = b;
                if (now - lastChangeAt >= quietMs) { settled = true; break; }
                if (now - t0 >= imageSettleCapMs) break;
            }
            loopEnd = SystemClock.uptimeMillis();
        } finally {
            if (prev != null) prev.recycle();
        }
        joinQuietThread(quietThread);
        // 文言は BridgeAPI.imageSettleCapNote(seconds:) と同じ形(ホストは末尾の "(image settle cap)" で識別する)
        lastSettleNote = settled ? null : "screen kept changing for " + (imageSettleCapMs / 1000.0) + "s (image settle cap)";
        lastImageSettleCapped = settled ? Boolean.FALSE : Boolean.TRUE;
        if (BridgeInstrumentation.timingEnabled) {
            android.util.Log.i(BridgeInstrumentation.TAG, "settleTiming " + tag + " image frames=" + frames
                    + " elapsed=" + (SystemClock.uptimeMillis() - t0) + " settled=" + settled
                    + " quiet=" + quietMs + " emulator=" + IS_EMULATOR
                    + " quietJoinMs=" + (SystemClock.uptimeMillis() - loopEnd)
                    + " region=" + (region != null ? "yes" : "no"));
        }
    }

    /**
     * 画像整定の次の撮影開始時刻(uptime ms)。時刻はどれも撮影の終了時刻。実機は待たない(= lastAt)。エミュレータは
     * ①1枚目の FIRST_GAP 後 ②変化が続く間は 50 → MAX_INTERVAL と広げる ③一致したら窓の中間と満了時刻の2点だけ撮る
     * (満了時刻ちょうどに撮るので、窓が満ちてから次の撮影を待つ遅れが無い)。
     * 根拠(密な撮影記録の上の再生・Emulator 4 SUT・平常と CPU 100% 負荷): 固定 100 ms 間隔と同じ撮影枚数で
     * 応答が平常 20〜50 ms・負荷時 50〜100 ms 短い。窓の中で変化して元の絵に戻る(2点では見えない)事象は約 300 操作で 0 件
     */
    static long nextCaptureAt(boolean emulator, int frames, long firstAt, long lastAt, long lastChangeAt,
                              int changeStreak, boolean lastChanged, long quietMs) {
        if (!emulator) return lastAt;
        if (frames == 1) return firstAt + IMAGE_SETTLE_FIRST_GAP_MS;
        if (lastChanged) {
            return lastAt + (changeStreak <= 1 ? IMAGE_SETTLE_FIRST_GAP_MS : IMAGE_SETTLE_MAX_INTERVAL_MS);
        }
        long mid = lastChangeAt + quietMs / 2;
        if (mid > lastAt) return mid;
        return Math.max(lastAt, lastChangeAt + quietMs);
    }

    /** 並走の静穏待ちスレッドの終了を待つ。上限は quietWait 自身の ACTION_CAP_MS + stableActivePackage の予算(+余裕)。
     *  割り込まれたら中断フラグを戻して待ちを諦める */
    private void joinQuietThread(Thread t) {
        try {
            t.join(QuietWaiter.ACTION_CAP_MS + STABLE_PACKAGE_BUDGET_MS + 500);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
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
            SystemClock.sleep(PACKAGE_RECHECK_MS);
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

    /** 出力が空なら口の死活を確かめてから返す(死んでいれば 503 + exit。handleStatus の doc) */
    private String shell(String command) {
        String out = rawShell(ua(), command);
        if (out.isEmpty()) assertConnectionAlive(ua());
        return out;
    }

    /** 死活を見ない素の shell。alive の判定自身が使う(shell() 経由だと再帰する) */
    static String rawShell(UiAutomation ua, String command) {
        try {
            ParcelFileDescriptor pfd = ua.executeShellCommand(command);
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

    /**
     * 口が死んでいれば 503 を投げて自ら exit する。**操作系(shell・screenshot・入力注入)が
     * 黙って通らないための共通の門** —— 死んだ口では executeShellCommand は空・takeScreenshot は
     * null・injectInputEvent は false を返すだけで例外にならない(handleStatus の doc)
     */
    static void assertConnectionAlive(UiAutomation ua) {
        if (uiAutomationConnectionAlive(ua)) return;
        scheduleExit();
        throw new BridgeException(503,
                "the UiAutomation connection is dead (adbd restarted?): the bridge is exiting"
                + " so the host can rebuild it — retry the step");
    }

    /** 画像整定が上限で打ち切られていれば note を載せる(settle() を呼ぶ全ルートの共通の出口) */
    private BridgeHttpServer.Response ok() {
        String note = lastSettleNote;
        Boolean capped = lastImageSettleCapped;
        StringBuilder body = new StringBuilder("{\"ok\":true");
        if (note != null) body.append(",\"note\":\"").append(note).append('"');  // 文言は固定の英数字(引用符を含まない)
        if (capped != null) body.append(",\"imageSettleCapped\":").append(capped.booleanValue());
        return BridgeHttpServer.Response.json(200, body.append('}').toString());
    }
}
