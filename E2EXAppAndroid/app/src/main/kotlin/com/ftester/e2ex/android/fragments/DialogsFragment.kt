package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.View
import android.widget.TextView
import android.widget.Toast
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.R
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.textfield.TextInputEditText

class DialogsFragment : Fragment(R.layout.fragment_dialogs) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_dialogs_result)
        txtResult.text = "dialogs=none"

        childFragmentManager.setFragmentResultListener(FULLSCREEN_REQUEST_KEY, viewLifecycleOwner) { _, bundle ->
            txtResult.text = "fullscreen=" + bundle.getString("value")
        }

        view.findViewById<View>(R.id.btn_alert).setOnClickListener {
            MaterialAlertDialogBuilder(requireContext())
                .setTitle("アラート")
                .setPositiveButton("OK") { _, _ -> txtResult.text = "alert=ok" }
                .setNegativeButton("キャンセル") { _, _ -> txtResult.text = "alert=cancel" }
                .setOnCancelListener { txtResult.text = "alert=cancel" }
                .show()
        }

        view.findViewById<View>(R.id.btn_prompt).setOnClickListener {
            val content = layoutInflater.inflate(R.layout.dialog_prompt_content, null)
            val field = content.findViewById<TextInputEditText>(R.id.field_prompt)
            MaterialAlertDialogBuilder(requireContext())
                .setTitle("入力つき")
                .setView(content)
                .setPositiveButton("保存") { _, _ -> txtResult.text = "prompt=" + (field.text ?: "") }
                .setNegativeButton("キャンセル") { _, _ -> txtResult.text = "prompt=cancel" }
                .setOnCancelListener { txtResult.text = "prompt=cancel" }
                .show()
        }

        view.findViewById<View>(R.id.btn_action_sheet).setOnClickListener {
            var chosen = false
            val dialog = BottomSheetDialog(requireContext())
            val content = layoutInflater.inflate(R.layout.dialog_action_sheet, null)
            fun selectAndClose(value: String) {
                chosen = true
                txtResult.text = "sheet=$value"
                dialog.dismiss()
            }
            content.findViewById<View>(R.id.action_sheet_camera).setOnClickListener { selectAndClose("camera") }
            content.findViewById<View>(R.id.action_sheet_library).setOnClickListener { selectAndClose("library") }
            content.findViewById<View>(R.id.action_sheet_cancel).setOnClickListener { selectAndClose("cancel") }
            dialog.setContentView(content)
            dialog.setOnDismissListener {
                if (!chosen) txtResult.text = "sheet=cancel"
            }
            dialog.show()
        }

        view.findViewById<View>(R.id.btn_fullscreen).setOnClickListener {
            FullScreenDialogFragment().show(childFragmentManager, "fullscreen")
        }

        view.findViewById<View>(R.id.btn_toast).setOnClickListener {
            Toast.makeText(requireContext(), "保存しました", Toast.LENGTH_SHORT).show()
            txtResult.text = "toast=shown"
        }
    }
}
