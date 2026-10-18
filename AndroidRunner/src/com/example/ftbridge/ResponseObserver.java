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
        /** 上限(capMs)に達して読みを止めている。観測は閉じない(同じステップの次の注入で再開できる)。cappedAt = 期限(capBase + capMs) */
        boolean capped = false;
        long cappedAt = -1;
        /** 最初のフレームの確定(--latency-clear の各回の直前の読みを当てる。規則は FirstFrameState)。lock の中で触る */
        final FirstFrameState firstFrame = new FirstFrameState();
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
    /** 締めた観測を最初の downTime で引けるよう直近 MAX_CLOSED 件だけ持つ(古い側から捨てる)。1件だと、ホストが取りに来る前に
     *  次のステップの締めで上書きされうる。ホストは締まった観測を次のステップの注入の前に取るので、2件あれば取りこぼさない */
    static final int MAX_CLOSED = 2;
    private static final List<Obs> closedObs = new ArrayList<>();
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

    /** **順序制約**: SurfaceFlinger の履歴を --latency-clear で消す**各回の直前に**呼ぶ(ResponseProbe.prepare の待ちは何度も消す)。
     *  最初のフレームがまだ見つかっていない観測(実行中・締め済み)の分を、消える前の履歴から求める。見つかれば確定、
     *  履歴の不足は覚えるだけ、noFrame は何もしない(暫定)。探索の上限は実行中なら min(今, 上限の期限 = capBase + capMs)・
     *  締め済みは endedAt。dumpsys は遅いのでロックの外で読む */
    static void beforeLatencyClear(UiAutomation ua, String pkg) {
        if (pkg == null) return;
        List<Obs> targets = new ArrayList<>();
        List<Long> bounds = new ArrayList<>();
        synchronized (lock) {
            long now = SystemClock.uptimeMillis();
            if (running != null && !running.firstFrame.decided()) {
                targets.add(running);
                bounds.add(Math.min(now, running.capBase + running.capMs));
            }
            for (Obs c : closedObs) {
                if (!c.firstFrame.decided()) {
                    targets.add(c);
                    bounds.add(c.endedAt);
                }
            }
        }
        for (int i = 0; i < targets.size(); i++) {
            Obs o = targets.get(i);
            Object[] ff = ResponseProbe.firstFrameWithin(ua, pkg, o.firstDown, bounds.get(i).longValue());
            synchronized (lock) {
                o.firstFrame.absorb(ff);
            }
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
            obs.capped = false;
            obs.cappedAt = -1;
        }
    }

    /** 締め終わった観測を最初の downTime で返す。締まっていない・知らない ID は null。
     *  最初のフレームは取得の時点で SurfaceFlinger から改めて求める(collect の時点で未提示だった遅いフレームを拾う)。
     *  dumpsys は遅いのでロックの外で読む(締めた観測は書き換わらない) */
    static JSONObject fetch(UiAutomation ua, String pkg, long firstDownTimeMs) throws org.json.JSONException {
        Obs obs = null;
        Object[] decidedFirstFrame = null;
        synchronized (lock) {
            for (Obs c : closedObs) {
                if (c.firstDown == firstDownTimeMs) obs = c;
            }
            if (obs != null) {
                decidedFirstFrame = obs.firstFrame.decidedResult();
            }
        }
        JSONObject o = new JSONObject();
        if (obs == null) {
            o.put("found", false);
            for (String k : new String[] {"firstDownTimeMs", "lastDownTimeMs", "injections", "endedAtMs",
                    "endReason", "reads", "trees", "truncated", "firstFrameDelayMs", "firstFrameReason"}) {
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
        // 確定していれば(フレーム、または確定の前に見た履歴の不足)それ。未確定なら最後に消した後の履歴を今読む(締めまでの残り)
        Object[] ff = decidedFirstFrame != null ? decidedFirstFrame
                : ResponseProbe.firstFrameWithin(ua, pkg, obs.firstDown, obs.endedAt);
        o.put("firstFrameDelayMs", ff[0] == null ? JSONObject.NULL : ff[0]);
        o.put("firstFrameReason", ff[1] == null ? JSONObject.NULL : ff[1]);
        return o;
    }

    /** シナリオの終わり: 実行中を締め、それ以外の記録は捨てる。締めた1件だけ残す = ホストが stop の後に最後の計測ステップの
     *  最初のフレームを取りに来る(残りは次の close が MAX_CLOSED で押し出す)。注入の記録も解く(解かないと stop の後の普通の操作が
     *  新しい観測を始める)。injector のロックは observer のロックの内側で取る(許される向き。injector は自分のロック中に observer を呼ばない) */
    static void stopAll() {
        synchronized (lock) {
            closedObs.clear();
            if (running != null) close(running, "stopped", SystemClock.uptimeMillis());
            running = null;
            InputInjector.disarmAndClear();
        }
    }

    /** lock を持って呼ぶ。closed に移す。上限に達していたら理由は cap・締めた時刻は達した時刻(読みはそこで止まっている。
     *  最初のフレームの探索もそこで切る = 上限より後の描画をこのステップに数えない) */
    private static void close(Obs obs, String reason, long endedAt) {
        refreshStats(obs);
        // 期限(capBase + capMs)を過ぎてから締めるなら、検知が遅れただけで上限には達していた
        if (!obs.capped && endedAt > obs.capBase + obs.capMs) {
            obs.capped = true;
            obs.cappedAt = obs.capBase + obs.capMs;
        }
        if (obs.capped) {
            reason = "cap";
            endedAt = obs.cappedAt;
        }
        obs.closed = true;
        obs.endReason = reason;
        obs.endedAt = endedAt;
        if (running == obs) running = null;
        closedObs.add(obs);
        while (closedObs.size() > MAX_CLOSED) closedObs.remove(0);
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
                if (!obs.capped && t0 - obs.capBase >= obs.capMs) {
                    obs.capped = true;
                    obs.cappedAt = obs.capBase + obs.capMs; // 検知の時刻ではなく期限
                }
                skip = obs.truncated || obs.capped;
            }
            if (skip) {
                // 打ち切り・上限の後は木を読まない(同じステップの次の注入での記録し直しか締めを待つだけ)
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
                if (!obs.capped && t1 > obs.capBase + obs.capMs) {
                    obs.capped = true;
                    obs.cappedAt = obs.capBase + obs.capMs;
                }
                if (obs.capped) continue; // 期限をまたいだ・期限の後に終わった読みは入れない
                if (!obs.truncated && obs.reads.size() >= MAX_READS) obs.truncated = true;
                if (!obs.truncated) {
                    boolean changed = json != null && !json.equals(obs.lastTreeJson);
                    if (changed && obs.trees.size() >= MAX_TREES) {
                        // 変わった木を置けない読みは足さない: 足すと判定が前の木をその読みへ持ち越し、古い木で「2回連続で保持」と誤る
                        obs.truncated = true;
                    } else {
                        int idx = obs.reads.size();
                        obs.reads.add(new long[] {t0, t1, json != null ? 1 : 0});
                        if (changed) {
                            obs.trees.add(new Object[] {Integer.valueOf(idx), json});
                            obs.lastTreeJson = json;
                        }
                    }
                }
                // 打ち切った後もスレッドは終わらせない(同じステップの次の DOWN で記録し直す)。記録しない間は空回りしない
                idle = obs.truncated;
            }
            if (json == null || idle) SystemClock.sleep(FAILURE_BACKOFF_MS);
        }
    }
}
