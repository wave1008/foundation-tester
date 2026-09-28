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
import com.ftester.e2ex.android.DynamicIds
import com.ftester.e2ex.android.R
import com.ftester.e2ex.android.paddedName

private const val INITIAL_COUNT = 20
private const val PAGE_SIZE = 20
private const val MAX_COUNT = 100
private const val LOAD_DELAY_MS = 800L
private const val VIEW_TYPE_ROW = 0
private const val VIEW_TYPE_LOADING = 1

class InfiniteFragment : Fragment(R.layout.fragment_infinite) {

    private var loaded = INITIAL_COUNT
    private var isLoading = false
    private lateinit var adapter: InfiniteAdapter
    private lateinit var txtCount: TextView
    private val handler = Handler(Looper.getMainLooper())

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        txtCount = view.findViewById(R.id.txt_infinite_count)
        val txtResult = view.findViewById<TextView>(R.id.txt_infinite_result)
        txtResult.text = "infinite=none"
        renderCount()

        adapter = InfiniteAdapter { position ->
            val label = position.toString().padStart(2, '0')
            txtResult.text = "infinite=row_i_$label"
        }
        val recycler = view.findViewById<RecyclerView>(R.id.list_infinite)
        val layoutManager = LinearLayoutManager(requireContext())
        recycler.layoutManager = layoutManager
        recycler.adapter = adapter

        recycler.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(rv: RecyclerView, dx: Int, dy: Int) {
                if (isLoading || loaded >= MAX_COUNT) return
                val lastVisible = layoutManager.findLastVisibleItemPosition()
                if (lastVisible >= loaded - 5) startLoadingMore()
            }
        })
    }

    private fun startLoadingMore() {
        isLoading = true
        adapter.notifyItemInserted(loaded)
        handler.postDelayed({
            // 末尾の「読み込み中」を外して、増えた行だけを足す。notifyDataSetChanged は見えている行を全部
            // 付け替えるので、その瞬間に押している行のクリックが取り消される(読み込みと重なった tap が消える)
            val start = loaded
            isLoading = false
            adapter.notifyItemRemoved(start)
            loaded = minOf(loaded + PAGE_SIZE, MAX_COUNT)
            adapter.notifyItemRangeInserted(start, loaded - start)
            renderCount()
        }, LOAD_DELAY_MS)
    }

    private fun renderCount() {
        txtCount.text = "loaded=$loaded"
    }

    override fun onDestroyView() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroyView()
    }

    private inner class InfiniteAdapter(private val onRowClick: (Int) -> Unit) :
        RecyclerView.Adapter<RecyclerView.ViewHolder>() {

        override fun getItemCount() = loaded + if (isLoading) 1 else 0

        override fun getItemViewType(position: Int) =
            if (isLoading && position == loaded) VIEW_TYPE_LOADING else VIEW_TYPE_ROW

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
            val layoutRes = if (viewType == VIEW_TYPE_LOADING) {
                R.layout.item_infinite_loading
            } else {
                R.layout.item_infinite_row
            }
            val itemView = LayoutInflater.from(parent.context).inflate(layoutRes, parent, false)
            return object : RecyclerView.ViewHolder(itemView) {}
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            if (getItemViewType(position) == VIEW_TYPE_LOADING) return
            val label = position.toString().padStart(2, '0')
            holder.itemView.id = DynamicIds.of(requireContext(), paddedName("row_i_", position))
            (holder.itemView as TextView).text = "項目 $label"
            holder.itemView.setOnClickListener { onRowClick(position) }
        }
    }
}
