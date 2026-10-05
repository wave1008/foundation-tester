package com.ftester.e2ey.android.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.widget.EditText
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.core.os.bundleOf
import androidx.fragment.app.Fragment
import androidx.navigation.fragment.findNavController
import com.ftester.e2ey.android.R
import com.google.android.material.dialog.MaterialAlertDialogBuilder

// A8: OnBackPressedDispatcher に常時有効なコールバックを積み、パネル → 確認ダイアログ → 素通しの順で扱う。
class EditorFragment : Fragment(R.layout.fragment_editor) {

    private var panelOpen = false

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtState = view.findViewById<TextView>(R.id.txt_editor_state)
        val field = view.findViewById<EditText>(R.id.field_title)
        val panel = view.findViewById<View>(R.id.panel_inline)
        panelOpen = false

        fun renderPanel() {
            panel.visibility = if (panelOpen) View.VISIBLE else View.GONE
            txtState.text = if (panelOpen) "panel=open" else "panel=closed"
        }
        renderPanel()
        view.findViewById<View>(R.id.btn_open_panel).setOnClickListener {
            panelOpen = true
            renderPanel()
        }

        fun leave(result: String) {
            parentFragmentManager.setFragmentResult(BACK_RESULT_KEY, bundleOf("r" to result))
            findNavController().popBackStack()
        }

        val guard = object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                when {
                    panelOpen -> {
                        panelOpen = false
                        renderPanel()
                    }
                    field.text.isNullOrEmpty() -> leave("clean")
                    else -> confirmDiscard { leave("discarded") }
                }
            }
        }
        requireActivity().onBackPressedDispatcher.addCallback(viewLifecycleOwner, guard)
    }

    private fun confirmDiscard(onDiscard: () -> Unit) {
        val content = LayoutInflater.from(requireContext()).inflate(R.layout.dialog_discard, null)
        val dialog = MaterialAlertDialogBuilder(requireContext()).setView(content).create()
        content.findViewById<View>(R.id.btn_keep).setOnClickListener { dialog.dismiss() }
        content.findViewById<View>(R.id.btn_discard).setOnClickListener {
            dialog.dismiss()
            onDiscard()
        }
        dialog.show()
    }
}
