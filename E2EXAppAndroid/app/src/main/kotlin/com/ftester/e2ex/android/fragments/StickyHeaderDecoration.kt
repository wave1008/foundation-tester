package com.ftester.e2ex.android.fragments

import android.graphics.Canvas
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ex.android.R

// 貼り付く見出しの定番レシピ(headerView を毎回 canvas に直接 draw するだけで RecyclerView の
// 子には加えない = a11y ツリーに出ない。実物の見出し行は Adapter 側が hdr_* の id 付きで別に持つ)。
class StickyHeaderDecoration(private val listener: Listener) : RecyclerView.ItemDecoration() {

    interface Listener {
        fun isHeader(position: Int): Boolean
        fun headerTextFor(position: Int): String
    }

    private var headerView: View? = null

    override fun onDrawOver(c: Canvas, parent: RecyclerView, state: RecyclerView.State) {
        val topChild = parent.getChildAt(0) ?: return
        val topPosition = parent.getChildAdapterPosition(topChild)
        if (topPosition == RecyclerView.NO_POSITION) return

        val headerPosition = findHeaderPositionForItem(topPosition)
        if (headerPosition == -1) return

        val header = getHeaderView(parent, headerPosition)
        fixLayoutSize(parent, header)

        val contactPoint = header.bottom
        val childInContact = getChildInContact(parent, contactPoint)

        if (childInContact != null && listener.isHeader(parent.getChildAdapterPosition(childInContact))) {
            moveHeader(c, header, childInContact)
        } else {
            drawHeader(c, header)
        }
    }

    private fun findHeaderPositionForItem(itemPosition: Int): Int {
        var position = itemPosition
        while (position >= 0) {
            if (listener.isHeader(position)) return position
            position--
        }
        return -1
    }

    private fun getHeaderView(parent: ViewGroup, headerPosition: Int): View {
        val view = headerView ?: LayoutInflater.from(parent.context)
            .inflate(R.layout.item_sticky_header_pinned, parent, false)
                .also { headerView = it }
        (view as TextView).text = listener.headerTextFor(headerPosition)
        return view
    }

    private fun drawHeader(c: Canvas, header: View) {
        c.save()
        c.translate(0f, 0f)
        header.draw(c)
        c.restore()
    }

    private fun moveHeader(c: Canvas, currentHeader: View, nextHeader: View) {
        c.save()
        c.translate(0f, (nextHeader.top - currentHeader.height).toFloat())
        currentHeader.draw(c)
        c.restore()
    }

    private fun getChildInContact(parent: RecyclerView, contactPoint: Int): View? {
        for (i in 0 until parent.childCount) {
            val child = parent.getChildAt(i)
            if (child.top <= contactPoint && child.bottom > contactPoint) return child
        }
        return null
    }

    private fun fixLayoutSize(parent: ViewGroup, view: View) {
        val widthSpec = View.MeasureSpec.makeMeasureSpec(parent.width, View.MeasureSpec.EXACTLY)
        val heightSpec = View.MeasureSpec.makeMeasureSpec(parent.height, View.MeasureSpec.UNSPECIFIED)
        val childWidthSpec = ViewGroup.getChildMeasureSpec(
            widthSpec, parent.paddingLeft + parent.paddingRight, view.layoutParams.width
        )
        val childHeightSpec = ViewGroup.getChildMeasureSpec(
            heightSpec, parent.paddingTop + parent.paddingBottom, view.layoutParams.height
        )
        view.measure(childWidthSpec, childHeightSpec)
        view.layout(0, 0, view.measuredWidth, view.measuredHeight)
    }
}
