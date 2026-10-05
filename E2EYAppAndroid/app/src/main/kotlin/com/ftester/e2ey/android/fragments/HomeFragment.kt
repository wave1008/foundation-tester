package com.ftester.e2ey.android.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.navigation.findNavController
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ey.android.R

private data class HomeRow(val idRes: Int, val label: String, val destId: Int)

// E2EYAppCMP/docs/ui-contract.md §ホーム の表と同じ順・ラベル・nav_* 名。
private val HOME_ROWS = listOf(
    HomeRow(R.id.nav_nested, "入れ子スクロール", R.id.nestedFragment),
    HomeRow(R.id.nav_chat, "反転チャット", R.id.chatFragment),
    HomeRow(R.id.nav_loading, "読み込みの状態", R.id.loadingFragment),
    HomeRow(R.id.nav_swipe_actions, "スワイプの操作", R.id.swipeActionsFragment),
    HomeRow(R.id.nav_select, "選択モード", R.id.selectFragment),
    HomeRow(R.id.nav_links, "文中リンク", R.id.linksFragment),
    HomeRow(R.id.nav_pin, "PIN と OTP", R.id.pinFragment),
    HomeRow(R.id.nav_back_guard, "戻るの横取り", R.id.backGuardFragment),
    HomeRow(R.id.nav_player, "引き伸ばせるシート", R.id.playerFragment),
    HomeRow(R.id.nav_hide_bars, "スクロールで隠れるバー", R.id.hideBarsFragment),
    HomeRow(R.id.nav_tab_header, "折りたたみヘッダとタブ", R.id.tabHeaderFragment),
    HomeRow(R.id.nav_staggered, "高さの揃わないグリッド", R.id.staggeredFragment),
)

class TextHolder(val text: TextView) : RecyclerView.ViewHolder(text)

fun inflateRow(parent: ViewGroup): TextHolder =
    TextHolder(LayoutInflater.from(parent.context).inflate(R.layout.item_row, parent, false) as TextView)

class HomeFragment : Fragment(R.layout.fragment_home) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val recycler = view.findViewById<RecyclerView>(R.id.recycler_home)
        recycler.layoutManager = LinearLayoutManager(requireContext())
        recycler.adapter = object : RecyclerView.Adapter<TextHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = inflateRow(parent)

            override fun onBindViewHolder(holder: TextHolder, position: Int) {
                val row = HOME_ROWS[position]
                holder.text.id = row.idRes
                holder.text.text = row.label
                holder.text.setOnClickListener { it.findNavController().navigate(row.destId) }
            }

            override fun getItemCount() = HOME_ROWS.size
        }
    }
}
