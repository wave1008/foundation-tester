package com.ftester.e2ey.android.fragments

import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.ConcatAdapter
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ey.android.DynamicIds
import com.ftester.e2ey.android.R
import com.google.android.material.button.MaterialButton

private const val SKELETON_ROWS = 8
private const val PAGE_FIRST = 30
private const val PAGE_SECOND = 20
private const val INITIAL_LOAD_MS = 2000L
private const val FOOTER_LOAD_MS = 1000L

private enum class Footer { LOADING, ERROR, END }

// A3: Paging3 の LoadState を模す。行は RowsAdapter、末尾の状態行は ConcatAdapter で足す FooterAdapter(LoadStateAdapter 相当)。
class LoadingFragment : Fragment(R.layout.fragment_loading) {

    private val handler = Handler(Looper.getMainLooper())
    private var generation = 0
    private var state = "loading"
    private var skeleton = true
    private var loaded = 0
    private var failedOnce = false
    private var footer: Footer? = null

    private lateinit var txtState: TextView
    private lateinit var txtCount: TextView
    private lateinit var txtResult: TextView
    private lateinit var rows: RowsAdapter
    private lateinit var footerAdapter: FooterAdapter

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        txtState = view.findViewById(R.id.txt_loading_state)
        txtCount = view.findViewById(R.id.txt_loading_count)
        txtResult = view.findViewById(R.id.txt_loading_result)
        val list = view.findViewById<RecyclerView>(R.id.list_loading)

        rows = RowsAdapter()
        footerAdapter = FooterAdapter()
        val lm = LinearLayoutManager(requireContext())
        list.layoutManager = lm
        list.adapter = ConcatAdapter(rows, footerAdapter)

        list.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(rv: RecyclerView, dx: Int, dy: Int) {
                if (dy > 0 && state == "loaded" && !rv.canScrollVertically(1)) loadMore()
            }
        })

        view.findViewById<MaterialButton>(R.id.btn_reload).setOnClickListener { restart() }
        restart()
    }

    private fun restart() {
        generation++
        handler.removeCallbacksAndMessages(null)
        skeleton = true
        loaded = 0
        failedOnce = false
        footer = null
        txtResult.text = "loading=none"
        render("loading")
        rows.notifyDataSetChanged()
        footerAdapter.notifyDataSetChanged()
        val g = generation
        handler.postDelayed({
            if (g != generation) return@postDelayed
            skeleton = false
            loaded = PAGE_FIRST
            render("loaded")
            rows.notifyDataSetChanged()
        }, INITIAL_LOAD_MS)
    }

    private fun loadMore() {
        val g = generation
        footer = Footer.LOADING
        render("loading")
        footerAdapter.notifyDataSetChanged()
        handler.postDelayed({
            if (g != generation) return@postDelayed
            when {
                loaded == PAGE_FIRST && !failedOnce -> {
                    failedOnce = true
                    footer = Footer.ERROR
                    render("error")
                }
                loaded == PAGE_FIRST -> {
                    val before = loaded
                    loaded += PAGE_SECOND
                    footer = null
                    render("loaded")
                    rows.notifyItemRangeInserted(before, PAGE_SECOND)
                }
                else -> {
                    footer = Footer.END
                    render("end")
                }
            }
            footerAdapter.notifyDataSetChanged()
        }, FOOTER_LOAD_MS)
    }

    private fun render(newState: String) {
        state = newState
        txtState.text = "state=$newState"
        txtCount.text = "loaded=$loaded"
    }

    override fun onDestroyView() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroyView()
    }

    private inner class RowsAdapter : RecyclerView.Adapter<TextHolder>() {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = inflateRow(parent)

        override fun getItemCount() = if (skeleton) SKELETON_ROWS else loaded

        override fun onBindViewHolder(holder: TextHolder, position: Int) {
            val t = holder.text
            val label = position.toString().padStart(2, '0')
            t.id = DynamicIds.of(t.context, "row_l_$label")
            t.text = "記事 $label"
            if (skeleton) {
                // 本物と同じ #id・ラベルのまま押せない灰色の帯(骨組み)。
                t.setBackgroundColor(Color.parseColor("#E0E0E0"))
                t.setTextColor(Color.parseColor("#E0E0E0"))
                t.setOnClickListener(null)
                t.isClickable = false
                t.isEnabled = false
            } else {
                t.setBackgroundResource(android.R.color.transparent)
                t.setTextColor(Color.BLACK)
                t.isEnabled = true
                t.isClickable = true
                t.setOnClickListener { txtResult.text = "loading=row_l_$label" }
            }
        }
    }

    private inner class FooterAdapter : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        override fun getItemCount() = if (footer == null) 0 else 1

        override fun getItemViewType(position: Int) = footer!!.ordinal

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
            val layout = when (Footer.values()[viewType]) {
                Footer.LOADING -> R.layout.item_footer_loading
                Footer.ERROR -> R.layout.item_footer_error
                Footer.END -> R.layout.item_footer_end
            }
            val v = LayoutInflater.from(parent.context).inflate(layout, parent, false)
            if (viewType == Footer.ERROR.ordinal) {
                v.findViewById<View>(R.id.btn_retry).setOnClickListener { loadMore() }
            }
            return object : RecyclerView.ViewHolder(v) {}
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) = Unit
    }
}
