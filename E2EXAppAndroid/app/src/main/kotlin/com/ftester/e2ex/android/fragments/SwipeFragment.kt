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

class SwipeFragment : Fragment(R.layout.fragment_swipe) {

    private val rows = (1..5).toMutableList()
    private lateinit var adapter: SwipeAdapter
    private lateinit var txtResult: TextView
    private lateinit var txtCount: TextView

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        txtResult = view.findViewById(R.id.txt_swipe_result)
        txtCount = view.findViewById(R.id.txt_swipe_count)
        val recycler = view.findViewById<RecyclerView>(R.id.recycler_swipe)

        txtResult.text = "removed=none"
        renderCount()

        adapter = SwipeAdapter()
        recycler.layoutManager = LinearLayoutManager(requireContext())
        recycler.adapter = adapter

        // 右から左(END-to-START)だけを許可(契約 §スワイプで削除: 左から右は無効)。
        val callback = object : ItemTouchHelper.SimpleCallback(0, ItemTouchHelper.LEFT) {
            override fun onMove(
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
                target: RecyclerView.ViewHolder
            ) = false

            override fun onSwiped(viewHolder: RecyclerView.ViewHolder, direction: Int) {
                val position = viewHolder.bindingAdapterPosition
                val removedValue = rows.removeAt(position)
                adapter.notifyItemRemoved(position)
                txtResult.text = "removed=$removedValue"
                renderCount()
            }
        }
        ItemTouchHelper(callback).attachToRecyclerView(recycler)
    }

    private fun renderCount() {
        txtCount.text = "rows=${rows.size}"
    }

    private inner class SwipeAdapter : RecyclerView.Adapter<RowHolder>() {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RowHolder {
            val itemView = LayoutInflater.from(parent.context)
                .inflate(R.layout.item_swipe_row, parent, false)
            return RowHolder(itemView)
        }

        override fun onBindViewHolder(holder: RowHolder, position: Int) {
            val n = rows[position]
            holder.itemView.id = DynamicIds.of(requireContext(), "swipe_row_$n")
            (holder.itemView as TextView).text = "スワイプ行 $n"
        }

        override fun getItemCount() = rows.size
    }

    private class RowHolder(itemView: View) : RecyclerView.ViewHolder(itemView)
}
