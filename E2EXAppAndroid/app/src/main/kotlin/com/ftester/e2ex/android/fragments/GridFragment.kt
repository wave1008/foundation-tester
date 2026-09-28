package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ex.android.DynamicIds
import com.ftester.e2ex.android.R
import com.ftester.e2ex.android.paddedName

private const val CELL_COUNT = 90

class GridFragment : Fragment(R.layout.fragment_grid) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_grid_result)
        val grid = view.findViewById<RecyclerView>(R.id.grid_main)
        txtResult.text = "grid=none"

        grid.layoutManager = GridLayoutManager(requireContext(), 3)
        grid.adapter = object : RecyclerView.Adapter<CellHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): CellHolder {
                val itemView = LayoutInflater.from(parent.context)
                    .inflate(R.layout.item_grid_cell, parent, false)
                return CellHolder(itemView)
            }

            override fun onBindViewHolder(holder: CellHolder, position: Int) {
                val label = position.toString().padStart(2, '0')
                holder.itemView.id = DynamicIds.of(requireContext(), paddedName("cell_", position))
                (holder.itemView as TextView).text = "セル $label"
                holder.itemView.setOnClickListener {
                    txtResult.text = "grid=$label"
                }
            }

            override fun getItemCount() = CELL_COUNT
        }
    }

    private class CellHolder(itemView: View) : RecyclerView.ViewHolder(itemView)
}
