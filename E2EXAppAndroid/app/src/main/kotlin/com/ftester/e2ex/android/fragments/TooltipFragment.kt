package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.widget.PopupWindow
import android.widget.TextView
import androidx.appcompat.widget.TooltipCompat
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.R

// 自動で消えるまでの間。実プロダクトの慣習値(短い操作ヒントは 2〜3 秒前後)を採用。
private const val AUTO_DISMISS_MS = 2000L

class TooltipFragment : Fragment(R.layout.fragment_tooltip) {

    private var popup: PopupWindow? = null

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val anchor = view.findViewById<View>(R.id.btn_tooltip_anchor)
        val txtState = view.findViewById<TextView>(R.id.txt_tooltip_state)
        txtState.text = "tooltip=hidden"

        // OS 標準の TooltipCompat も付けておくが、そのポップアップは別プロセス描画で
        // id を持てないため、#txt_tooltip/#txt_tooltip_state の観測は自前 PopupWindow が担う
        // (docs/ui-contract.md の逸脱注記を参照)。
        TooltipCompat.setTooltipText(anchor, "情報")

        anchor.setOnLongClickListener {
            showTooltip(anchor, txtState)
            true
        }
    }

    private fun showTooltip(anchor: View, txtState: TextView) {
        val content = LayoutInflater.from(requireContext()).inflate(R.layout.popup_tooltip, null)
        content.findViewById<TextView>(R.id.txt_tooltip).text = "これはツールチップです"
        val window = PopupWindow(
            content,
            android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
            android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
            false
        )
        window.setOnDismissListener {
            txtState.text = "tooltip=hidden"
            popup = null
        }
        popup = window
        window.showAsDropDown(anchor)
        txtState.text = "tooltip=shown"
        anchor.postDelayed({ window.dismiss() }, AUTO_DISMISS_MS)
    }

    override fun onDestroyView() {
        popup?.dismiss()
        popup = null
        super.onDestroyView()
    }
}
