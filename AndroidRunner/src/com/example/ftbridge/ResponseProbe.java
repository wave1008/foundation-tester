// ResponseProbe.java
// 応答時間計測の端末側。SurfaceFlinger の提示時刻(CLOCK_MONOTONIC)と MotionEvent.downTime(SystemClock.uptimeMillis)は同じ時計。
package com.example.ftbridge;

import android.app.UiAutomation;
import android.content.Context;
import android.os.SystemClock;

import java.util.ArrayList;
import java.util.List;

final class ResponseProbe {

    private ResponseProbe() {}

    /** --latency の履歴は1レイヤー最大128フレーム。これ以上埋まっていたら溢れて古い側が消えている可能性がある(127 = 余裕1) */
    private static final int HISTORY_FULL_ROWS = 127;
    private static final String NO_SESSION_APP = "noSessionApp";

    static final class Prepared {
        final boolean quiet;
        final long waitedMs;
        final String reason;

        Prepared(boolean quiet, long waitedMs, String reason) {
            this.quiet = quiet;
            this.waitedMs = waitedMs;
            this.reason = reason;
        }
    }

    static final class Collected {
        final Long downTimeMs;
        final Long firstFrameDelayMs;
        final String reason;
        Long lastDownTimeMs = null;
        int injections = 0;

        Collected(Long downTimeMs, Long firstFrameDelayMs, String reason) {
            this.downTimeMs = downTimeMs;
            this.firstFrameDelayMs = firstFrameDelayMs;
            this.reason = reason;
        }
    }

    /** 1レイヤーの読み。validPresents は actualPresent が 0 < v < Long.MAX_VALUE の行(MAX_VALUE は未確定のフェンス) */
    private static final class Frames {
        final List<Long> validPresents = new ArrayList<>();
        int filledRows = 0;
    }

    /**
     * 描画が止まるまで待ってから、最初の DOWN の記録を構える。quiet でなくても(タイムアウトでも noSessionApp でも)必ず構える
     * —— 構えないと collect が前の操作の記録を拾う
     */
    static Prepared prepare(UiAutomation ua, Context context, String pkg, long quietMs, long timeoutMs, long observeMs) {
        // 実行中の観測の最後の DOWN・回数は armFirstDown で消えるので、その前に観測へ写させる
        ResponseObserver.prepare(ua, context, pkg, observeMs);
        try {
            if (pkg == null) return new Prepared(false, 0, NO_SESSION_APP);
            long start = SystemClock.uptimeMillis();
            while (true) {
                BridgeRouter.rawShell(ua, "dumpsys SurfaceFlinger --latency-clear");
                sleep(quietMs);
                boolean any = false;
                for (String layer : appLayers(ua, pkg)) {
                    if (!readFrames(ua, layer).validPresents.isEmpty()) any = true;
                }
                long waited = SystemClock.uptimeMillis() - start;
                if (!any) return new Prepared(true, waited, null);
                if (waited >= timeoutMs) return new Prepared(false, waited, null);
            }
        } finally {
            InputInjector.armFirstDown();
        }
    }

    static Collected collect(UiAutomation ua, String pkg) {
        Collected c = collectFrames(ua, pkg);
        long[] stats = InputInjector.peekDownStats();
        if (stats[0] >= 0) {
            c.lastDownTimeMs = stats[1];
            c.injections = (int) stats[2];
        }
        return c;
    }

    private static Collected collectFrames(UiAutomation ua, String pkg) {
        long downTime = InputInjector.takeFirstDown();
        if (downTime < 0) return new Collected(null, null, "noInjectedInput");
        if (pkg == null) return new Collected(downTime, null, NO_SESSION_APP);
        long downNs = downTime * 1_000_000L;
        long first = Long.MAX_VALUE;
        boolean incomplete = false;
        for (String layer : appLayers(ua, pkg)) {
            Frames f = readFrames(ua, layer);
            if (f.validPresents.isEmpty()) continue;
            long earliest = Long.MAX_VALUE;
            for (long p : f.validPresents) {
                if (p < earliest) earliest = p;
                if (p > downNs && p < first) first = p;
            }
            if (f.filledRows >= HISTORY_FULL_ROWS && earliest > downNs) incomplete = true;
        }
        // 履歴から落ちた可能性を noFrame より先に: 失われたフレームを「出なかった」と読ませない
        if (incomplete) return new Collected(downTime, null, "frameHistoryIncomplete");
        if (first == Long.MAX_VALUE) return new Collected(downTime, null, "noFrame");
        return new Collected(downTime, Math.round((first - downNs) / 1e6), null);
    }

