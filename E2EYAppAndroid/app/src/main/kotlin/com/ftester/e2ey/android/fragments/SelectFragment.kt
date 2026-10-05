package com.ftester.e2ey.android.fragments

import android.os.Bundle
import android.util.TypedValue
import android.view.LayoutInflater
import android.view.Menu
import android.view.View
import android.view.ViewGroup
import android.widget.CheckedTextView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.view.ActionMode
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ey.android.DynamicIds
import com.ftester.e2ey.android.R
import com.google.android.material.button.MaterialButton

// A5: 長押しで ActionMode(バーを置き換える)に入る。バーの中身は customView(メニュー項目は resource-id を持てない)。
class SelectFragment : Fragment(R.layout.fragment_select) {

    private val items = (1..20).toMutableList()
    private val selected = sortedSetOf<Int>()
    private var actionMode: ActionMode? = null
    private lateinit var txtMode: TextView
    private lateinit var txtCount: TextView
    private lateinit var txtResult: TextView
    private lateinit var btnEdit: MaterialButton
    private lateinit var adapter: RecyclerView.Adapter<*>
    private var checkMarkRes = 0

    private val selectMode get() = actionMode != null

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        txtMode = view.findViewById(R.id.txt_select_mode)
        txtCount = view.findViewById(R.id.txt_select_count)
        txtResult = view.findViewById(R.id.txt_select_result)
        btnEdit = view.findViewById(R.id.btn_edit)
        txtResult.text = "select=none"

        val tv = TypedValue()
        requireContext().theme.resolveAttribute(android.R.attr.listChoiceIndicatorMultiple, tv, true)
        checkMarkRes = tv.resourceId

        adapter = SelectAdapter()
        view.findViewById<RecyclerView>(R.id.list_select).apply {
            layoutManager = LinearLayoutManager(requireContext())
            adapter = this@SelectFragment.adapter
        }
        btnEdit.setOnClickListener { if (selectMode) exit() else enter() }
        render()
    }

    private fun render() {
        txtMode.text = if (selectMode) "mode=select" else "mode=normal"
        txtCount.text = "selected=${selected.size}"
        btnEdit.text = if (selectMode) "完了" else "編集"
    }

    private fun enter() {
        if (selectMode) return
        actionMode = (requireActivity() as AppCompatActivity).startSupportActionMode(modeCallback)
        render()
        adapter.notifyDataSetChanged()
    }

    private fun exit() {
        actionMode?.finish()
    }

    private fun label(n: Int) = n.toString().padStart(2, '0')

    private val modeCallback = object : ActionMode.Callback {
        override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
            val bar = layoutInflater.inflate(R.layout.actionmode_select, null)
            bar.findViewById<View>(R.id.btn_sel_cancel).setOnClickListener { exit() }
            bar.findViewById<View>(R.id.btn_sel_all).setOnClickListener {
                selected.addAll(items)
                render()
                adapter.notifyDataSetChanged()
            }
            bar.findViewById<View>(R.id.btn_sel_delete).setOnClickListener {
                if (selected.isEmpty()) return@setOnClickListener
                val deleted = selected.joinToString(",") { label(it) }
                items.removeAll(selected)
                txtResult.text = "select=deleted:$deleted"
                exit()
            }
            mode.customView = bar
            return true
        }

        override fun onPrepareActionMode(mode: ActionMode, menu: Menu) = false

        override fun onActionItemClicked(mode: ActionMode, item: android.view.MenuItem) = false

        override fun onDestroyActionMode(mode: ActionMode) {
            actionMode = null
            selected.clear()
            if (view != null) {
                render()
                adapter.notifyDataSetChanged()
            }
        }
    }

    override fun onDestroyView() {
        actionMode?.finish()
        super.onDestroyView()
    }

    private inner class SelectAdapter : RecyclerView.Adapter<SelectHolder>() {
        override fun getItemCount() = items.size

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = SelectHolder(
            LayoutInflater.from(parent.context).inflate(R.layout.item_select_row, parent, false) as CheckedTextView
        )

        override fun onBindViewHolder(holder: SelectHolder, position: Int) {
            val n = items[position]
            val t = holder.text
            t.id = DynamicIds.of(t.context, "sel_row_${label(n)}")
            t.text = "項目 ${label(n)}"
            // AppCompatCheckedTextView は resId=0 で NotFoundException を投げるので、消すときは null の Drawable を渡す
            if (selectMode && checkMarkRes != 0) t.setCheckMarkDrawable(checkMarkRes) else t.setCheckMarkDrawable(null)
            t.isChecked = selectMode && n in selected
            t.setOnClickListener {
                if (selectMode) {
                    if (!selected.remove(n)) selected.add(n)
                    render()
                    notifyItemChanged(holder.bindingAdapterPosition)
                } else {
                    txtResult.text = "select=open:sel_row_${label(n)}"
                }
            }
            t.setOnLongClickListener {
                if (!selectMode) {
                    selected.add(n)
                    enter()
                }
                true
            }
        }
    }

    private class SelectHolder(val text: CheckedTextView) : RecyclerView.ViewHolder(text)
}
