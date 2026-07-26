package com.ftester.e2e.android

import android.app.Activity
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView

// 契約: E2EApp/docs/ui-contract.md「ID なし画面」。
// **この画面のビューに android:id を付けてはいけない**(方向セレクタだけで操作・検証できることの検証用)。
// XML を使わずコードで組むのは、レイアウト XML だと `@+id` を付けたくなる/付けないと
// 参照できないため。ここでは参照をローカル変数で持つので id が要らない。
// 最小高 48dp と行間は帯判定(:right が隣の行のスイッチを拾わない)の余裕。
fun buildNoIdScreen(activity: Activity, parent: ViewGroup): View {
    val density = activity.resources.displayMetrics.density
    fun dp(value: Int) = (value * density).toInt()

    val root = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(16), dp(16), dp(16))
        layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    }

    fun text(value: String): TextView = TextView(activity).apply {
        this.text = value
        minHeight = dp(24)
    }

    var notify = false
    var location = false
    var qty = 0

    root.addView(text("設定"))

    val notifyEcho = text("notify=off")
    root.addView(row(activity, dp(48)) { row ->
        row.addView(text("通知"), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        row.addView(Switch(activity).apply {
            setOnCheckedChangeListener { _, checked ->
                notify = checked
                notifyEcho.text = "notify=" + if (notify) "on" else "off"
            }
        })
    })
    root.addView(notifyEcho)

    val locationEcho = text("location=off")
    root.addView(row(activity, dp(48)) { row ->
        row.addView(text("位置情報"), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        row.addView(Switch(activity).apply {
            setOnCheckedChangeListener { _, checked ->
                location = checked
                locationEcho.text = "location=" + if (location) "on" else "off"
            }
        })
    })
    root.addView(locationEcho)

    val qtyEcho = text("qty=0")
    root.addView(row(activity, dp(48)) { row ->
        row.addView(Button(activity).apply {
            this.text = "変更"
            minHeight = dp(48)
            setOnClickListener {
                if (qty > 0) qty -= 1
                qtyEcho.text = "qty=$qty"
            }
        })
        row.addView(text("数量").apply {
            setPadding(dp(16), 0, dp(16), 0)
        })
        row.addView(Button(activity).apply {
            this.text = "変更"
            minHeight = dp(48)
            setOnClickListener {
                qty += 1
                qtyEcho.text = "qty=$qty"
            }
        })
    })
    root.addView(qtyEcho)

    return root
}

private fun row(activity: Activity, minHeightPx: Int,
                build: (LinearLayout) -> Unit): LinearLayout =
    LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = minHeightPx
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        build(this)
    }
