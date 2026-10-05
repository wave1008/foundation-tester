package com.ftester.e2ey.android.views

import android.content.Context
import android.util.AttributeSet
import android.view.View
import androidx.coordinatorlayout.widget.CoordinatorLayout
import androidx.core.view.ViewCompat
import com.google.android.material.floatingactionbutton.FloatingActionButton

// Thunderbird の HideFabOnScrollBehavior と同じ作り。hide() は消えきると GONE になり木からも消える。
class HideFabOnScrollBehavior(context: Context, attrs: AttributeSet?) :
    CoordinatorLayout.Behavior<FloatingActionButton>(context, attrs) {

    override fun onStartNestedScroll(
        coordinatorLayout: CoordinatorLayout, child: FloatingActionButton, directTargetChild: View,
        target: View, axes: Int, type: Int,
    ) = axes and ViewCompat.SCROLL_AXIS_VERTICAL != 0

    // AppBarLayout が先に消費すると一覧の dyConsumed が 0 になり向きが取れないので、消費前の dy で判定する。
    override fun onNestedPreScroll(
        coordinatorLayout: CoordinatorLayout, child: FloatingActionButton, target: View,
        dx: Int, dy: Int, consumed: IntArray, type: Int,
    ) {
        if (dy > 0) child.hide() else if (dy < 0) child.show()
    }

    // 一覧が実際に動いた分でも向きを拾う(上へ戻す送りの取りこぼしを塞ぐ)。
    override fun onNestedScroll(
        coordinatorLayout: CoordinatorLayout, child: FloatingActionButton, target: View,
        dxConsumed: Int, dyConsumed: Int, dxUnconsumed: Int, dyUnconsumed: Int, type: Int, consumed: IntArray,
    ) {
        if (dyConsumed < 0 || dyUnconsumed < 0) child.show()
    }
}
