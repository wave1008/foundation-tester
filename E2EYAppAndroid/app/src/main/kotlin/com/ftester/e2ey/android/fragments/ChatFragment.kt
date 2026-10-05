package com.ftester.e2ey.android.fragments

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ey.android.DynamicIds
import com.ftester.e2ey.android.R
import com.google.android.material.button.MaterialButton

private class Msg(val index: Int, val text: String)

private const val INITIAL_COUNT = 60

// A2: reverseLayout=true の RecyclerView。位置 0 = 最新 = 画面の最下部なので、木の並びと見た目の上下が逆になる。
class ChatFragment : Fragment(R.layout.fragment_chat) {

    private val handler = Handler(Looper.getMainLooper())
    private val newestFirst = ArrayList<Msg>()
    private var nextIndex = INITIAL_COUNT

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_chat_result)
        val txtCount = view.findViewById<TextView>(R.id.txt_chat_count)
        val txtPos = view.findViewById<TextView>(R.id.txt_chat_pos)
        val list = view.findViewById<RecyclerView>(R.id.list_chat)
        val jump = view.findViewById<MaterialButton>(R.id.btn_jump_bottom)
        val field = view.findViewById<EditText>(R.id.field_chat)

        newestFirst.clear()
        nextIndex = INITIAL_COUNT
        for (i in INITIAL_COUNT - 1 downTo 0) {
            newestFirst.add(Msg(i, "メッセージ " + i.toString().padStart(2, '0')))
        }
        txtResult.text = "chat=none"

        val lm = LinearLayoutManager(requireContext()).apply { reverseLayout = true }
        list.layoutManager = lm
        val adapter = object : RecyclerView.Adapter<TextHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): TextHolder {
                val h = inflateRow(parent)
                return h
            }

            override fun onBindViewHolder(holder: TextHolder, position: Int) {
                val m = newestFirst[position]
                holder.text.id = DynamicIds.ofOrNone(holder.text.context, "msg_" + m.index.toString().padStart(2, '0'))
                holder.text.text = m.text
                holder.text.setOnClickListener {
                    txtResult.text = "chat=msg_" + m.index.toString().padStart(2, '0')
                }
            }

            override fun getItemCount() = newestFirst.size
        }
        list.adapter = adapter

        fun atBottom() = lm.findFirstCompletelyVisibleItemPosition() == 0

        fun renderPos() {
            txtCount.text = "count=${newestFirst.size}"
            val bottom = atBottom()
            txtPos.text = "at_bottom=$bottom"
            jump.visibility = if (bottom) View.GONE else View.VISIBLE
        }
        txtCount.text = "count=${newestFirst.size}"
        txtPos.text = "at_bottom=true"
        list.post { renderPos() }

        list.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrollStateChanged(rv: RecyclerView, newState: Int) {
                if (newState == RecyclerView.SCROLL_STATE_IDLE) renderPos()
            }

            override fun onScrolled(rv: RecyclerView, dx: Int, dy: Int) {
                jump.visibility = if (atBottom()) View.GONE else View.VISIBLE
            }
        })

        jump.setOnClickListener { list.smoothScrollToPosition(0) }

        fun append(msg: Msg, followIfAtBottom: Boolean) {
            val follow = followIfAtBottom && atBottom()
            newestFirst.add(0, msg)
            adapter.notifyItemInserted(0)
            txtCount.text = "count=${newestFirst.size}"
            if (follow) list.smoothScrollToPosition(0)
            list.post { jump.visibility = if (atBottom()) View.GONE else View.VISIBLE }
        }

        view.findViewById<MaterialButton>(R.id.btn_send).setOnClickListener {
            val text = field.text.toString()
            if (text.isEmpty()) return@setOnClickListener
            append(Msg(nextIndex++, text), followIfAtBottom = true)
            list.smoothScrollToPosition(0)
            field.text.clear()
        }

        view.findViewById<MaterialButton>(R.id.btn_incoming).setOnClickListener {
            handler.postDelayed({
                val n = nextIndex++
                append(Msg(n, "着信 " + n.toString().padStart(2, '0')), followIfAtBottom = true)
            }, 1000)
        }
    }

    override fun onDestroyView() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroyView()
    }
}
