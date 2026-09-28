package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import com.ftester.e2ex.android.R

private const val ROW_COUNT = 20

class RefreshFragment : Fragment(R.layout.fragment_refresh) {

    private var count = 0
    private val handler = Handler(Looper.getMainLooper())

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtCount = view.findViewById<TextView>(R.id.txt_refresh_count)
        val swipeRefresh = view.findViewById<SwipeRefreshLayout>(R.id.box_refresh)
        val recycler = view.findViewById<RecyclerView>(R.id.recycler_refresh)

        txtCount.text = "refresh=$count"
        recycler.layoutManager = LinearLayoutManager(requireContext())
        recycler.adapter = object : RecyclerView.Adapter<RowHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RowHolder {
                val itemView = LayoutInflater.from(parent.context)
                    .inflate(R.layout.item_refresh_row, parent, false)
                return RowHolder(itemView)
            }

            override fun onBindViewHolder(holder: RowHolder, position: Int) {
                holder.itemView.id = com.ftester.e2ex.android.DynamicIds.of(
                    requireContext(), com.ftester.e2ex.android.paddedName("row_refresh_", position)
                )
                (holder.itemView as TextView).text = "更新行 " + position.toString().padStart(2, '0')
            }

            override fun getItemCount() = ROW_COUNT
        }

        swipeRefresh.setOnRefreshListener {
            // 1.0 秒後に完了(契約 §引っ張って更新)。this 呼び手のアプリの応答ではなく固定の
            // 待ちなので画面離脱で握り潰してよい(onDestroyView で removeCallbacksAndMessages)。
            handler.postDelayed({
                swipeRefresh.isRefreshing = false
                count++
                txtCount.text = "refresh=$count"
            }, 1000)
        }
    }

    override fun onDestroyView() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroyView()
    }

    private class RowHolder(itemView: View) : RecyclerView.ViewHolder(itemView)
}
