package com.example.ftbridge;

/**
 * 1つの観測の最初のフレームの確定(ResponseObserver が --latency-clear の各回の直前の読みを当てる)。Android に依存しない
 * = Tests/FTCoreTests/AndroidFirstFrameStateTests が javac で動かして固定する。呼び手は ResponseObserver のロックの中で使う。
 * - 見つかったフレームは確定(以後の読みで変えない)
 * - 確定の前に履歴の不足を見たら、最初のフレームは言えない(後で見つかるフレームは消えた分より後かもしれない)= 以後は確定せず
 *   frameHistoryIncomplete
 * - noFrame は暫定 = 何もしない(待ちの途中や締めの前に出るフレームを後の回・取得の読みで拾う)
 */
final class FirstFrameState {
    static final String FRAME_HISTORY_INCOMPLETE = "frameHistoryIncomplete";

    private Long delay;
    private boolean incompleteSeen = false;

    /** 確定済みならもう読まなくてよい(取得も今の履歴を読まない) */
    boolean decided() {
        return delay != null || incompleteSeen;
    }

    /** ResponseProbe.firstFrameWithin の結果 {Long delay, String reason} を当てる */
    void absorb(Object[] read) {
        if (decided()) return;
        if (FRAME_HISTORY_INCOMPLETE.equals(read[1])) incompleteSeen = true;
        else if (read[0] != null) delay = (Long) read[0];
    }

    /** 確定した結果 {delay, reason}。未確定なら null(呼び手は最後に消した後の履歴を読んでその結果を使う) */
    Object[] decidedResult() {
        if (delay != null) return new Object[] {delay, null};
        if (incompleteSeen) return new Object[] {null, FRAME_HISTORY_INCOMPLETE};
        return null;
    }
}
