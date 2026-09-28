package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.BaseExpandableListAdapter
import android.widget.ExpandableListView
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.DynamicIds
import com.ftester.e2ex.android.R

private data class Group(val idName: String, val label: String, val children: List<String>)

private val GROUPS = listOf(
    Group("group_fruit", "果物", listOf("りんご", "みかん", "ぶどう")),
    Group("group_veg", "野菜", listOf("にんじん", "たまねぎ", "キャベツ")),
    Group("group_drink", "飲み物", listOf("水", "お茶", "コーヒー")),
)

private val GROUP_KEYS = listOf("fruit", "veg", "drink")

class ExpandFragment : Fragment(R.layout.fragment_expand) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_expand_result)
        txtResult.text = "expand=none"

        val list = view.findViewById<ExpandableListView>(R.id.expandable_list)
        list.setAdapter(ExpandAdapter())
        list.setOnChildClickListener { _, _, groupPosition, childPosition, _ ->
            txtResult.text = "expand=item_${GROUP_KEYS[groupPosition]}_${childPosition + 1}"
            true
        }
    }

    private inner class ExpandAdapter : BaseExpandableListAdapter() {
        override fun getGroupCount() = GROUPS.size
        override fun getChildrenCount(groupPosition: Int) = GROUPS[groupPosition].children.size
        override fun getGroup(groupPosition: Int) = GROUPS[groupPosition]
        override fun getChild(groupPosition: Int, childPosition: Int) = GROUPS[groupPosition].children[childPosition]
        override fun getGroupId(groupPosition: Int) = groupPosition.toLong()
        override fun getChildId(groupPosition: Int, childPosition: Int) = childPosition.toLong()
        override fun hasStableIds() = true
        override fun isChildSelectable(groupPosition: Int, childPosition: Int) = true

        override fun getGroupView(
            groupPosition: Int, isExpanded: Boolean, convertView: View?, parent: ViewGroup?
        ): View {
            val itemView = convertView
                ?: LayoutInflater.from(requireContext()).inflate(R.layout.item_expand_group, parent, false)
            val group = GROUPS[groupPosition]
            itemView.id = DynamicIds.of(requireContext(), group.idName)
            (itemView as TextView).text = group.label
            return itemView
        }

        override fun getChildView(
            groupPosition: Int, childPosition: Int, isLastChild: Boolean, convertView: View?, parent: ViewGroup?
        ): View {
            val itemView = convertView
                ?: LayoutInflater.from(requireContext()).inflate(R.layout.item_expand_child, parent, false)
            val key = GROUP_KEYS[groupPosition]
            itemView.id = DynamicIds.of(requireContext(), "item_${key}_${childPosition + 1}")
            (itemView as TextView).text = GROUPS[groupPosition].children[childPosition]
            return itemView
        }
    }
}
