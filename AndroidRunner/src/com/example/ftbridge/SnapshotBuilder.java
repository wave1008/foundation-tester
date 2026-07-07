// SnapshotBuilder.java
// AccessibilityNodeInfo ツリー → BridgeDTO.SnapshotResponse 互換 JSON。
// フィルタ・型語彙マップ・テキスト昇格・ref 採番は Sources/FTAndroid/AndroidDriver.swift の
// uiautomator dump 版と同一仕様(FM プロンプトの一貫性のため。変更時は両方を揃えること)。
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
        final Rect screen;
        Result(String json, Map<Integer, double[]> refCenters, Rect screen) {
            this.json = json;
            this.refCenters = refCenters;
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
        boolean enabled = true;
        boolean password;
        Rect bounds = new Rect();
        int depth;
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

    static Result build(UiAutomation ua) throws JSONException {
        AccessibilityNodeInfo root = waitForRoot(ua, 2000);
        if (root == null) {
            throw new IllegalStateException("アクティブウィンドウの UI ツリーを取得できません");
        }

        List<UINode> nodes = new ArrayList<>();
        // uiautomator dump の XML は hierarchy=depth1、root ノード=depth2 相当
        collect(root, 2, nodes);

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
        int truncated = 0;
        for (UINode node : nodes) {
            if (!shouldInclude(node, screen)) continue;
            if (elements.length() >= MAX_ELEMENTS) {
                truncated++;
                continue;
            }
            int ref = elements.length() + 1;
            centers.put(ref, new double[]{node.bounds.exactCenterX(), node.bounds.exactCenterY()});
            elements.put(makeInfo(node, ref));
        }

        String pkg = root.getPackageName() == null ? null : root.getPackageName().toString();
        JSONObject response = new JSONObject();
        if (pkg != null) response.put("sessionBundleID", pkg);
        response.put("screen", rectJSON(screen));
        response.put("elements", elements);
        response.put("truncatedCount", truncated);
        return new Result(response.toString(), centers, screen);
    }

    /** preorder 走査。不可視ノードはサブツリーごと除外(uiautomator dump と同じ) */
    private static void collect(AccessibilityNodeInfo node, int depth, List<UINode> out) {
        if (node == null || !node.isVisibleToUser()) return;

        UINode n = new UINode();
        n.className = charSeq(node.getClassName());
        // ヒント表示中の text は値ではない → placeholder として別枠で返す(iOS と同じ意味論)
        n.text = node.isShowingHintText() ? "" : charSeq(node.getText());
        n.hint = charSeq(node.getHintText());
        n.contentDesc = charSeq(node.getContentDescription());
        n.resourceID = node.getViewIdResourceName() == null ? "" : node.getViewIdResourceName();
        n.clickable = node.isClickable();
        n.checkable = node.isCheckable();
        n.checked = node.isChecked();
        n.enabled = node.isEnabled();
        n.password = node.isPassword();
        node.getBoundsInScreen(n.bounds);
        n.depth = depth;
        out.add(n);

        for (int i = 0; i < node.getChildCount(); i++) {
            collect(node.getChild(i), depth + 1, out);
        }
    }

    private static String charSeq(CharSequence cs) {
        return cs == null ? "" : cs.toString();
    }

    // MARK: - フィルタと変換(AndroidDriver.shouldInclude / makeInfo / mappedType の移植)

    private static boolean shouldInclude(UINode node, Rect screen) {
        if (node.bounds.width() < 2 || node.bounds.height() < 2) return false;

        // 画面の大半を覆うコンテナは除外(FM の誤タップ誘発対策)
        if (!node.clickable && screen.width() > 0) {
            double ratio = (double) (node.bounds.width() * node.bounds.height())
                    / ((double) screen.width() * screen.height());
            if (ratio > 0.85) return false;
        }

        boolean hasText = !node.text.isEmpty() || !node.contentDesc.isEmpty() || !node.resourceID.isEmpty();
        if (node.clickable || node.checkable) return true;
        String type = mappedType(node);
        switch (type) {
            case "TextField":
            case "SecureTextField":
                return true;
            case "StaticText":
            case "Image":
                return hasText;
            default:
                return !node.resourceID.isEmpty();
        }
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
        String className = node.className;
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
                if (node.clickable) return "Cell";
                return "Other";
        }
    }
}
