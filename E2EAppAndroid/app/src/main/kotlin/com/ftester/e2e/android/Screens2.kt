package com.ftester.e2e.android

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import kotlin.math.abs

private const val ROW_COUNT = 40

private fun rowTag(n: Int) = "row_%02d".format(n)
private fun rowLabel(n: Int) = "行 %02d".format(n)

fun buildGestureScreen(activity: Activity, parent: ViewGroup): View {
    val v = activity.layoutInflater.inflate(R.layout.screen_gesture, parent, false)
    var tap = 0
    var press = 0
    val tapCount = v.findViewById<TextView>(R.id.txt_tap_count)
    val pressCount = v.findViewById<TextView>(R.id.txt_press_count)
    val swipeDir = v.findViewById<TextView>(R.id.txt_swipe_dir)
    val last = v.findViewById<TextView>(R.id.txt_last_gesture)

    v.findViewById<Button>(R.id.btn_tap_counter).setOnClickListener {
        tap += 1
        tapCount.text = "tap=$tap"
        last.text = "last=tap"
    }
    // clickable=false / longClickable=true(XML)なので通常タップでは発火しない。
    v.findViewById<Button>(R.id.btn_long_press).setOnLongClickListener {
        press += 1
        pressCount.text = "press=$press"
        last.text = "last=longpress"
        true
    }

    val pad = v.findViewById<View>(R.id.pad_swipe)
    var downX = 0f
    var downY = 0f
    pad.setOnTouchListener { view, ev ->
        when (ev.action) {
            MotionEvent.ACTION_DOWN -> {
                downX = ev.x
                downY = ev.y
            }
            MotionEvent.ACTION_UP -> {
                val dx = ev.x - downX
                val dy = ev.y - downY
                // 判定は指の移動方向(上へ払う = up)。ブリッジの direction 定義と一致させる契約。
                if (abs(dx) > 20 || abs(dy) > 20) {
                    swipeDir.text = "swipe=" + if (abs(dx) > abs(dy)) {
                        if (dx < 0) "left" else "right"
                    } else {
                        if (dy < 0) "up" else "down"
                    }
                    last.text = "last=swipe"
                }
                view.performClick()
            }
        }
        true
    }

    v.findViewById<Button>(R.id.btn_gesture_reset).setOnClickListener {
        tap = 0
        press = 0
        tapCount.text = "tap=0"
        pressCount.text = "press=0"
        swipeDir.text = "swipe=-"
        last.text = "last=-"
    }
    return v
}

fun buildScrollScreen(activity: Activity, parent: ViewGroup): View {
    val v = activity.layoutInflater.inflate(R.layout.screen_scroll, parent, false)
    val selected = v.findViewById<TextView>(R.id.txt_row_selected)
    val list = v.findViewById<RecyclerView>(R.id.list_rows)
    list.layoutManager = LinearLayoutManager(activity)
    list.adapter = RowAdapter { n -> selected.text = "selected=${rowTag(n)}" }
    v.findViewById<Button>(R.id.btn_scroll_top).setOnClickListener { list.scrollToPosition(0) }
    return v
}

private class RowAdapter(val onClick: (Int) -> Unit) : RecyclerView.Adapter<RowAdapter.VH>() {
    class VH(val view: View) : RecyclerView.ViewHolder(view)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH =
        VH(android.view.LayoutInflater.from(parent.context).inflate(R.layout.item_row, parent, false))

    override fun getItemCount(): Int = ROW_COUNT

    override fun onBindViewHolder(holder: VH, position: Int) {
        val n = position + 1
        // 行内の TextView に id は付けない(40行で重複 id になるため)。位置で取る。
        ((holder.view as ViewGroup).getChildAt(0) as TextView).text = rowLabel(n)
        // View は resource-id を実行時生成できないため、res/values/ids.xml に静的宣言した
        // row_01..row_40 を割り当てる。これが無いと #row_NN が引けない。
        holder.view.id = ROW_IDS[position]
        holder.view.contentDescription = rowLabel(n)
        holder.view.setOnClickListener { onClick(n) }
    }

    companion object {
        val ROW_IDS = intArrayOf(
            R.id.row_01, R.id.row_02, R.id.row_03, R.id.row_04, R.id.row_05,
            R.id.row_06, R.id.row_07, R.id.row_08, R.id.row_09, R.id.row_10,
            R.id.row_11, R.id.row_12, R.id.row_13, R.id.row_14, R.id.row_15,
            R.id.row_16, R.id.row_17, R.id.row_18, R.id.row_19, R.id.row_20,
            R.id.row_21, R.id.row_22, R.id.row_23, R.id.row_24, R.id.row_25,
            R.id.row_26, R.id.row_27, R.id.row_28, R.id.row_29, R.id.row_30,
            R.id.row_31, R.id.row_32, R.id.row_33, R.id.row_34, R.id.row_35,
            R.id.row_36, R.id.row_37, R.id.row_38, R.id.row_39, R.id.row_40,
        )
    }
}

