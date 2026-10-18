// ResponseObserver.java
// 応答時間計測の t2 の観測。計測ステップの最初の ACTION_DOWN の後、アクセシビリティ木を読み続けて
// 全読みの時刻と、前の読みから変わった木だけを記録する。契約は Sources/FTCore/ResponseMeasurementWire.swift
// (ResponseObservation)。時刻はすべて SystemClock.uptimeMillis(MotionEvent.downTime と同じ時計)
package com.example.ftbridge;

import android.app.UiAutomation;
import android.content.Context;
import android.os.SystemClock;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

final class ResponseObserver {

    private ResponseObserver() {}

    /** 1観測の読み回数の上限。1回の記録は約 50 バイト(JSON)なので 5000 回でも約 250KB。
     *  上限 observeMs = 60s を読み1回 12ms 以上で読める範囲に収める(これを超える速さで読めた分は記録を打ち切って truncated で申告) */
    static final int MAX_READS = 5000;
    /** 変化した木の保存数の上限。30 では Pixel 4a の E2E-Android のスクロールのシナリオで計測した 32 ステップ中 3 ステップが打ち切られた
     *  (慣性の間は読むたびに枠が動き、毎回「変わった木」になる)。既定の要素上限(120)の木を 1 本約 30KB と見積もり、100 本で
     *  応答は約 3MB(保持は UTF-16 で倍)= adb forward で渡せる範囲。尽きたら truncated で申告する(ホストは observationTruncated) */
    static final int MAX_TREES = 100;
    /** 読めなかった(根が無い等)あとの待ち(ms)。build は根が無いと内部で待ってから投げるが、すぐ投げる例外もあり、
     *  待たないと UiAutomation を空回りで叩き続けてアプリの描画を妨げる */
    static final long FAILURE_BACKOFF_MS = 50;

    static final class Obs {
        final long firstDown;
        final long capMs;
        /** 上限(capMs)の起点 = このステップの直近の DOWN。記録し直し(onLaterDown)で進む */
        long capBase;
        long lastDown = -1;
        long injections = 0;
        long endedAt = -1;
        String endReason;
        boolean closed = false;
        boolean truncated = false;
        final List<long[]> reads = new ArrayList<>(); // {startMs, endMs, ok(1/0)}
        final List<Object[]> trees = new ArrayList<>(); // {Integer readIndex, String snapshotJson}
        String lastTreeJson;

        Obs(long firstDown, long capMs) {
            this.firstDown = firstDown;
            this.capMs = capMs;
            this.capBase = firstDown;
        }
    }

    /** 全状態を守る単一のロック。InputInjector のロックはこの内側でだけ取る(逆順は作らない) */
    private static final Object lock = new Object();
    private static Obs running;
    private static Obs closedObs;
    private static long pendingCapMs = 0;
    private static Context context;

    /** responsePrepare から、InputInjector.armFirstDown の前に呼ぶ。実行中の観測の最後の DOWN・回数は arm で消えるので先に写す */
    static void prepare(Context ctx, long observeMs) {
        synchronized (lock) {
            context = ctx;
            pendingCapMs = observeMs;
            if (running != null) refreshStats(running);
        }
    }

