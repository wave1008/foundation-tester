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
import com.ftester.e2ex.android.paddedName

private const val ROW_COUNT = 50

class CollapseFragment : Fragment(R.layout.fragment_collapse) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_collapse_result)
        txtResult.text = "collapse=none"

        val recycler = view.findViewById<RecyclerView>(R.id.recycler_collapse)
        recycler.layoutManager = LinearLayoutManager(requireContext())
        recycler.adapter = object : RecyclerView.Adapter<RowHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RowHolder {
                val itemView = LayoutInflater.from(parent.context)
                    .inflate(R.layout.item_collapse_row, parent, false)
                return RowHolder(itemView)
            }

            override fun onBindViewHolder(holder: RowHolder, position: Int) {
                val label = position.toString().padStart(2, '0')
                holder.itemView.id = DynamicIds.of(requireContext(), paddedName("row_c_", position))
                (holder.itemView as TextView).text = "行 C$label"
                holder.itemView.setOnClickListener {
                    txtResult.text = "collapse=row_c_$label"
                }
            }

            override fun getItemCount() = ROW_COUNT
        }
    }

    private class RowHolder(itemView: View) : RecyclerView.ViewHolder(itemView)
}
