package com.ftester.e2ey.android.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.RecyclerView
import androidx.recyclerview.widget.StaggeredGridLayoutManager
import com.ftester.e2ey.android.DynamicIds
import com.ftester.e2ey.android.R

// A12: StaggeredGridLayoutManager(2 列)。タイル i の高さ = 80 + ((i * 37) % 5) * 30 dp。
class StaggeredFragment : Fragment(R.layout.fragment_staggered) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_staggered_result)
        txtResult.text = "stag=none"
        val grid = view.findViewById<RecyclerView>(R.id.grid_staggered)
        grid.layoutManager = StaggeredGridLayoutManager(2, StaggeredGridLayoutManager.VERTICAL)
        val density = resources.displayMetrics.density
        grid.adapter = object : RecyclerView.Adapter<TextHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = TextHolder(
                LayoutInflater.from(parent.context).inflate(R.layout.item_tile, parent, false) as TextView
            )

            override fun onBindViewHolder(holder: TextHolder, position: Int) {
                val nn = position.toString().padStart(2, '0')
                holder.text.id = DynamicIds.of(holder.text.context, "stag_$nn")
                holder.text.text = "タイル $nn"
                holder.text.layoutParams = holder.text.layoutParams.apply {
                    height = ((80 + ((position * 37) % 5) * 30) * density).toInt()
                }
                holder.text.setOnClickListener { txtResult.text = "stag=stag_$nn" }
            }

            override fun getItemCount() = 60
        }
    }
}
