package com.ftester.e2ey.android.fragments

import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.core.os.bundleOf
import androidx.fragment.app.Fragment
import androidx.navigation.fragment.findNavController
import com.ftester.e2ey.android.R

const val BACK_RESULT_KEY = "back_guard_result"

class BackGuardFragment : Fragment(R.layout.fragment_back_guard) {

    private var result = "none"
    private var txtResult: TextView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        parentFragmentManager.setFragmentResultListener(BACK_RESULT_KEY, this) { _, b ->
            result = b.getString("r") ?: "none"
            txtResult?.text = "back=$result"
        }
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        txtResult = view.findViewById<TextView>(R.id.txt_back_result).also { it.text = "back=$result" }
        view.findViewById<View>(R.id.btn_open_editor).setOnClickListener {
            findNavController().navigate(R.id.editorFragment, bundleOf())
        }
    }

    override fun onDestroyView() {
        txtResult = null
        super.onDestroyView()
    }
}
