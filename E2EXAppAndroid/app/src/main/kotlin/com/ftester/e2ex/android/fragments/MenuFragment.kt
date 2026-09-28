package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.View
import android.widget.ArrayAdapter
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.R
import com.google.android.material.button.MaterialButton
import androidx.appcompat.widget.PopupMenu
import com.google.android.material.textfield.MaterialAutoCompleteTextView

private val FRUIT_LABELS = listOf("りんご", "バナナ", "さくらんぼ")
private val FRUIT_VALUES = listOf("apple", "banana", "cherry")

class MenuFragment : Fragment(R.layout.fragment_menu) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val btnOpenMenu = view.findViewById<MaterialButton>(R.id.btn_open_menu)
        val txtMenuResult = view.findViewById<TextView>(R.id.txt_menu_result)
        val fieldFruit = view.findViewById<MaterialAutoCompleteTextView>(R.id.field_fruit)
        val txtFruitResult = view.findViewById<TextView>(R.id.txt_fruit_result)

        txtMenuResult.text = "menu=none"
        txtFruitResult.text = "fruit=none"

        btnOpenMenu.setOnClickListener {
            // PopupMenu は別ウィンドウの ListPopupWindow で描画され、行 View に resource-id は出ない
            // (E2EXAppAndroid/docs/ui-contract.md の逸脱を参照。ラベルでの一致が前提)。
            var chosen = false
            val popup = PopupMenu(requireContext(), btnOpenMenu)
            popup.inflate(R.menu.menu_actions)
            popup.setOnMenuItemClickListener { item ->
                chosen = true
                txtMenuResult.text = "menu=" + when (item.itemId) {
                    R.id.menu_item_copy -> "copy"
                    R.id.menu_item_share -> "share"
                    R.id.menu_item_delete -> "delete"
                    else -> "none"
                }
                true
            }
            popup.setOnDismissListener {
                if (!chosen) txtMenuResult.text = "menu=dismissed"
            }
            popup.show()
        }

        val adapter = ArrayAdapter(requireContext(), android.R.layout.simple_list_item_1, FRUIT_LABELS)
        fieldFruit.setAdapter(adapter)
        fieldFruit.setOnItemClickListener { _, _, position, _ ->
            txtFruitResult.text = "fruit=" + FRUIT_VALUES[position]
        }
    }
}
