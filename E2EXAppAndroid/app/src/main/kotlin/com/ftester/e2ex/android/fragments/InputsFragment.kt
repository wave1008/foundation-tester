package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.widget.ArrayAdapter
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.R
import com.google.android.material.textfield.MaterialAutoCompleteTextView
import com.google.android.material.textfield.TextInputEditText

private val COUNTRIES = listOf("Japan", "Jamaica", "Jordan")

private fun watcher(onChanged: (String) -> Unit) = object : TextWatcher {
    override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
    override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
        onChanged(s?.toString().orEmpty())
    }
    override fun afterTextChanged(s: Editable?) = Unit
}

class InputsFragment : Fragment(R.layout.fragment_inputs) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtNumber = view.findViewById<TextView>(R.id.txt_number_echo)
        val txtPassword = view.findViewById<TextView>(R.id.txt_password_echo)
        val txtMultiline = view.findViewById<TextView>(R.id.txt_multiline_echo)
        val txtFocus = view.findViewById<TextView>(R.id.txt_focus_echo)
        val txtAuto = view.findViewById<TextView>(R.id.txt_auto_echo)
        val txtBottom = view.findViewById<TextView>(R.id.txt_bottom_echo)

        txtNumber.text = "number="
        txtPassword.text = "password_len=0"
        txtMultiline.text = "lines=1"
        txtFocus.text = "focus=none"
        txtAuto.text = "auto=none"
        txtBottom.text = "bottom="

        view.findViewById<TextInputEditText>(R.id.field_number).addTextChangedListener(
            watcher { txtNumber.text = "number=$it" }
        )
        view.findViewById<TextInputEditText>(R.id.field_password).addTextChangedListener(
            watcher { txtPassword.text = "password_len=${it.length}" }
        )
        view.findViewById<TextInputEditText>(R.id.field_multiline).addTextChangedListener(
            watcher { txtMultiline.text = "lines=${it.split("\n").size}" }
        )
        view.findViewById<TextInputEditText>(R.id.field_bottom).addTextChangedListener(
            watcher { txtBottom.text = "bottom=$it" }
        )

        // IME の「次へ」は同じ親の次の焦点可能な EditText へ自動で移る(OS 標準挙動。field_first
        // 側にリスナーは不要)。ここでは移った先(field_second)の focus 獲得だけを見る。
        view.findViewById<TextInputEditText>(R.id.field_second).setOnFocusChangeListener { _, hasFocus ->
            if (hasFocus) txtFocus.text = "focus=second"
        }

        val fieldAuto = view.findViewById<MaterialAutoCompleteTextView>(R.id.field_auto)
        fieldAuto.setAdapter(ArrayAdapter(requireContext(), android.R.layout.simple_list_item_1, COUNTRIES))
        // 候補ポップアップ(ListPopupWindow)の行 View は無名で #auto_opt_* を持たせられない
        // (docs/ui-contract.md の逸脱を参照。MenuFragment の #opt_fruit_* と同型)。
        fieldAuto.setOnItemClickListener { _, _, position, _ ->
            txtAuto.text = "auto=${COUNTRIES[position]}"
        }
    }
}