    /** InputInjector.inject から、計測ステップの最初の ACTION_DOWN を撃つ前に呼ぶ */
    static void onFirstDown(UiAutomation ua, long downTime) {
        final Obs obs;
        final Context ctx;
        synchronized (lock) {
            if (running != null) close(running, "nextInjection", downTime);
            obs = new Obs(downTime, pendingCapMs);
            ctx = context;
            running = obs;
        }
        final UiAutomation uiAutomation = ua;
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                readLoop(obs, uiAutomation, ctx);
            }
        }, "ft-response-observer");
        t.setDaemon(true);
        t.start();
    }

    /**
     * InputInjector.inject から、同じ計測ステップの2回目以降の ACTION_DOWN を撃つ前に呼ぶ(スクロールで探す操作・反復のフリック等)。
     * それまでの読みと木を捨ててこの DOWN から記録し直し、上限の起点もこの DOWN に移す —— ホストの判定は最後の注入より後の読みしか
     * 使わないので、捨てた分は要らない。捨てないと、何度も送る操作では最後の注入の前に記録の上限を使い切った(Pixel 4a の
     * スクロールのシナリオで 32 ステップ中 3 ステップが truncated)
     */
    static void onLaterDown(long downTime, int count) {
        synchronized (lock) {
            Obs obs = running;
            if (obs == null || obs.closed) return;
            long[] s = InputInjector.peekDownStats();
            if (s[0] != obs.firstDown) return; // 別のステップの arm に替わっている
            obs.lastDown = downTime;
            obs.injections = count;
            obs.capBase = downTime;
            obs.reads.clear();
            obs.trees.clear();
            obs.lastTreeJson = null;
            obs.truncated = false;
        }
    }

    /** 締め終わった観測を最初の downTime で返す。締まっていない・知らない ID は null */
    static JSONObject fetch(long firstDownTimeMs) throws org.json.JSONException {
        Obs obs;
        synchronized (lock) {
            obs = closedObs;
            if (obs == null || obs.firstDown != firstDownTimeMs) obs = null;
        }
        JSONObject o = new JSONObject();
        if (obs == null) {
            o.put("found", false);
            for (String k : new String[] {"firstDownTimeMs", "lastDownTimeMs", "injections", "endedAtMs",
                    "endReason", "reads", "trees", "truncated"}) {
                o.put(k, JSONObject.NULL);
            }
            return o;
        }
        // 締めた観測は reader が書かない(close 後の追記は closed で弾く)ので、ロックの外で組み立ててよい
        o.put("found", true);
        o.put("firstDownTimeMs", obs.firstDown);
        o.put("lastDownTimeMs", obs.lastDown < 0 ? JSONObject.NULL : (Object) obs.lastDown);
        o.put("injections", obs.injections);
        o.put("endedAtMs", obs.endedAt);
        o.put("endReason", obs.endReason);
        JSONArray reads = new JSONArray();
        for (long[] r : obs.reads) {
            JSONObject j = new JSONObject();
            j.put("startMs", r[0]);
            j.put("endMs", r[1]);
            j.put("ok", r[2] == 1);
            reads.put(j);
        }
        o.put("reads", reads);
        JSONArray trees = new JSONArray();
        for (Object[] tr : obs.trees) {
            JSONObject j = new JSONObject();
            j.put("readIndex", ((Integer) tr[0]).intValue());
            j.put("snapshot", new JSONObject((String) tr[1]));
            trees.put(j);
        }
        o.put("trees", trees);
        o.put("truncated", obs.truncated);
        return o;
    }

    /** シナリオの終わり: 実行中を止め、記録はすべて捨てる */
    static void stopAll() {
        synchronized (lock) {
            if (running != null) close(running, "stopped", SystemClock.uptimeMillis());
            running = null;
            closedObs = null;
        }
    }

    /** lock を持って呼ぶ。closed に移す(古い closed は置き換え) */
    private static void close(Obs obs, String reason, long endedAt) {
        refreshStats(obs);
        obs.closed = true;
        obs.endReason = reason;
        obs.endedAt = endedAt;
        if (running == obs) running = null;
        closedObs = obs;
    }

    /** lock を持って呼ぶ。injector がまだこの観測の arm のままなら最後の DOWN・回数を写す(別の arm に替わっていたら写さない) */
    private static void refreshStats(Obs obs) {
        long[] s = InputInjector.peekDownStats();
        if (s[0] == obs.firstDown) {
            obs.lastDown = s[1];
            obs.injections = s[2];
        }
    }

    /**
     * SnapshotBuilder.build は static で BridgeRouter の状態(refCenters 等)に触らず、結果は Result で返すだけ。
     * UiAutomation への同時の問い合わせは許されるので、HTTP スレッドの /snapshot と並行してよい
     */
    private static void readLoop(Obs obs, UiAutomation ua, Context ctx) {
        while (true) {
            long t0 = SystemClock.uptimeMillis();
            boolean skip;
            synchronized (lock) {
                if (obs.closed) return;
                if (t0 - obs.capBase >= obs.capMs) {
                    close(obs, "cap", t0);
                    return;
                }
                skip = obs.truncated;
            }
            if (skip) {
                // 打ち切った後は木を読まない(記録し直しか締めを待つだけ)
                SystemClock.sleep(FAILURE_BACKOFF_MS);
                continue;
            }
            String json = null;
            try {
                json = SnapshotBuilder.build(ua, ctx, false, SnapshotBuilder.MAX_ELEMENTS).json;
            } catch (Exception e) {
                // 根が取れない(IllegalStateException)等。読めなかった回として残す
            }
            long t1 = SystemClock.uptimeMillis();
            boolean idle;
            synchronized (lock) {
                if (obs.closed) return;
                // 記録し直しより前に始まった読みは捨てる(記録し直した後の列は最後の DOWN 以降だけにする)
                if (t0 < obs.capBase) continue;
                if (!obs.truncated && obs.reads.size() >= MAX_READS) obs.truncated = true;
                if (!obs.truncated) {
                    int idx = obs.reads.size();
                    obs.reads.add(new long[] {t0, t1, json != null ? 1 : 0});
                    if (json != null && !json.equals(obs.lastTreeJson)) {
                        if (obs.trees.size() >= MAX_TREES) {
                            obs.truncated = true;
                        } else {
                            obs.trees.add(new Object[] {Integer.valueOf(idx), json});
                            obs.lastTreeJson = json;
                        }
                    }
                }
                // 打ち切った後もスレッドは終わらせない(同じステップの次の DOWN で記録し直す・上限で締める)。記録しない間は空回りしない
                idle = obs.truncated;
            }
            if (json == null || idle) SystemClock.sleep(FAILURE_BACKOFF_MS);
        }
    }
}