    /**
     * 観測の取得時に求める最初のフレーム: downMs より後(厳密)で endMs 以前の最初の提示までの遅れ(ms)。{Long delay, String reason}。
     * collectFrames と同じ読み・同じ ns↔ms の換算。履歴が溢れていて最古の提示が downMs より後なら途中が欠けているので incomplete
     */
    static Object[] firstFrameWithin(UiAutomation ua, String pkg, long downMs, long endMs) {
        if (pkg == null) return new Object[] {null, NO_SESSION_APP};
        long downNs = downMs * 1_000_000L;
        long endNs = endMs * 1_000_000L;
        long first = Long.MAX_VALUE;
        boolean incomplete = false;
        for (String layer : appLayers(ua, pkg)) {
            Frames f = readFrames(ua, layer);
            if (f.validPresents.isEmpty()) continue;
            long earliest = Long.MAX_VALUE;
            for (long p : f.validPresents) {
                if (p < earliest) earliest = p;
                if (p > downNs && p <= endNs && p < first) first = p;
            }
            if (f.filledRows >= HISTORY_FULL_ROWS && earliest > downNs) incomplete = true;
        }
        if (incomplete) return new Object[] {null, "frameHistoryIncomplete"};
        if (first == Long.MAX_VALUE) return new Object[] {null, "noFrame"};
        return new Object[] {Long.valueOf(Math.round((first - downNs) / 1e6)), null};
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    /** `--list` の行は素のレイヤー名か `RequestedLayerState{<name> parentId=...}`(Android 14+)。ActivityRecord は入れ物なので除く */
    private static List<String> appLayers(UiAutomation ua, String pkg) {
        List<String> result = new ArrayList<>();
        String out = BridgeRouter.rawShell(ua, "dumpsys SurfaceFlinger --list");
        for (String line : out.split("\n")) {
            String name = line.trim();
            if (name.startsWith("RequestedLayerState{")) {
                name = name.substring("RequestedLayerState{".length());
                int end = name.indexOf(" parentId=");
                name = end >= 0 ? name.substring(0, end) : name.replace("}", "");
            }
            // "pkg/" で照合する: 素の pkg だと com.ftester.e2e が com.ftester.e2e.android 等の別アプリの層まで拾う
            // (裏に回ったアプリの層も一覧に残る)。層名は "pkg/Activity#N"・"<hex> pkg/..."・"SurfaceView[pkg/...]" の形
            if (name.isEmpty() || !name.contains(pkg + "/") || name.contains("ActivityRecord")) continue;
            if (!result.contains(name)) result.add(name);
        }
        return result;
    }

    /**
     * **引用符で包まない**: executeShellCommand はシェルを通さず空白で引数を分けるので、引用符は名前の一部として渡り層が見つからない
     * (全部 noFrame になった)。空白を含む名前は1つの引数にできないので読まない —— 空白入りは入れ物・leash・Background・Bounds の層で、
     * フレームを持つ層(`pkg/Activity#N`・Flutter の `SurfaceView[...](BLAST)#N`)は空白を含まない(Pixel 4a・Android 13 で確認)
     */
    private static Frames readFrames(UiAutomation ua, String layer) {
        Frames f = new Frames();
        if (layer.matches(".*\\s.*")) return f;
        String out = BridgeRouter.rawShell(ua, "dumpsys SurfaceFlinger --latency " + layer);
        String[] lines = out.split("\n");
        for (int i = 1; i < lines.length; i++) { // 先頭行は更新周期(ns)
            String[] cols = lines[i].trim().split("\\s+");
            if (cols.length < 3) continue;
            try {
                long desired = Long.parseLong(cols[0]);
                long actual = Long.parseLong(cols[1]);
                long ready = Long.parseLong(cols[2]);
                if (desired == 0 && actual == 0 && ready == 0) continue;
                f.filledRows++;
                if (actual > 0 && actual < Long.MAX_VALUE) f.validPresents.add(actual);
            } catch (NumberFormatException e) {
                // 数値行でない行は読み飛ばす
            }
        }
        return f;
    }
}
