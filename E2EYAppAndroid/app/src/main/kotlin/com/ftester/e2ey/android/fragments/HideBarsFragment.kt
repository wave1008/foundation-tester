package com.ftester.e2ey.android.fragments

import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ey.android.DynamicIds
import com.ftester.e2ey.android.R
import com.google.android.material.appbar.AppBarLayout

// A10: 上部バーは AppBarLayout(scroll|enterAlways)、下部バーは HideBottomViewOnScrollBehavior、FAB は自前 Behavior。
class HideBarsFragment : Fragment(R.layout.fragment_hide_bars) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_hide_result)
        val txtBars = view.findViewById<TextView>(R.id.txt_bars_state)
        txtResult.text = "hide=none"
        txtBars.text = "bars=shown"

        val list = view.findViewById<RecyclerView>(R.id.list_hiding)
        list.layoutManager = LinearLayoutManager(requireContext())
        list.adapter = object : RecyclerView.Adapter<TextHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = inflateRow(parent)

            override fun onBindViewHolder(holder: TextHolder, position: Int) {
                val nn = position.toString().padStart(2, '0')
                holder.text.id = DynamicIds.of(holder.text.context, "row_h_$nn")
                holder.text.text = "行 H$nn"
                holder.text.setOnClickListener { txtResult.text = "hide=row_h_$nn" }
            }

            override fun getItemCount() = 60
        }

        // 止まった時点で上部バーが完全に隠れていれば hidden(一部でも見えていれば shown)。
        val appBar = view.findViewById<AppBarLayout>(R.id.appbar_hiding)
        list.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrollStateChanged(rv: RecyclerView, newState: Int) {
                if (newState != RecyclerView.SCROLL_STATE_IDLE) return
                val hidden = appBar.totalScrollRange > 0 && -appBar.top >= appBar.totalScrollRange
                txtBars.text = if (hidden) "bars=hidden" else "bars=shown"
            }
        })

        view.findViewById<View>(R.id.btn_top_action).setOnClickListener { txtResult.text = "hide=top_action" }
        view.findViewById<View>(R.id.fab_hiding).setOnClickListener { txtResult.text = "hide=fab" }
        view.findViewById<View>(R.id.btn_bottom_a).setOnClickListener { txtResult.text = "hide=bottom_a" }
        view.findViewById<View>(R.id.btn_bottom_b).setOnClickListener { txtResult.text = "hide=bottom_b" }
    }
}
