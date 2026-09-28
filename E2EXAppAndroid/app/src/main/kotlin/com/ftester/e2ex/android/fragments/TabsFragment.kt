package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.DynamicIds
import com.ftester.e2ex.android.R
import com.ftester.e2ex.android.paddedName
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.tabs.TabLayout

private val FIXED_TABS = listOf(R.id.tab_a to "タブA", R.id.tab_b to "タブB", R.id.tab_c to "タブC")
private const val SCROLLABLE_TAB_COUNT = 12

class TabsFragment : Fragment(R.layout.fragment_tabs) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val tabFixed = view.findViewById<TabLayout>(R.id.tab_layout_fixed)
        val txtTabContent = view.findViewById<TextView>(R.id.txt_tab_content)
        val stabRow = view.findViewById<TabLayout>(R.id.stab_row)
        val txtStabContent = view.findViewById<TextView>(R.id.txt_stab_content)
        val bottomNav = view.findViewById<BottomNavigationView>(R.id.bottom_nav)
        val txtNavbarResult = view.findViewById<TextView>(R.id.txt_navbar_result)

        txtTabContent.text = "content=A"
        txtStabContent.text = "scroll-tab=01"
        txtNavbarResult.text = "navbar=home"

        // TabLayout.Tab は view フィールドを公開しないため setCustomView で id 付きの
        // TextView を差し込む(docs/ui-contract.md の逸脱注記を参照。実機未検証)。
        FIXED_TABS.forEach { (idRes, label) ->
            val customView = layoutInflater.inflate(R.layout.item_tab_label, tabFixed, false) as TextView
            customView.id = idRes
            customView.text = label
            tabFixed.addTab(tabFixed.newTab().setCustomView(customView))
        }
        tabFixed.addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(tab: TabLayout.Tab) {
                txtTabContent.text = "content=" + ('A' + tab.position)
            }

            override fun onTabUnselected(tab: TabLayout.Tab) {}
            override fun onTabReselected(tab: TabLayout.Tab) {}
        })

        for (i in 1..SCROLLABLE_TAB_COUNT) {
            val customView = layoutInflater.inflate(R.layout.item_tab_label, stabRow, false) as TextView
            customView.id = DynamicIds.of(requireContext(), paddedName("stab_", i))
            customView.text = "項目タブ" + i.toString().padStart(2, '0')
            stabRow.addTab(stabRow.newTab().setCustomView(customView))
        }
        stabRow.addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(tab: TabLayout.Tab) {
                txtStabContent.text = "scroll-tab=" + (tab.position + 1).toString().padStart(2, '0')
            }

            override fun onTabUnselected(tab: TabLayout.Tab) {}
            override fun onTabReselected(tab: TabLayout.Tab) {}
        })

        bottomNav.setOnItemSelectedListener { item ->
            txtNavbarResult.text = "navbar=" + when (item.itemId) {
                R.id.navbar_home -> "home"
                R.id.navbar_search -> "search"
                R.id.navbar_settings -> "settings"
                else -> "home"
            }
            true
        }
    }
}
