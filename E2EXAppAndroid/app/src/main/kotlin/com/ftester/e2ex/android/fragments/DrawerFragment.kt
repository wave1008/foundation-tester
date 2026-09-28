package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.core.view.GravityCompat
import androidx.drawerlayout.widget.DrawerLayout
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.R
import com.google.android.material.navigation.NavigationView

class DrawerFragment : Fragment(R.layout.fragment_drawer) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val drawerLayout = view.findViewById<DrawerLayout>(R.id.drawer_layout)
        val navView = view.findViewById<NavigationView>(R.id.nav_view_drawer)
        val txtResult = view.findViewById<TextView>(R.id.txt_drawer_result)
        val txtState = view.findViewById<TextView>(R.id.txt_drawer_state)

        txtResult.text = "drawer=none"
        txtState.text = "drawerOpen=false"

        view.findViewById<View>(R.id.btn_open_drawer).setOnClickListener {
            drawerLayout.openDrawer(GravityCompat.START)
        }

        navView.setNavigationItemSelectedListener { item ->
            txtResult.text = "drawer=" + when (item.itemId) {
                R.id.drawer_item_inbox -> "inbox"
                R.id.drawer_item_sent -> "sent"
                R.id.drawer_item_trash -> "trash"
                else -> "none"
            }
            drawerLayout.closeDrawer(GravityCompat.START)
            true
        }

        // アニメーション完了後の値だけを反映する(契約 §ドロワー)。
        drawerLayout.addDrawerListener(object : DrawerLayout.SimpleDrawerListener() {
            override fun onDrawerOpened(drawerView: View) {
                txtState.text = "drawerOpen=true"
            }

            override fun onDrawerClosed(drawerView: View) {
                txtState.text = "drawerOpen=false"
            }
        })
    }
}
