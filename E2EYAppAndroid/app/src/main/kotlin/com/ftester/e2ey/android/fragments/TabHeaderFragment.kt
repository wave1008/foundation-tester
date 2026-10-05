package com.ftester.e2ey.android.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.viewpager2.widget.ViewPager2
import com.ftester.e2ey.android.DynamicIds
import com.ftester.e2ey.android.R
import com.google.android.material.appbar.AppBarLayout
import com.google.android.material.tabs.TabLayout
import com.google.android.material.tabs.TabLayoutMediator

private val TAB_KEYS = listOf("posts", "media", "likes")
private val TAB_LABELS = listOf("投稿", "メディア", "いいね")
private val ROW_PREFIX = listOf("post", "media", "like")
private val ROW_LABEL = listOf("投稿", "メディア", "いいね")

// A11: CoordinatorLayout + AppBarLayout(縮むヘッダ + TabLayout)+ ViewPager2(ページごとに縦の RecyclerView)。
class TabHeaderFragment : Fragment(R.layout.fragment_tab_header) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_tabhdr_result)
        val txtTab = view.findViewById<TextView>(R.id.txt_tabhdr_tab)
        val txtHeader = view.findViewById<TextView>(R.id.txt_tabhdr_header)
        txtResult.text = "tabhdr=none"
        txtTab.text = "tab=posts"
        txtHeader.text = "header=expanded"

        view.findViewById<View>(R.id.btn_follow).setOnClickListener { txtResult.text = "tabhdr=follow" }

        val appBar = view.findViewById<AppBarLayout>(R.id.appbar_tabhdr)
        appBar.addOnOffsetChangedListener { bar, offset ->
            val collapsed = bar.totalScrollRange > 0 && -offset >= bar.totalScrollRange
            txtHeader.text = if (collapsed) "header=collapsed" else "header=expanded"
        }

        val pager = view.findViewById<ViewPager2>(R.id.pager_profile)
        // 3 ページとも保持する(タブごとの一覧の位置が残る)。
        pager.offscreenPageLimit = 2
        pager.adapter = object : RecyclerView.Adapter<PageHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): PageHolder {
                val list = LayoutInflater.from(parent.context).inflate(R.layout.page_list, parent, false) as RecyclerView
                list.layoutManager = LinearLayoutManager(parent.context)
                return PageHolder(list)
            }

            override fun onBindViewHolder(holder: PageHolder, position: Int) {
                holder.list.adapter = RowAdapter(position, txtResult)
            }

            override fun getItemCount() = 3
        }

        val tabs = view.findViewById<TabLayout>(R.id.tabs_profile)
        TabLayoutMediator(tabs, pager) { tab, pos -> tab.text = TAB_LABELS[pos] }.attach()
        val tabIds = intArrayOf(R.id.tab_posts, R.id.tab_media, R.id.tab_likes)
        for (i in 0 until 3) tabs.getTabAt(i)?.view?.id = tabIds[i]
        tabs.addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(tab: TabLayout.Tab) {
                txtTab.text = "tab=${TAB_KEYS[tab.position]}"
            }

            override fun onTabUnselected(tab: TabLayout.Tab) = Unit
            override fun onTabReselected(tab: TabLayout.Tab) = Unit
        })
    }

    private class PageHolder(val list: RecyclerView) : RecyclerView.ViewHolder(list)

    private class RowAdapter(private val page: Int, private val txtResult: TextView) :
        RecyclerView.Adapter<TextHolder>() {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = inflateRow(parent)

        override fun onBindViewHolder(holder: TextHolder, position: Int) {
            val nn = position.toString().padStart(2, '0')
            val prefix = ROW_PREFIX[page]
            holder.text.id = DynamicIds.of(holder.text.context, "${prefix}_$nn")
            holder.text.text = "${ROW_LABEL[page]} $nn"
            holder.text.setOnClickListener { txtResult.text = "tabhdr=${prefix}_$nn" }
        }

        override fun getItemCount() = 40
    }
}
