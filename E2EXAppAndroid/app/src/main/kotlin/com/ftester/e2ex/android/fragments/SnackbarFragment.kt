package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.R
import com.google.android.material.snackbar.Snackbar

class SnackbarFragment : Fragment(R.layout.fragment_snackbar) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val root = view.findViewById<View>(R.id.snackbar_coordinator)
        val txtResult = view.findViewById<TextView>(R.id.txt_snackbar_result)
        txtResult.text = "snackbar=none"

        view.findViewById<View>(R.id.btn_show_snackbar).setOnClickListener {
            val snackbar = Snackbar.make(root, "削除しました", Snackbar.LENGTH_INDEFINITE)
            // 契約の Long(約10秒)/Short(約4秒)は Compose の SnackbarDuration 準拠の秒数で、
            // Android の LENGTH_LONG(約2.75秒)とは値が違うため setDuration で明示指定する。
            snackbar.duration = 10000
            snackbar.setAction("元に戻す") {
                txtResult.text = "snackbar=undo"
            }
            snackbar.addCallback(object : Snackbar.Callback() {
                override fun onDismissed(transientBottomBar: Snackbar?, event: Int) {
                    if (event != DISMISS_EVENT_ACTION) {
                        txtResult.text = "snackbar=dismissed"
                    }
                }
            })
            snackbar.show()
        }

        view.findViewById<View>(R.id.btn_show_snackbar_short).setOnClickListener {
            val snackbar = Snackbar.make(root, "保存しました", Snackbar.LENGTH_INDEFINITE)
            snackbar.duration = 4000
            snackbar.addCallback(object : Snackbar.Callback() {
                override fun onDismissed(transientBottomBar: Snackbar?, event: Int) {
                    if (event != DISMISS_EVENT_ACTION) {
                        txtResult.text = "snackbar=short-dismissed"
                    }
                }
            })
            snackbar.show()
        }
    }
}
