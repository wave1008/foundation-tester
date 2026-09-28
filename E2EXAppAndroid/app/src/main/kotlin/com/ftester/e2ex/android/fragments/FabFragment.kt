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
import com.google.android.material.bottomappbar.BottomAppBar

private const val ROW_COUNT = 30

class FabFragment : Fragment(R.layout.fragment_fab) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_fab_result)
        txtResult.text = "fab=none"

        val recycler = view.findViewById<RecyclerView>(R.id.recycler_fab)
        recycler.layoutManager = LinearLayoutManager(requireContext())
        recycler.adapter = object : RecyclerView.Adapter<RowHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RowHolder {
                val itemView = LayoutInflater.from(parent.context)
                    .inflate(R.layout.item_fab_row, parent, false)
                return RowHolder(itemView)
            }

            override fun onBindViewHolder(holder: RowHolder, position: Int) {
                val label = position.toString().padStart(2, '0')
                holder.itemView.id = DynamicIds.of(requireContext(), paddedName("row_f_", position))
                (holder.itemView as TextView).text = "行 F$label"
            }

            override fun getItemCount() = ROW_COUNT
        }

        view.findViewById<View>(R.id.fab_add).setOnClickListener { txtResult.text = "fab=add" }
        view.findViewById<View>(R.id.fab_extended).setOnClickListener { txtResult.text = "fab=extended" }

        view.findViewById<BottomAppBar>(R.id.bottom_app_bar).setOnMenuItemClickListener { item ->
            txtResult.text = "fab=" + when (item.itemId) {
                R.id.bar_action_search -> "search"
                R.id.bar_action_share -> "share"
                else -> "none"
            }
            true
        }
    }

    private class RowHolder(itemView: View) : RecyclerView.ViewHolder(itemView)
}
