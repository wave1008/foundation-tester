package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.ContextMenu
import android.view.MenuItem
import android.view.View
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.R

private const val MENU_EDIT = 1
private const val MENU_COPY = 2
private const val MENU_DELETE = 3

private val ROW_IDS = mapOf(R.id.ctx_row_1 to "row1", R.id.ctx_row_2 to "row2", R.id.ctx_row_3 to "row3")

class ContextFragment : Fragment(R.layout.fragment_context) {

    private lateinit var txtResult: TextView

    // registerForContextMenu の OnCreateContextMenuListener は長押しされた View を v として渡すが
    // onContextItemSelected は選択項目しか受け取らないため、直近に開いたメニューの行をここで覚える。
    private var activeRowId: Int = View.NO_ID

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        txtResult = view.findViewById(R.id.txt_context_result)
        txtResult.text = "context=none"

        ROW_IDS.keys.forEach { idRes -> registerForContextMenu(view.findViewById(idRes)) }
    }

    override fun onCreateContextMenu(menu: ContextMenu, v: View, menuInfo: ContextMenu.ContextMenuInfo?) {
        activeRowId = v.id
        menu.add(0, MENU_EDIT, 0, "編集")
        menu.add(0, MENU_COPY, 1, "複製")
        menu.add(0, MENU_DELETE, 2, "削除")
    }

    override fun onContextItemSelected(item: MenuItem): Boolean {
        val row = ROW_IDS[activeRowId] ?: return super.onContextItemSelected(item)
        val action = when (item.itemId) {
            MENU_EDIT -> "edit"
            MENU_COPY -> "copy"
            MENU_DELETE -> "delete"
            else -> return super.onContextItemSelected(item)
        }
        txtResult.text = "context=$row:$action"
        return true
    }
}
