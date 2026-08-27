// SnapshotBuilder.java
// AccessibilityNodeInfo ツリー → BridgeDTO.SnapshotResponse 互換 JSON。
// フィルタ・型語彙マップ・テキスト昇格・ref 採番の**唯一の実装**(ホスト側に揃えるべき相方は
// 無い。iOS 側との型語彙の対応は Runner/FleetestRunnerUITests を参照)。
package com.example.ftbridge;

import android.app.UiAutomation;
import android.content.Context;
import android.graphics.Rect;
import android.os.Build;
import android.os.SystemClock;
import android.view.Display;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

final class SnapshotBuilder {

    /** BridgeAPI.maxSnapshotElements と同期(4Kトークン対策) */
    static final int MAX_ELEMENTS = 120;

    /** BridgeAPI.maxSnapshotElementsCeiling と同期(`?max=` で引き上げられる天井) */
    static final int MAX_ELEMENTS_CEILING = 400;

    /**
     * `?max=` の解釈。**規則は BridgeAPI.resolvedSnapshotElementLimit と同じ**
     * (null・非整数・0以下 = 既定、天井超え = 天井へ丸める)。片方だけ変えないこと
     */
    static int resolveElementLimit(String raw) {
        if (raw == null || raw.isEmpty()) return MAX_ELEMENTS;
        int value;
        try {
            value = Integer.parseInt(raw);
        } catch (NumberFormatException e) {
            return MAX_ELEMENTS;
        }
        if (value <= 0) return MAX_ELEMENTS;
        return Math.min(value, MAX_ELEMENTS_CEILING);
    }

    static final class Result {
        final String json;
        final Map<Integer, double[]> refCenters;  // ref → {centerX, centerY}
        /// ref → 短縮 resource-id(無い要素はキー無し)。/type・/clear が**座標がズレても同じ要素を
        /// 追跡し直す**ために使う(キーボードの開閉で adjustResize が走ると座標は当てにならない)
        final Map<Integer, String> refIds;
        final Rect screen;
        Result(String json, Map<Integer, double[]> refCenters, Map<Integer, String> refIds,
               Rect screen) {
            this.json = json;
            this.refCenters = refCenters;
            this.refIds = refIds;
            this.screen = screen;
        }
    }

    /** uiautomator dump の XML ノードに相当する中間表現 */
    private static final class UINode {
        String className = "";
        String text = "";
        String contentDesc = "";
        String resourceID = "";
        String hint = "";
        boolean clickable;
        boolean checkable;
        boolean checked;
        /** タブ・選択行の選択状態(isChecked とは別軸。checked へ OR して出す。collect 参照) */
        boolean selected;
        /** clearInput 事後検証用(BridgeDTO.ElementInfo.focused 参照) */
        boolean focused;
        /** スクロールできる容器か(BridgeDTO.ElementInfo.scrollable 参照) */
        boolean scrollable;
        /** 根から自分までの描画順の並び(各段は API24+ の getDrawingOrder)。
         *  **preorder は描画順ではない** —— ViewGroup は elevation で子を並べ替えるので、
         *  木で後に出る要素が奥にあることがある(実測: Google マップは地図の FAB を
         *  シートより後に出すが、描画はシートが手前)。
         *  **単体の getDrawingOrder はホストでは合成できない**: 出力ツリーは中間ノードを
         *  間引くので、2要素の共通祖先が木に残っていない。だから**根からの並びをここで持ち**、
         *  最後に辞書式で並べて 1 本の整数 z にしてから送る(assignPaintOrder) */
        int[] zPath = new int[0];
        /** 塗り順(0 起点の通し番号。大きいほど手前)。BridgeDTO.ElementInfo.z 参照 */
        int z;
        /** スライダー/プログレスの現在値と範囲(API21+ の RangeInfo)。**採っていないと
         *  Android ではスライダーの状態がまったく読めない** —— iOS は XCUIElement.value が
         *  "50%" を返すので、同じ SUT の同じ要素でプラットフォームごとに結果が違っていた
         *  (2026-08-07 実測)。`hasRange` が false のときは3値とも無効 */
        boolean hasRange;
        float rangeCurrent, rangeMin, rangeMax;
        boolean enabled = true;
        boolean password;
        Rect bounds = new Rect();
        int depth;
        /** 子孫から引き継いだ役割クラス名(Compose の Role マーカー。adoptRoleFromMarkerChildren 参照) */
        String roleClassName = "";
        /** WebView 内ノードの Blink ロール名(非ローカライズ。EXTRA_CHROME_ROLE 参照)。web 以外は空 */
        String chromeRole = "";
        /** WebView の入れ子(Chromium の仮想ルート)。実 View 側だけ残すため除外する */
        boolean nestedWebView;
        /** WebView 内の画面外ノード(Chromium は全ドキュメントをツリーに載せる。2026-07-29 実測)。
         *  isVisibleToUser は true のまま offscreen extra だけが立つ。bounds は可視域へ
         *  クランプされ、実座標は unclippedTop/Bottom が持つ */
        boolean offscreen;
        /** クランプ前の実座標(offscreen のときだけ有効。無い側は Integer.MIN_VALUE) */
        int unclippedTop = Integer.MIN_VALUE;
        int unclippedBottom = Integer.MIN_VALUE;
        /** 子を持つか(テキスト昇格・Flutter のテキスト判定で「葉かどうか」を見るため) */
        boolean hasChildren;
    }

