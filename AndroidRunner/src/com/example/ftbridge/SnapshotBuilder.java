// SnapshotBuilder.java
// AccessibilityNodeInfo ツリー → BridgeDTO.SnapshotResponse 互換 JSON。
// フィルタ・型語彙マップ・テキスト昇格・ref 採番の唯一の実装(Phase 1 で
// Sources/FTAndroid/AndroidDriver.swift 側の uiautomator dump フォールバックは削除済み。
// 揃えるべき相方はもう存在しない。iOS 側との型語彙の対応は Runner/FTesterRunnerUITests を参照)。
package com.example.ftbridge;

import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.SystemClock;
import android.view.accessibility.AccessibilityNodeInfo;

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
        /** clearInput 事後検証用(BridgeDTO.ElementInfo.focused 参照) */
        boolean focused;
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

    /** forceRefresh: WebView 外のノードも refresh() してから読むか(既定は false。collect 参照) */
    static Result build(UiAutomation ua, boolean forceRefresh) throws JSONException {
        AccessibilityNodeInfo root = waitForRoot(ua, 2000);
        if (root == null) {
            throw new IllegalStateException("アクティブウィンドウの UI ツリーを取得できません");
        }

        List<UINode> nodes = new ArrayList<>();
        // uiautomator dump の XML は hierarchy=depth1、root ノード=depth2 相当
        collect(root, 2, nodes, false, forceRefresh);
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

        Rect screen = nodes.isEmpty() ? new Rect() : nodes.get(0).bounds;

        JSONArray elements = new JSONArray();
        Map<Integer, double[]> centers = new HashMap<>();
        Map<Integer, String> ids = new HashMap<>();
        int truncated = 0;
        for (UINode node : nodes) {
            if (!shouldInclude(node, screen)) continue;
            if (elements.length() >= MAX_ELEMENTS) {
                truncated++;
                continue;
            }
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
        return new Result(response.toString(), centers, ids, screen);
    }

    /** preorder 走査。不可視ノードはサブツリーごと除外(uiautomator dump と同じ) */
    private static void collect(AccessibilityNodeInfo node, int depth, List<UINode> out,
                                boolean insideWebView, boolean forceRefresh) {
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
        n.focused = node.isFocused();
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
        out.add(n);

        for (int i = 0; i < node.getChildCount(); i++) {
            collect(node.getChild(i), depth + 1, out, insideWebView || isWebView, forceRefresh);
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
     */
    private static void adoptRoleFromMarkerChildren(List<UINode> nodes) {
        for (int i = 0; i < nodes.size(); i++) {
            UINode node = nodes.get(i);
            if (!node.clickable || !isGenericContainer(node.className)) continue;
            for (int j = i + 1; j < nodes.size() && nodes.get(j).depth > node.depth; j++) {
                UINode child = nodes.get(j);
                // マーカーの条件: 親と同じ矩形・名前を持たない・自身は操作対象でない
                if (!child.bounds.equals(node.bounds)) continue;
                if (!child.text.isEmpty() || !child.contentDesc.isEmpty()
                        || !child.resourceID.isEmpty() || child.clickable) continue;
                if (isGenericContainer(child.className)) continue;
                node.roleClassName = child.className;
                break;
            }
        }
    }

    /** 役割を持たない汎用コンテナ(Compose/Flutter が canvas 描画で使う)か */
    private static boolean isGenericContainer(String className) {
        return className.equals("android.view.View") || className.equals("android.view.ViewGroup")
                || className.endsWith("Layout") || className.isEmpty();
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
        if (node.clickable || node.checkable) return true;
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

        // Optional フィールドは nil のときキー省略(Swift JSONEncoder と同じ形)
        JSONObject info = new JSONObject();
        info.put("ref", ref);
        info.put("type", type);
        if (identifier != null) info.put("identifier", identifier);
        if (label != null) info.put("label", label);
        if (value != null) info.put("value", value);
        if (isInput && !node.hint.isEmpty()) info.put("placeholder", node.hint);
        info.put("enabled", node.enabled);
        // checked は true のときだけ送る(iOS の isSelected と同じ意味・同じ省略規約)
        if (node.checked) info.put("checked", true);
        // focused も同じ省略規約(clearInput 事後検証用。BridgeDTO.ElementInfo.focused 参照)
        if (node.focused) info.put("focused", true);
        info.put("frame", rectJSON(node.bounds));
        info.put("depth", node.depth);
        return info;
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
                // ラベルをアンカーにした方向セレクタが使えない(2026-07-26 実測)
                if (!node.hasChildren && !node.contentDesc.isEmpty()) return "StaticText";
                return "Other";
        }
    }
}
