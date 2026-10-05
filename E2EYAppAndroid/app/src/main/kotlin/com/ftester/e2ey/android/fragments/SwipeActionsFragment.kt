package com.ftester.e2ey.android.fragments

import android.graphics.Canvas
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ey.android.DynamicIds
import com.ftester.e2ey.android.R
import com.ftester.e2ey.android.views.SwipeRevealLayout

// A4: 払う距離で結果が変わる reveal 行(自前の SwipeRevealLayout)と、ItemTouchHelper の閾値で返信する行。
class SwipeActionsFragment : Fragment(R.layout.fragment_swipe_actions) {

    private val rows = (1..6).toMutableList()
    private lateinit var txtResult: TextView
    private lateinit var txtCount: TextView
    private lateinit var txtReply: TextView
    private lateinit var adapter: SwipeAdapter

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        txtResult = view.findViewById(R.id.txt_swipe_actions_result)
        txtCount = view.findViewById(R.id.txt_swipe_actions_count)
        txtReply = view.findViewById(R.id.txt_reply_target)
        txtResult.text = "action=none"
        txtReply.text = "reply=none"
        renderCount()

        adapter = SwipeAdapter()
        view.findViewById<RecyclerView>(R.id.list_swipe_rows).apply {
            layoutManager = LinearLayoutManager(requireContext())
            adapter = this@SwipeActionsFragment.adapter
        }

        val replyList = view.findViewById<RecyclerView>(R.id.list_reply_rows)
        replyList.layoutManager = LinearLayoutManager(requireContext())
        val replyAdapter = ReplyAdapter()
        replyList.adapter = replyAdapter
        ItemTouchHelper(ReplyCallback(replyAdapter)).attachToRecyclerView(replyList)
    }

    private fun renderCount() {
        txtCount.text = "rows=${rows.size}"
    }

    private inner class SwipeAdapter : RecyclerView.Adapter<SwipeHolder>() {
        override fun getItemCount() = rows.size

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = SwipeHolder(
            LayoutInflater.from(parent.context).inflate(R.layout.item_swipe_row, parent, false) as SwipeRevealLayout
        )

        override fun onBindViewHolder(holder: SwipeHolder, position: Int) {
            val n = rows[position]
            val ctx = holder.itemView.context
            holder.row.reset()
            holder.label.id = DynamicIds.of(ctx, "sw_row_$n")
            holder.label.text = "スワイプ行 $n"
            holder.archive.id = DynamicIds.of(ctx, "btn_sw_archive_$n")
            holder.delete.id = DynamicIds.of(ctx, "btn_sw_delete_$n")
            holder.pin.id = DynamicIds.of(ctx, "btn_sw_pin_$n")

            holder.label.setOnClickListener {
                if (holder.row.isOpen) holder.row.close() else txtResult.text = "action=row$n:open"
            }
            holder.archive.setOnClickListener {
                txtResult.text = "action=row$n:archive"
                holder.row.close()
            }
            holder.pin.setOnClickListener {
                txtResult.text = "action=row$n:pin"
                holder.row.close()
            }
            holder.delete.setOnClickListener { remove(n) }
            holder.row.onFullSwipe = { remove(n) }
        }

        private fun remove(n: Int) {
            val pos = rows.indexOf(n)
            if (pos < 0) return
            rows.removeAt(pos)
            notifyItemRemoved(pos)
            txtResult.text = "action=row$n:delete"
            renderCount()
        }
    }

    private class SwipeHolder(val row: SwipeRevealLayout) : RecyclerView.ViewHolder(row) {
        val label: TextView = row.findViewById(R.id.txt_sw_row)
        val archive: View = row.findViewById(R.id.btn_sw_archive)
        val delete: View = row.findViewById(R.id.btn_sw_delete)
        val pin: View = row.findViewById(R.id.btn_sw_pin)
    }

    private inner class ReplyAdapter : RecyclerView.Adapter<TextHolder>() {
        override fun getItemCount() = 3

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = inflateRow(parent)

        override fun onBindViewHolder(holder: TextHolder, position: Int) {
            val n = position + 1
            holder.text.id = DynamicIds.of(holder.text.context, "reply_row_$n")
            holder.text.text = "返信行 $n"
            holder.text.setBackgroundColor(0xFFEEF1F6.toInt())
        }
    }

    // 離した位置が行幅の REPLY_THRESHOLD を越えたら返信。見た目は REPLY_MAX_DP までしか動かさず、行は消えない。
    private inner class ReplyCallback(private val replyAdapter: ReplyAdapter) :
        ItemTouchHelper.SimpleCallback(0, ItemTouchHelper.RIGHT) {

        private val maxPx = REPLY_MAX_DP * resources.displayMetrics.density

        override fun onMove(rv: RecyclerView, vh: RecyclerView.ViewHolder, target: RecyclerView.ViewHolder) = false

        override fun getSwipeThreshold(vh: RecyclerView.ViewHolder) = REPLY_THRESHOLD

        // 速度では確定させない(距離だけで決める)。
        override fun getSwipeEscapeVelocity(defaultValue: Float) = Float.MAX_VALUE

        override fun onChildDraw(
            c: Canvas, rv: RecyclerView, vh: RecyclerView.ViewHolder,
            dX: Float, dY: Float, actionState: Int, isCurrentlyActive: Boolean,
        ) {
            super.onChildDraw(c, rv, vh, minOf(dX, maxPx), dY, actionState, isCurrentlyActive)
        }

        override fun onSwiped(vh: RecyclerView.ViewHolder, direction: Int) {
            val pos = vh.bindingAdapterPosition
            if (pos == RecyclerView.NO_POSITION) return
            txtReply.text = "reply=reply_row_${pos + 1}"
            replyAdapter.notifyItemChanged(pos)
        }
    }

    companion object {
        private const val REPLY_THRESHOLD = 0.25f
        private const val REPLY_MAX_DP = 56
    }
}
