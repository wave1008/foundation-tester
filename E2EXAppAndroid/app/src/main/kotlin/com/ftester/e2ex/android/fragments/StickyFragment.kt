package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ex.android.DynamicIds
import com.ftester.e2ex.android.R

private val SECTIONS = ('A'..'H').toList()
private const val ROWS_PER_SECTION = 10

private data class StickyItem(val isHeader: Boolean, val section: Char, val rowIndex: Int = -1)

private val ITEMS: List<StickyItem> = SECTIONS.flatMap { section ->
    listOf(StickyItem(true, section)) + (0 until ROWS_PER_SECTION).map { StickyItem(false, section, it) }
}

class StickyFragment : Fragment(R.layout.fragment_sticky) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_sticky_result)
        txtResult.text = "sticky=none"

        val recycler = view.findViewById<RecyclerView>(R.id.recycler_sticky)
        recycler.layoutManager = LinearLayoutManager(requireContext())
        recycler.adapter = StickyAdapter { section, rowIndex ->
            txtResult.text = "sticky=row_s_$section$rowIndex"
        }
        recycler.addItemDecoration(object : StickyHeaderDecoration.Listener {
            override fun isHeader(position: Int) = ITEMS.getOrNull(position)?.isHeader == true
            override fun headerTextFor(position: Int) = "セクション ${ITEMS[position].section}"
        }.let { StickyHeaderDecoration(it) })
    }

    private inner class StickyAdapter(private val onRowClick: (Char, Int) -> Unit) :
        RecyclerView.Adapter<RecyclerView.ViewHolder>() {

        override fun getItemViewType(position: Int) = if (ITEMS[position].isHeader) 0 else 1

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
            val layoutRes = if (viewType == 0) R.layout.item_sticky_header else R.layout.item_sticky_row
            val itemView = LayoutInflater.from(parent.context).inflate(layoutRes, parent, false)
            return object : RecyclerView.ViewHolder(itemView) {}
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            val item = ITEMS[position]
            val textView = holder.itemView as TextView
            if (item.isHeader) {
                holder.itemView.id = DynamicIds.of(requireContext(), "hdr_${item.section}")
                textView.text = "セクション ${item.section}"
            } else {
                holder.itemView.id = DynamicIds.of(requireContext(), "row_s_${item.section}${item.rowIndex}")
                textView.text = "行 ${item.section}${item.rowIndex}"
                holder.itemView.setOnClickListener { onRowClick(item.section, item.rowIndex) }
            }
        }

        override fun getItemCount() = ITEMS.size
    }
}
