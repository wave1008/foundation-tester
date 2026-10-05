package com.ftester.e2ey.android.views

import android.content.Context
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.widget.FrameLayout
import kotlin.math.abs

// 子: 0 = 左側の操作(右へ払うと出る) / 1 = 右側の操作(左へ払うと出る) / 2 = 前面の行本体。
// 操作ボタンは払い始めるまで GONE(木に居ない)。操作の幅はレイアウト側の固定 dp と START_DP / END_DP を揃える。
class SwipeRevealLayout @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) :
    FrameLayout(context, attrs) {

    var onFullSwipe: (() -> Unit)? = null

    private val density = resources.displayMetrics.density
    private val startWidth = START_DP * density
    private val endWidth = END_DP * density
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var base = 0f
    private var dragging = false

    private val startActions get() = getChildAt(0)
    private val endActions get() = getChildAt(1)
    val foreground: View get() = getChildAt(2)

    val isOpen get() = foreground.translationX != 0f

    fun reset() {
        foreground.animate().cancel()
        foreground.translationX = 0f
        startActions.visibility = GONE
        endActions.visibility = GONE
    }

    fun close() = settleTo(0f)

    private fun setOffset(x: Float) {
        val clamped = x.coerceIn(-width.toFloat(), startWidth)
        foreground.translationX = clamped
        startActions.visibility = if (clamped > 0f) VISIBLE else GONE
        endActions.visibility = if (clamped < 0f) VISIBLE else GONE
    }

    private fun settleTo(target: Float, after: (() -> Unit)? = null) {
        foreground.animate().cancel()
        foreground.animate().translationX(target).setDuration(150).withEndAction {
            if (target == 0f) {
                startActions.visibility = GONE
                endActions.visibility = GONE
            }
            after?.invoke()
        }.start()
    }

    private fun settle() {
        val x = foreground.translationX
        val delta = x - base
        val opposes = base != 0f && (delta * base < 0f) && abs(delta) > 24 * density
        when {
            opposes -> settleTo(0f)
            x < -FULL_SWIPE_RATIO * width -> settleTo(-width.toFloat()) { onFullSwipe?.invoke() }
            x <= -OPEN_RATIO * endWidth -> settleTo(-endWidth)
            x >= OPEN_RATIO * startWidth -> settleTo(startWidth)
            else -> settleTo(0f)
        }
    }

    override fun onInterceptTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.x
                downY = e.y
                base = foreground.translationX
                dragging = false
            }
            MotionEvent.ACTION_MOVE -> if (!dragging) {
                val dx = e.x - downX
                if (abs(dx) > slop && abs(dx) > abs(e.y - downY)) {
                    dragging = true
                    foreground.animate().cancel()
                    parent?.requestDisallowInterceptTouchEvent(true)
                }
            }
        }
        return dragging
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> return true
            MotionEvent.ACTION_MOVE -> if (dragging) setOffset(base + (e.x - downX))
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> if (dragging) {
                dragging = false
                settle()
            }
        }
        return true
    }

    companion object {
        const val START_DP = 96
        const val END_DP = 192

        // 全幅のこの割合を越えて離すと確定(定番の full swipe の閾値は半分前後)。
        private const val FULL_SWIPE_RATIO = 0.6f

        // 操作の幅のこの割合を越えて離すと開いたまま止まる。
        private const val OPEN_RATIO = 0.3f
    }
}