    private SnapshotBuilder() {}

    /** アクティブウィンドウの root。a11y 接続直後は null のことがあるためリトライする */
    static AccessibilityNodeInfo waitForRoot(UiAutomation ua, long timeoutMs) {
        long deadline = SystemClock.uptimeMillis() + timeoutMs;
        while (true) {
            AccessibilityNodeInfo root = ua.getRootInActiveWindow();
            if (root != null) return root;
            if (SystemClock.uptimeMillis() >= deadline) return null;
            SystemClock.sleep(50);
        }
    }

    /**
     * ディスプレイ全体の矩形。**アクティブウィンドウの根では代用できない** —— ダイアログが
     * 出ている間はそれがダイアログの DecorView になる(実測 1024x427)。
     *
     * **インセットを除かない物理サイズ**を返す(API 30+: getMaximumWindowMetrics().getBounds()。
     * 未満: Display#getRealMetrics。どちらも下部ジェスチャーナビゲーションバー分を含む)。
     * `Resources.getSystem().getDisplayMetrics()`(widthPixels/heightPixels)は
     * **アプリウィンドウに割り当てられた領域**で、edge-to-edge 端末だと上部ステータスバー分は
     * 含むのに下部ジェスチャーバー分だけ非対称に欠ける(実測: Pixel 9/Android 15 で
     * 報告 1080x2219、実ディスプレイは 1080x2424)。**取れなければウィンドウの根へ落ちる**:
     * 嘘の大きさを返すより、従来の値のままの方が害が小さい(ホストはこれで
     * 既定スワイプとピンチの座標を作る)。
     */
    private static Rect displayBounds(Context context, Rect fallback) {
        try {
            WindowManager wm = context == null
                    ? null : (WindowManager) context.getSystemService(Context.WINDOW_SERVICE);
            if (wm != null) {
                if (Build.VERSION.SDK_INT >= 30) {
                    Rect bounds = wm.getMaximumWindowMetrics().getBounds();
                    if (bounds.width() > 0 && bounds.height() > 0) return bounds;
                } else {
                    Display display = wm.getDefaultDisplay();
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
            // 取得できない環境では従来どおり
        }
        return fallback;
    }

    /** forceRefresh: WebView 外のノードも refresh() してから読むか(既定は false。collect 参照)。
     *  context: displayBounds の WindowManager 取得用(null 可・その場合はウィンドウの根へ落ちる) */
    static Result build(UiAutomation ua, Context context, boolean forceRefresh, int maxElements)
            throws JSONException {
        AccessibilityNodeInfo root = waitForRoot(ua, 2000);
        if (root == null) {
            throw new IllegalStateException("cannot read the UI tree of the active window");
        }

        List<UINode> nodes = new ArrayList<>();
        // uiautomator dump の XML は hierarchy=depth1、root ノード=depth2 相当
        collect(root, 2, nodes, false, forceRefresh);
        assignPaintOrder(nodes);
        markChildren(nodes);
        adoptRoleFromMarkerChildren(nodes);

        // リスト行のテキスト昇格: クリック可能な無名コンテナに最初の子孫テキストを写す
        // (AndroidDriver.snapshot() と同一ループ)
        for (int i = 0; i < nodes.size(); i++) {
            UINode node = nodes.get(i);
            if (!node.clickable || !node.text.isEmpty() || !node.contentDesc.isEmpty()) continue;
            for (int j = i + 1; j < nodes.size() && nodes.get(j).depth > node.depth; j++) {
                if (!nodes.get(j).text.isEmpty()) {
                    node.text = nodes.get(j).text;
                    break;
                }
            }
        }

        // **フィルタの基準はアクティブウィンドウの根**(従来どおり)。ここを display に替えると
        // 「画面の大半を覆う容器を落とす」0.85 の意味が変わり、ダイアログの中身の出方が動く
        Rect window = nodes.isEmpty() ? new Rect() : nodes.get(0).bounds;
        // **報告する screen は display**(2026-08-06 の探索で外した)。ウィンドウの根をそのまま
        // 返していたため、ダイアログが出ている間 `screen` が 1080x2424 ではなく
        // ダイアログの DecorView(実測 1024x427 / 735x386)になり、**同じ応答に入っている
        // 要素座標(y=1342 等)が screen をはみ出す**自己矛盾した木を返していた。
        // ホスト側の実害はもう1つある: BridgeRouter はこれを lastScreen として覚え、
        // **既定の全画面スワイプとピンチの座標をここから作る**ので、ダイアログを撮った直後の
        // swipe が画面上部の狭い帯を払うことになる
        Rect screen = displayBounds(context, window);

        List<UINode> included = new ArrayList<>();
        for (UINode node : nodes) {
            if (shouldInclude(node, window)) included.add(node);
        }
        List<UINode> kept = included.size() <= maxElements
                ? included : selectByPriority(included, maxElements);
        int truncated = included.size() - kept.size();

        JSONArray elements = new JSONArray();
        Map<Integer, double[]> centers = new HashMap<>();
        Map<Integer, String> ids = new HashMap<>();
        for (UINode node : kept) {
            int ref = elements.length() + 1;
            centers.put(ref, new double[]{node.bounds.exactCenterX(), node.bounds.exactCenterY()});
            String shortId = shortResourceId(node.resourceID);
            if (shortId != null) ids.put(ref, shortId);
            elements.put(makeInfo(node, ref));
        }

        // WebView 内の画面外ノード(スクロールヒント)。ホストのスクロール探索が
        // 「目的の要素がどの方向・何 px 先か」を事前に知り、盲目的スワイプを長距離ドラッグに
        // 置き換えるために使う(StepExecutor.offscreenJump)。実座標は
        // 下方向 = (bounds.top 実 / unclippedBottom 実)、上方向 = (unclippedTop 実 / bounds.bottom 実)。
        // **通常の elements には決して混ぜない**(見えない要素へ exist/tap が当たる)
        JSONArray offscreen = new JSONArray();
        for (UINode node : nodes) {
            if (!node.offscreen || offscreen.length() >= MAX_ELEMENTS) continue;
            int realTop = node.unclippedTop != Integer.MIN_VALUE ? node.unclippedTop : node.bounds.top;
            int realBottom = node.unclippedBottom != Integer.MIN_VALUE ? node.unclippedBottom : node.bounds.bottom;
            if (realBottom <= realTop) continue;   // 実座標を復元できないノードはヒントにしない
            Rect real = new Rect(node.bounds.left, realTop, node.bounds.right, realBottom);
            Rect saved = node.bounds;
            node.bounds = real;
            JSONObject info = makeInfo(node, 0);   // ref=0: タップ対象にならない(座標表にも入れない)
            node.bounds = saved;
            offscreen.put(info);
        }

        String pkg = root.getPackageName() == null ? null : root.getPackageName().toString();
        JSONObject response = new JSONObject();
        if (pkg != null) response.put("sessionBundleID", pkg);
        response.put("screen", rectJSON(screen));
        response.put("elements", elements);
        response.put("truncatedCount", truncated);
        if (offscreen.length() > 0) response.put("offscreen", offscreen);
        WindowRects hidden = hiddenWindowRects(ua);
        if (hidden.keyboard != null) response.put("keyboardFrame", rectJSON(hidden.keyboard));
        if (!hidden.overlays.isEmpty()) {
            JSONArray overlayFrames = new JSONArray();
            for (Rect overlay : hidden.overlays) overlayFrames.put(rectJSON(overlay));
            response.put("overlayWindowFrames", overlayFrames);
        }
        return new Result(response.toString(), centers, ids, screen);
    }

    /**
     * 木に出ないウィンドウの矩形。**木の根は `getRootInActiveWindow()` の1枚だけ**なので、
     * アクティブウィンドウ以外はどれも `elements` に1つも載らない —— ホストはここで申告された
     * 矩形でしか「要素が覆われているか」を判定できない。
     *
     * 元は IME だけを申告していた(2026-08-08 Google マップで無警告タップ漏れを実害確認)。
     * **同じ失敗は IME 以外の別ウィンドウ全部にあった**(2026-08-28・実機 Pixel 4a の Chrome で
     * 実害確認): テキスト選択のフローティングツールバー(Copy/Share/Select all)が段落の中心を
     * 覆っている状態で ref タップが無警告の "done" を返し、実際には「Select all」に当たった。
     *
     * **数えるのは TYPE_APPLICATION だけ**(実測で決めた境界):
     *  - TYPE_INPUT_METHOD は `keyboard` が持つ(実効矩形を chrome で広げる専用の扱いがある)
     *  - TYPE_SYSTEM は**ステータスバー / ナビゲーションバーが常設で入る**ので数えない。
     *    数えると画面上下の帯に居る要素が毎回警告になる(= 常時発火する検知は雑音でしかない)。
     *    代償として TYPE_APPLICATION_OVERLAY(SYSTEM_ALERT_WINDOW のチャットヘッド等)は
     *    拾えない —— こちらは実害を観測してから広げる
     *  - TYPE_ACCESSIBILITY_OVERLAY は検査基盤自身なので数えない
     *
     * **手前に居ることを layer で確かめる**(アクティブより奥のウィンドウは覆っていない)。
     * アクティブが1枚も無ければ何も申告しない = 従来動作へ縮退する。
     *
     * getWindows() は BridgeRouter コンストラクタで FLAG_RETRIEVE_INTERACTIVE_WINDOWS を
     * 立てないと常に空を返す。取れない(空/例外)場合は黙って空 = レスポンスから省略する。
     */
    static final class WindowRects {
        Rect keyboard;
        final List<Rect> overlays = new ArrayList<>();
    }

    /** 1応答で申告するオーバーレイの上限。**件数を絞るのは応答を膨らませないため**で、
     *  超える画面は実測で1つも無い(溢れたら黙って落とす = 従来動作) */
    static final int MAX_OVERLAY_WINDOWS = 8;

    private static WindowRects hiddenWindowRects(UiAutomation ua) {
        WindowRects out = new WindowRects();
        try {
            List<AccessibilityWindowInfo> windows = ua.getWindows();
            if (windows == null) return out;
            boolean haveActive = false;
            int activeLayer = Integer.MIN_VALUE;
            for (AccessibilityWindowInfo window : windows) {
                if (window == null || !window.isActive()) continue;
                haveActive = true;
                activeLayer = Math.max(activeLayer, window.getLayer());
            }
            for (AccessibilityWindowInfo window : windows) {
                if (window == null) continue;
                Rect bounds = new Rect();
                window.getBoundsInScreen(bounds);
                if (bounds.isEmpty()) continue;
                int type = window.getType();
                if (type == AccessibilityWindowInfo.TYPE_INPUT_METHOD) {
                    if (out.keyboard == null) out.keyboard = bounds;
                    continue;
                }
                if (type != AccessibilityWindowInfo.TYPE_APPLICATION) continue;
                if (!haveActive || window.isActive() || window.getLayer() <= activeLayer) continue;
                if (out.overlays.size() >= MAX_OVERLAY_WINDOWS) continue;
                out.overlays.add(bounds);
            }
        } catch (RuntimeException ignored) {
            // a11y サービス切断中などで getWindows が使えない環境では省略
        }
        return out;
    }

    /** preorder 走査。不可視ノードはサブツリーごと除外(uiautomator dump と同じ) */
    private static void collect(AccessibilityNodeInfo node, int depth, List<UINode> out,
                                boolean insideWebView, boolean forceRefresh) {
        collect(node, depth, out, insideWebView, forceRefresh, new int[0]);
    }

    private static void collect(AccessibilityNodeInfo node, int depth, List<UINode> out,
                                boolean insideWebView, boolean forceRefresh, int[] parentZPath) {
        if (node == null) return;

        // a11y ノードはキャッシュ供給で古い値を返し続ける(Chromium は DOM 変更のイベントを
        // 遅れて出す。interop 埋め込みで実測 4〜8 秒)。**既定は WebView 内だけ** refresh() する
        // — 全ノードに広げると snapshot 1回あたり約 +65ms 増え、View/XML SUT(ノード数が多い)の
        // scenario sum が +43% になると実測済み(2026-08-01、E2E-Android 208.3s→297.3s)。
        // forceRefresh は呼び出し側(BridgeRouter.handleSnapshot、クエリ `refresh=1`)が
        // 検証タイムアウト直前の1回だけ明示的に要求するときの逃げ道。
        // **順序が要**: isVisibleToUser() 自体が古いと、実際は見えているノードがサブツリーごと
        // 消える。getChildCount()/getChild() も refresh 後の子リストを読む必要がある。
        // 無効ノードの refresh() は false を返すだけで例外は投げないので戻り値は見ない。
        if (insideWebView || forceRefresh) node.refresh();
        if (!node.isVisibleToUser()) return;

        UINode n = new UINode();
        n.className = charSeq(node.getClassName());
        // WebView は「実 View + Chromium の仮想ルート」の2段で出る(2026-07-29 実測)。
        // 外側だけ残さないと `.webView[1]` がどちらを指すか読めなくなる
        boolean isWebView = n.className.equals("android.webkit.WebView");
        n.nestedWebView = isWebView && insideWebView;
        // ヒント表示中の text は値ではない → placeholder として別枠で返す(iOS と同じ意味論)
        n.text = node.isShowingHintText() ? "" : charSeq(node.getText());
        n.hint = charSeq(node.getHintText());
        n.contentDesc = charSeq(node.getContentDescription());
        n.resourceID = node.getViewIdResourceName() == null ? "" : node.getViewIdResourceName();
        n.clickable = node.isClickable();
        n.checkable = node.isCheckable();
        n.checked = node.isChecked();
        n.selected = node.isSelected();
        n.focused = node.isFocused();
        n.scrollable = node.isScrollable();
        AccessibilityNodeInfo.RangeInfo range = node.getRangeInfo();
        if (range != null) {
            n.hasRange = true;
            n.rangeCurrent = range.getCurrent();
            n.rangeMin = range.getMin();
            n.rangeMax = range.getMax();
        }

        n.enabled = node.isEnabled();
        n.password = node.isPassword();
        n.chromeRole = chromeRole(node);
        if (insideWebView) {
            android.os.Bundle extras = node.getExtras();
            if (extras != null) {
                Object off = extras.get("AccessibilityNodeInfo.offscreen");
                n.offscreen = Boolean.TRUE.equals(off);
                Object top = extras.get("AccessibilityNodeInfo.unclippedTop");
                Object bottom = extras.get("AccessibilityNodeInfo.unclippedBottom");
                if (top instanceof Integer) n.unclippedTop = (Integer) top;
                if (bottom instanceof Integer) n.unclippedBottom = (Integer) bottom;
            }
        }
        node.getBoundsInScreen(n.bounds);
        n.depth = depth;
        int[] zPath = new int[parentZPath.length + 1];
        System.arraycopy(parentZPath, 0, zPath, 0, parentZPath.length);
        zPath[parentZPath.length] = node.getDrawingOrder();
        n.zPath = zPath;
        out.add(n);

        for (int i = 0; i < node.getChildCount(); i++) {
            collect(node.getChild(i), depth + 1, out, insideWebView || isWebView, forceRefresh,
                    zPath);
        }
    }

    private static String charSeq(CharSequence cs) {
        return cs == null ? "" : cs.toString();
    }

    /**
     * WebView 内ノードだけが持つ Blink のロール名(Chromium が extras に載せる)。
     * **roleDescription は端末ロケールで訳される**ので使わない(フリートのロケール差でシナリオが
     * 壊れる)。こちらは "link" / "heading" 等の非ローカライズ値。web 以外のノードでは空。
     */
    private static final String EXTRA_CHROME_ROLE = "AccessibilityNodeInfo.chromeRole";

    private static String chromeRole(AccessibilityNodeInfo node) {
        android.os.Bundle extras = node.getExtras();
        return extras == null ? "" : charSeq(extras.getCharSequence(EXTRA_CHROME_ROLE));
    }

    /**
     * zPath を辞書式に並べて 0 起点の通し番号 `z` を振る(大きいほど手前)。
     * **出力の並び(preorder)は変えない** —— `RefGuard.lineage` が preorder+depth で
     * ツリーを復元するので、並べ替えるとそちらが壊れる。順位だけを別フィールドで持つ。
     * 辞書式でよいのは塗り順がまさにそれだから: 親を塗ってから子を描画順に、を再帰する
     * = 祖先は必ず先、同じ親なら drawingOrder の小さい枝が先。
     */
    private static void assignPaintOrder(List<UINode> nodes) {
        List<UINode> sorted = new java.util.ArrayList<>(nodes);
        java.util.Collections.sort(sorted, new java.util.Comparator<UINode>() {
            @Override public int compare(UINode a, UINode b) {
                int n = Math.min(a.zPath.length, b.zPath.length);
                for (int i = 0; i < n; i++) {
                    if (a.zPath[i] != b.zPath[i]) return a.zPath[i] < b.zPath[i] ? -1 : 1;
                }
                return Integer.compare(a.zPath.length, b.zPath.length);
            }
        });
        for (int i = 0; i < sorted.size(); i++) sorted.get(i).z = i;
    }

    /** pre-order なので「次のノードの depth が自分より深い」= 子を持つ */
    private static void markChildren(List<UINode> nodes) {
        for (int i = 0; i < nodes.size(); i++) {
            UINode node = nodes.get(i);
            node.hasChildren = i + 1 < nodes.size() && nodes.get(i + 1).depth > node.depth;
        }
    }

    /**
     * Compose(CMP / Android の ComposeView)は Role.Button 等を **同一 bounds の無名子ノード**
     * (className=android.widget.Button・text/id 無し・clickable=false)として出し、testTag が付いた
     * 当の clickable ノードは android.view.View のままにする。そのままだと既定分岐に落ちて `Cell` に
     * なり、iOS(AX trait で Button になる)と型が食い違う。ここで子の役割を親へ引き上げて揃える。
     * 2026-07-26 に E2EApp(CMP)と E2EAppAndroid(ComposeView)の実スナップショットで確認。
     *
     * **矩形の完全一致を条件にしてはいけない**(2026-08-06 に実測して緩めた): 見切れると
     * 親とマーカー子が**独立にクリップされる**。一致条件では引き上げに失敗し、
     * **同じ Composable が可視状態によって Button と Clickable を行き来していた**
     * (`.button` の型セレクタがスクロール位置で落ちる)。実測した3形はどれも食い違う:
     *
     * | 見切れ方 | 親 | マーカー子 |
     * |---|---|---|
     * | 右端(`#tag_04`) | `(987,1972)-(1080,2119)` | `(987,1972)-(1038,2119)`(子が狭い) |
     * | 下端(`#btn_scroll_top`) | `(42,378)-(278,441)` | `(42,378)-(278,504)`(**子のほうが大きい**) |
     * | 上端(`#row_07`) | `(42,441)-(1038,559)` | `(42,504)-(1038,559)`(原点が違う) |
     *
     * 「子は親に内包される」も「原点は動かない」も成り立たない。**成り立つのは辺の共有**で、
     * 3形とも4辺のうち3辺が一致する(切れていない側は必ず一致する)。角で切れれば2辺なので
     * しきい値は2。装飾(行の中のアイコン等)は0〜1辺しか一致しない —— ここを緩めすぎると
     * **リスト行が Image になる**ので、面積比(3倍以内)も併せて要求する。
     */
    private static void adoptRoleFromMarkerChildren(List<UINode> nodes) {
        for (int i = 0; i < nodes.size(); i++) {
            UINode node = nodes.get(i);
            if (!node.clickable || !isGenericContainer(node.className)) continue;
            for (int j = i + 1; j < nodes.size() && nodes.get(j).depth > node.depth; j++) {
                UINode child = nodes.get(j);
                // マーカーの条件: 親と同じ矩形(見切れ許容)・名前を持たない・自身は操作対象でない
                if (!looksLikeRoleMarker(child.bounds, node.bounds)) continue;
                if (!child.text.isEmpty() || !child.contentDesc.isEmpty()
                        || !child.resourceID.isEmpty() || child.clickable) continue;
                if (isGenericContainer(child.className)) continue;
                node.roleClassName = child.className;
                break;
            }
        }
    }

    /** 役割マーカーの矩形条件: 4辺のうち2辺以上が一致し、面積が3倍以内(独立クリップの許容) */
    private static boolean looksLikeRoleMarker(Rect child, Rect parent) {
        int sharedEdges = (child.left == parent.left ? 1 : 0)
                + (child.top == parent.top ? 1 : 0)
                + (child.right == parent.right ? 1 : 0)
                + (child.bottom == parent.bottom ? 1 : 0);
        if (sharedEdges < 2) return false;
        long childArea = (long) child.width() * child.height();
        long parentArea = (long) parent.width() * parent.height();
        if (childArea <= 0 || parentArea <= 0) return false;
        return Math.min(childArea, parentArea) * 3 >= Math.max(childArea, parentArea);
    }

    /** 役割を持たない汎用コンテナ(Compose/Flutter が canvas 描画で使う)か */
    private static boolean isGenericContainer(String className) {
        return className.equals("android.view.View") || className.equals("android.view.ViewGroup")
                || className.endsWith("Layout") || className.isEmpty();
    }

    /**
     * MAX_ELEMENTS 超過時に優先度の低いノードから間引く。**preorder 順は維持する**
     * (RefGuard.lineage が preorder+depth からツリーを復元し、ref の大小を z-order の
     * 代理に使うため。並べ替え厳禁)。
     * tier0(clickable/checkable/scrollable/編集可能なテキスト欄) → tier1(非空白の
     * text/contentDesc か resourceID を持つ) → tier2(それ以外)の順に、**tier2 から**
     * 全部捨ててもまだ超過するなら tier1、それでも超過するなら tier0 を捨てる。
     * 同一 tier 内では preorder の後ろから捨てる(先頭寄りの要素を優先して残す)。
     */
    private static List<UINode> selectByPriority(List<UINode> included, int max) {
        int n = included.size();
        boolean[] keep = new boolean[n];
        java.util.Arrays.fill(keep, true);
        int remaining = n;
        for (int tier = 2; tier >= 0 && remaining > max; tier--) {
            for (int i = n - 1; i >= 0 && remaining > max; i--) {
                if (!keep[i] || priorityTier(included.get(i)) != tier) continue;
                keep[i] = false;
                remaining--;
            }
        }
        List<UINode> kept = new ArrayList<>(Math.min(max, n));
        for (int i = 0; i < n; i++) {
            if (keep[i]) kept.add(included.get(i));
        }
        return kept;
    }

    /**
     * 0=高優先(残す) .. 2=低優先(先に捨てる)。tier0/1 の条件は shouldInclude と別軸。
     * **正は Swift 側の BridgeSnapshotThinning**(Sources/FTCore/BridgeDTO.swift)。
     * あちらは iOS 専用に tier3(同一 id が20件以上の非スクロール装飾群)を持つが、
     * コーパス14本の実測で Android は1画面も発火しなかったので写していない。
     */
    private static int priorityTier(UINode node) {
        if (node.clickable || node.checkable || node.scrollable) return 0;
        String type = mappedType(node);
        if (type.equals("TextField") || type.equals("SecureTextField")) return 0;
        boolean hasText = !node.text.trim().isEmpty() || !node.contentDesc.trim().isEmpty();
        if (hasText || !node.resourceID.isEmpty()) return 1;
        return 2;
    }

    // MARK: - フィルタと変換(AndroidDriver.shouldInclude / makeInfo / mappedType の移植)

    private static boolean shouldInclude(UINode node, Rect screen) {
        if (node.bounds.width() < 2 || node.bounds.height() < 2) return false;
        if (node.nestedWebView) return false;
        // 画面外ノードは通常要素にしない(exist/tap が見えない要素に当たる)。
        // 現状もクランプで高さが負になり偶然落ちるが、Chromium の挙動依存なので明示する
        if (node.offscreen) return false;

        String type = mappedType(node);
        // 画面の大半を覆うコンテナは除外(FM の誤タップ誘発対策)。WebView は全画面が普通で、
        // かつスコープ起点として要るので対象外にする
        if (!node.clickable && screen.width() > 0 && !type.equals("WebView")) {
            double ratio = (double) (node.bounds.width() * node.bounds.height())
                    / ((double) screen.width() * screen.height());
            if (ratio > 0.85) return false;
        }

        boolean hasText = !node.text.isEmpty() || !node.contentDesc.isEmpty() || !node.resourceID.isEmpty();
        // **選択中のノードは必ず残す**(2026-08-07 実測): Android は選択中のタブから
        // clickable を落とす。そのノードが resource-id もテキストも持たないと、下の default
        // 分岐で捨てられて**木から丸ごと消える**。実害は Google マップの経路プランナーで、
        // 移動手段タブを切り替えると**選んだ側だけが消え**、今どれが選ばれているのか
        // エージェントから読めなくなっていた(下部ナビが無事なのは id を持つから)。
        // `selected` は checked へ OR して出しているので、残れば状態も読める
        if (node.clickable || node.checkable || node.selected) return true;
        switch (type) {
            case "TextField":
            case "SecureTextField":
                return true;
            // WebView コンテナは resource-id を持たない(レイアウトで付けても a11y ノードには
            // 出ない。2026-07-29 実測)。既定分岐だと落ちてスコープ起点にできないので明示的に残す
            case "WebView":
                return true;
            case "StaticText":
            case "Image":
                return hasText;
            default:
                return !node.resourceID.isEmpty();
        }
    }

    /** "com.example:id/foo" → "foo"(makeInfo の identifier と同じ短縮規則。片方だけ変えない) */
    private static String shortResourceId(String resourceID) {
        if (resourceID == null || resourceID.isEmpty()) return null;
        int idx = resourceID.indexOf("id/");
        return idx >= 0 ? resourceID.substring(idx + 3) : resourceID;
    }

    private static JSONObject makeInfo(UINode node, int ref) throws JSONException {
        String type = mappedType(node);
        boolean isInput = type.equals("TextField") || type.equals("SecureTextField");

        String label = null;
        String value = null;
        if (isInput) {
            value = node.text.isEmpty() ? null : node.text;
            label = node.contentDesc.isEmpty() ? null : node.contentDesc;
        } else {
            label = !node.text.isEmpty() ? node.text
                    : (!node.contentDesc.isEmpty() ? node.contentDesc : null);
        }
        if (node.checkable) {
            value = node.checked ? "1" : "0";
        }

        // resource-id は "com.example:id/foo" 形式 → "foo" に短縮
        String identifier = null;
        if (!node.resourceID.isEmpty()) {
            int idx = node.resourceID.indexOf("id/");
            identifier = idx >= 0 ? node.resourceID.substring(idx + 3) : node.resourceID;
        }

        // **スライダー等は現在値を value に載せる**。パーセントへ正規化しない ——
        // 0..10 のスライダーで current=3 を "30%" と言うのは、生値を読みたい側には嘘に近い。
        // 範囲は別キー `range` で添えるので、読み手は割合も自分で出せる(2026-08-07 の決定)
        String range = null;
        if (node.hasRange) {
            if (value == null) value = trimFloat(node.rangeCurrent);
            range = trimFloat(node.rangeMin) + "-" + trimFloat(node.rangeMax);
        }

        // Optional フィールドは nil のときキー省略(Swift JSONEncoder と同じ形)
        JSONObject info = new JSONObject();
        info.put("ref", ref);
        info.put("type", type);
        if (identifier != null) info.put("identifier", identifier);
        if (label != null) info.put("label", label);
        if (value != null) info.put("value", value);
        if (isInput && !node.hint.isEmpty()) info.put("placeholder", node.hint);
        info.put("enabled", node.enabled);
        // checked は true のときだけ送る(iOS の isSelected と同じ意味・同じ省略規約)。
        // Android は isChecked と isSelected の両方を OR で流し込む —— タブ・選択行は
        // isChecked を立てず isSelected だけで選択状態を出す widget がある(実測: Google マップ
        // 下部ナビ)。isChecked/isSelected どちらが立っても checkIsON の意味は同じ「選択中」
        if (node.checked || node.selected) info.put("checked", true);
        // focused も同じ省略規約(clearInput 事後検証用。BridgeDTO.ElementInfo.focused 参照)
        if (node.focused) info.put("focused", true);
        // scrollable も同じ省略規約(scrollFrame の空振り検出用)
        if (node.scrollable) info.put("scrollable", true);
        if (range != null) info.put("range", range);
        // 塗り順は**常に**送る(0 も有効な値。省略すると「奥から数えて0番目」と
        // 「申告なし」が区別できなくなる)
        info.put("z", node.z);
        info.put("frame", rectJSON(node.bounds));
        info.put("depth", node.depth);
        return info;
    }

    /** 整数なら小数点以下を落とす("50.0" ではなく "50")。読み手はこれをそのまま値として使う */
    private static String trimFloat(float f) {
        return f == Math.rint(f) ? String.valueOf((long) f) : String.valueOf(f);
    }

    static JSONObject rectJSON(Rect rect) throws JSONException {
        JSONObject o = new JSONObject();
        o.put("x", (double) rect.left);
        o.put("y", (double) rect.top);
        o.put("width", (double) rect.width());
        o.put("height", (double) rect.height());
        return o;
    }

    /** Android クラス名 → iOS 側と共通の型語彙(AndroidDriver.UINode.mappedType と同一) */
    private static String mappedType(UINode node) {
        // WebView 内はリンクが android.view.View(=既定分岐で Clickable)に落ち、iOS の Link と
        // 食い違う。Chromium の非ローカライズなロール名で先に確定させる(chromeRole 参照)
        if (node.chromeRole.equals("link")) return "Link";
        // 役割マーカー子から引き上げたクラス名を優先する(Compose の Button/Switch はこちらにしか出ない)
        String className = node.roleClassName.isEmpty() ? node.className : node.roleClassName;
        int dot = className.lastIndexOf('.');
        String name = dot >= 0 ? className.substring(dot + 1) : className;
        if (node.password) return "SecureTextField";
        switch (name) {
            case "Button":
            case "ImageButton":
            case "MaterialButton":
                return "Button";
            case "EditText":
            case "AutoCompleteTextView":
            case "MultiAutoCompleteTextView":
                return "TextField";
            case "TextView":
            case "CheckedTextView":
                return "StaticText";
            case "ImageView":
                return "Image";
            case "Switch":
            case "SwitchCompat":
            case "ToggleButton":
                return "Switch";
            case "CheckBox":
            case "RadioButton":
                return "CheckBox";
            case "SeekBar":
                return "Slider";
            case "RecyclerView":
            case "ListView":
            case "GridView":
                return "CollectionView";
            case "ScrollView":
            case "NestedScrollView":
            case "HorizontalScrollView":
                return "ScrollView";
            case "WebView":
                return "WebView";
            default:
                // ここから下は「className が役割を語らない」ケース(Compose / Flutter の canvas 描画)。
                // iOS 側が返す型に寄せるための推定。順序に意味がある(checkable → clickable → 葉テキスト)
                //
                // checkable な汎用ノード = Compose の Switch(Role.Switch は legacy className を持たない)。
                // Checkbox / RadioButton は className が出るので上の case で先に確定している
                if (node.checkable) return "Switch";
                // 役割が確定しない clickable 容器(リスト行・カード)。iOS のセルと同じ語にする
                if (node.clickable) return "Clickable";
                // Flutter(Android)はテキストも android.view.View で、contentDesc にだけ文字が入る。
                // 葉であることを条件にする(子を持つ汎用コンテナを StaticText にしないため)。
                // これが無いと id を振っていないテキストがスナップショットから丸ごと落ち、
                // ラベルをアンカーにした方向セレクタが使えない(2026-07-26 実測)。
                // **text 側も見る**(2026-08-13 実機で発見): Chromium は WebView 内の
                // `<td>` 等を className=android.view.View + **getText()** で出す(contentDesc は空)。
                // contentDesc だけを見ていたため Other へ落ち、shouldInclude の default が
                // resource-id を要求して**表のセルが1つも木に出なかった**。しかも
                // `<table>` 自身は GridView + id で残るので `webViewGapNote` の空白帯にもならず、
                // **黙って消える**(WebView 150 で実機再現。124 のエミュレータでは table ごと出ない)
                if (!node.hasChildren && (!node.contentDesc.isEmpty() || !node.text.isEmpty())) {
                    return "StaticText";
                }
                return "Other";
        }
    }
}
