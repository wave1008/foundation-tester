package com.ftester.e2ex.android.fragments

import android.content.DialogInterface
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.core.os.bundleOf
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ex.android.DynamicIds
import com.ftester.e2ex.android.R
import com.ftester.e2ex.android.paddedName
import com.google.android.material.bottomsheet.BottomSheetDialogFragment

private const val REQUEST_KEY = "sheet_result"
private const val ROW_COUNT = 30

class SheetFragment : Fragment(R.layout.fragment_sheet) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_sheet_result)
        txtResult.text = "sheet=none"

        childFragmentManager.setFragmentResultListener(REQUEST_KEY, viewLifecycleOwner) { _, bundle ->
            txtResult.text = "sheet=" + bundle.getString("value")
        }

        view.findViewById<View>(R.id.btn_open_sheet).setOnClickListener {
            SheetDialogFragment().show(childFragmentManager, "sheet")
        }
    }
}

class SheetDialogFragment : BottomSheetDialogFragment() {

    private var selected = false

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View = inflater.inflate(R.layout.dialog_sheet_content, container, false)

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        fun selectAndClose(value: String) {
            selected = true
            parentFragmentManager.setFragmentResult(REQUEST_KEY, bundleOf("value" to value))
            dismiss()
        }

        view.findViewById<View>(R.id.btn_sheet_opt_1).setOnClickListener { selectAndClose("opt1") }
        view.findViewById<View>(R.id.btn_sheet_opt_2).setOnClickListener { selectAndClose("opt2") }
        view.findViewById<View>(R.id.btn_sheet_opt_3).setOnClickListener { selectAndClose("opt3") }

        val recycler = view.findViewById<RecyclerView>(R.id.recycler_sheet_rows)
        recycler.layoutManager = LinearLayoutManager(requireContext())
        recycler.adapter = object : RecyclerView.Adapter<RowHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RowHolder {
                val itemView = LayoutInflater.from(parent.context)
                    .inflate(R.layout.item_sheet_row, parent, false)
                return RowHolder(itemView)
            }

            override fun onBindViewHolder(holder: RowHolder, position: Int) {
                holder.itemView.id = DynamicIds.of(requireContext(), paddedName("row_sheet_", position))
                (holder.itemView as TextView).text = "シート行 " + position.toString().padStart(2, '0')
                holder.itemView.setOnClickListener {
                    selectAndClose(paddedName("row", position))
                }
            }

            override fun getItemCount() = ROW_COUNT
        }
    }

    override fun onDismiss(dialog: DialogInterface) {
        super.onDismiss(dialog)
        if (!selected) {
            parentFragmentManager.setFragmentResult(REQUEST_KEY, bundleOf("value" to "dismissed"))
        }
    }

    private class RowHolder(itemView: View) : RecyclerView.ViewHolder(itemView)
}
