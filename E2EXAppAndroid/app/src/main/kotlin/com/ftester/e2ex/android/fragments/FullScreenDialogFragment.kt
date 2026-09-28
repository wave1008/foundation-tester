package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.core.os.bundleOf
import androidx.fragment.app.DialogFragment
import com.ftester.e2ex.android.R

const val FULLSCREEN_REQUEST_KEY = "fullscreen_result"

class FullScreenDialogFragment : DialogFragment() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setStyle(STYLE_NORMAL, R.style.Theme_FTE2EX_FullScreenDialog)
    }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View = inflater.inflate(R.layout.dialog_fullscreen, container, false)

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        fun finish(value: String) {
            parentFragmentManager.setFragmentResult(FULLSCREEN_REQUEST_KEY, bundleOf("value" to value))
            dismiss()
        }
        view.findViewById<View>(R.id.btn_fullscreen_save).setOnClickListener { finish("saved") }
        view.findViewById<View>(R.id.btn_fullscreen_close).setOnClickListener { finish("closed") }
    }

    override fun onStart() {
        super.onStart()
        // STYLE_NORMAL のダイアログ既定は wrap_content なので、全画面に見せるため明示的に広げる。
        dialog?.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    }
}
