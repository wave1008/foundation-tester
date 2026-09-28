package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.R
import com.google.android.material.timepicker.MaterialTimePicker
import com.google.android.material.timepicker.TimeFormat

private const val INITIAL_HOUR = 9
private const val INITIAL_MINUTE = 30

class TimeFragment : Fragment(R.layout.fragment_time) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_time_result)
        txtResult.text = "time=none"

        view.findViewById<View>(R.id.btn_open_time).setOnClickListener {
            // 入力モード(数字を打つ)への切替ボタンは MaterialTimePicker 標準の内蔵部品
            // (追加実装不要。契約の「入力モードに切り替えられる口」を満たす)。
            val picker = MaterialTimePicker.Builder()
                .setTimeFormat(TimeFormat.CLOCK_24H)
                .setHour(INITIAL_HOUR)
                .setMinute(INITIAL_MINUTE)
                .setInputMode(MaterialTimePicker.INPUT_MODE_CLOCK)
                .setPositiveButtonText("OK")
                .setNegativeButtonText("キャンセル")
                .build()
            // OK/キャンセルのボタンはライブラリ内部レイアウトの id を持ち #btn_time_ok/#btn_time_cancel
            // は存在しない(docs/ui-contract.md の逸脱を参照)。ラベルで指す前提。
            picker.addOnPositiveButtonClickListener {
                val h = picker.hour.toString().padStart(2, '0')
                val m = picker.minute.toString().padStart(2, '0')
                txtResult.text = "time=$h:$m"
            }
            picker.addOnNegativeButtonClickListener {
                txtResult.text = "time=cancel"
            }
            picker.addOnCancelListener {
                txtResult.text = "time=cancel"
            }
            picker.show(childFragmentManager, "time")
        }
    }
}
