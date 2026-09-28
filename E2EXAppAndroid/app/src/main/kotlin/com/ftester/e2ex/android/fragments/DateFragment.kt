package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.INITIAL_DATE_EPOCH_MILLIS
import com.ftester.e2ex.android.R
import com.ftester.e2ex.android.formatUtcDate
import com.google.android.material.datepicker.MaterialDatePicker

class DateFragment : Fragment(R.layout.fragment_date) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_date_result)
        txtResult.text = "date=none"

        view.findViewById<View>(R.id.btn_open_date).setOnClickListener {
            // MaterialDatePicker は選択値を UTC epoch millis で扱うため CMP の
            // INITIAL_DATE_EPOCH_MILLIS(2026-01-15 UTC)をそのまま渡せる(タイムゾーン変換不要)。
            val picker = MaterialDatePicker.Builder.datePicker()
                .setSelection(INITIAL_DATE_EPOCH_MILLIS)
                .setPositiveButtonText("OK")
                .setNegativeButtonText("キャンセル")
                .build()
            // ボタンは Material 内部レイアウトの id(confirm_button/cancel_button)を持ち、
            // #btn_date_ok/#btn_date_cancel は存在しない(docs/ui-contract.md の逸脱を参照)。
            picker.addOnPositiveButtonClickListener { selection ->
                txtResult.text = "date=" + formatUtcDate(selection)
            }
            picker.addOnNegativeButtonClickListener {
                txtResult.text = "date=cancel"
            }
            picker.addOnCancelListener {
                txtResult.text = "date=cancel"
            }
            picker.show(childFragmentManager, "date")
        }
    }
}
