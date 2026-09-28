package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ex.android.DynamicIds
import com.ftester.e2ex.android.R

class ReorderFragment : Fragment(R.layout.fragment_reorder) {

    private val rows = (1..5).toMutableList()
    private lateinit var adapter: ReorderAdapter
    private lateinit var txtResult: TextView

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        txtResult = view.findViewById(R.id.txt_reorder_result)
        renderResult()

        adapter = ReorderAdapter()
        val recycler = view.findViewById<RecyclerView>(R.id.recycler_reorder)
        recycler.layoutManager = LinearLayoutManager(requireContext())
        recycler.adapter = adapter

        // onMove はドラッグ中に隣接行をまたぐたび毎回呼ばれるので、都度 swap すれば
        // 指を離した最終位置まで(複数行分でも)正しく移動する(1回だけの隣接入替えにしない)。
        // isLongPressDragEnabled の既定は true(長押しでドラッグ開始)。
        val callback = object : ItemTouchHelper.SimpleCallback(
            ItemTouchHelper.UP or ItemTouchHelper.DOWN, 0
        ) {
            override fun onMove(
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
                target: RecyclerView.ViewHolder
            ): Boolean {
                val from = viewHolder.bindingAdapterPosition
                val to = target.bindingAdapterPosition
                if (from == RecyclerView.NO_POSITION || to == RecyclerView.NO_POSITION) return false
                rows.add(to, rows.removeAt(from))
                adapter.notifyItemMoved(from, to)
                renderResult()
                return true
            }

            override fun onSwiped(viewHolder: RecyclerView.ViewHolder, direction: Int) = Unit
        }
        ItemTouchHelper(callback).attachToRecyclerView(recycler)
    }

    private fun renderResult() {
        txtResult.text = "order=" + rows.joinToString(",")
    }

    private inner class ReorderAdapter : RecyclerView.Adapter<RowHolder>() {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RowHolder {
            val itemView = LayoutInflater.from(parent.context)
                .inflate(R.layout.item_reorder_row, parent, false)
            return RowHolder(itemView)
        }

        override fun onBindViewHolder(holder: RowHolder, position: Int) {
            val n = rows[position]
            holder.itemView.id = DynamicIds.of(requireContext(), "reorder_row_$n")
            (holder.itemView as TextView).text = "並べ替え $n"
        }

        override fun getItemCount() = rows.size
    }

    private class RowHolder(itemView: View) : RecyclerView.ViewHolder(itemView)
}