fun buildAsyncScreen(activity: Activity, parent: ViewGroup): View {
    val v = activity.layoutInflater.inflate(R.layout.screen_async, parent, false)
    val state = v.findViewById<TextView>(R.id.txt_delay_state)
    val delayed = v.findViewById<TextView>(R.id.txt_delayed)
    val countdown = v.findViewById<TextView>(R.id.txt_countdown)
    val handler = Handler(Looper.getMainLooper())

    fun reset() {
        // 前回タイマを消さないと、古い遅延が後から done を書き込んで検証を壊す。
        handler.removeCallbacksAndMessages(null)
        state.text = "state=idle"
        delayed.visibility = View.GONE
        countdown.visibility = View.GONE
    }

    fun startDelay(seconds: Int, withCountdown: Boolean) {
        handler.removeCallbacksAndMessages(null)
        state.text = "state=waiting"
        delayed.visibility = View.GONE
        countdown.visibility = View.GONE
        if (withCountdown) {
            for (n in seconds downTo 0) {
                handler.postDelayed({
                    countdown.text = "count=$n"
                    countdown.visibility = View.VISIBLE
                }, ((seconds - n) * 1000).toLong())
            }
        }
        handler.postDelayed({
            state.text = "state=done"
            delayed.visibility = View.VISIBLE
        }, seconds * 1000L)
    }

    v.findViewById<Button>(R.id.btn_delay_1).setOnClickListener { startDelay(1, false) }
    v.findViewById<Button>(R.id.btn_delay_3).setOnClickListener { startDelay(3, true) }
    v.findViewById<Button>(R.id.btn_delay_8).setOnClickListener { startDelay(8, false) }
    v.findViewById<Button>(R.id.btn_async_reset).setOnClickListener { reset() }
    return v
}

fun buildDialogScreen(activity: Activity, parent: ViewGroup): View {
    val v = activity.layoutInflater.inflate(R.layout.screen_dialog, parent, false)
    val result = v.findViewById<TextView>(R.id.txt_dialog_result)
    val autoText = v.findViewById<TextView>(R.id.txt_auto_dialog)
    val sw = v.findViewById<androidx.appcompat.widget.SwitchCompat>(R.id.sw_auto_dialog)
    var maybeCount = 0

    fun showDialog() {
        val content = activity.layoutInflater.inflate(R.layout.dialog_confirm, null)
        val dialog = AlertDialog.Builder(activity).setView(content).create()
        content.findViewById<Button>(R.id.btn_dialog_ok).setOnClickListener {
            result.text = "dialog=ok"
            dialog.dismiss()
        }
        content.findViewById<Button>(R.id.btn_dialog_cancel).setOnClickListener {
            result.text = "dialog=cancel"
            dialog.dismiss()
        }
        dialog.show()
    }

    sw.isChecked = Prefs.getBool("auto_dialog", false)
    autoText.text = "auto=${if (sw.isChecked) "on" else "off"}"
    sw.setOnCheckedChangeListener { _, checked ->
        Prefs.setBool("auto_dialog", checked)
        autoText.text = "auto=${if (checked) "on" else "off"}"
    }

    v.findViewById<Button>(R.id.btn_show_dialog).setOnClickListener { showDialog() }
    v.findViewById<Button>(R.id.btn_maybe_dialog).setOnClickListener {
        maybeCount += 1
        // 乱数不使用: 奇数回目だけ開く決定的な交互動作が検証要件。
        if (maybeCount % 2 == 1) showDialog()
    }

    // auto=on のとき、この画面に入るたびダイアログを自動で開く。
    if (sw.isChecked) v.post { showDialog() }
    return v
}

fun buildDiagnosticsScreen(activity: Activity, parent: ViewGroup): View {
    val v = activity.layoutInflater.inflate(R.layout.screen_diagnostics, parent, false)
    v.findViewById<TextView>(R.id.txt_build_info).text = "build=${AppInfo.VERSION}"
    v.findViewById<Button>(R.id.btn_freeze_3s).setOnClickListener {
        // ブリッジのタイムアウト挙動検証用にメインスレッドを 3 秒ブロックする。
        Thread.sleep(3000)
    }
    v.findViewById<Button>(R.id.btn_crash).setOnClickListener {
        val content = activity.layoutInflater.inflate(R.layout.dialog_crash, null)
        val dialog = AlertDialog.Builder(activity).setView(content).create()
        content.findViewById<Button>(R.id.btn_crash_cancel).setOnClickListener { dialog.dismiss() }
        content.findViewById<Button>(R.id.btn_crash_confirm).setOnClickListener {
            dialog.dismiss()
            throw RuntimeException("FT_E2E intentional crash")
        }
        dialog.show()
    }
    return v
}
