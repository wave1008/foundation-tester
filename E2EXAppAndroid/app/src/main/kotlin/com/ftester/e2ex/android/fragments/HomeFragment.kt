package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.navigation.findNavController
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ex.android.R

private data class HomeRow(val idRes: Int, val label: String, val destId: Int)

// 契約(E2EXAppCMP/docs/ui-contract.md §ホーム)の表と同じ順・同じラベル・同じ nav_* 名。
private val HOME_ROWS = listOf(
    HomeRow(R.id.nav_pager, "ページャ", R.id.pagerFragment),
    HomeRow(R.id.nav_sheet, "ボトムシート", R.id.sheetFragment),
    HomeRow(R.id.nav_menu, "メニュー", R.id.menuFragment),
    HomeRow(R.id.nav_date, "日付ピッカー", R.id.dateFragment),
    HomeRow(R.id.nav_drawer, "ドロワー", R.id.drawerFragment),
    HomeRow(R.id.nav_refresh, "引っ張って更新", R.id.refreshFragment),
    HomeRow(R.id.nav_snackbar, "スナックバー", R.id.snackbarFragment),
    HomeRow(R.id.nav_grid, "グリッド", R.id.gridFragment),
    HomeRow(R.id.nav_swipe, "スワイプで削除", R.id.swipeFragment),
    HomeRow(R.id.nav_tabs, "タブ", R.id.tabsFragment),
    HomeRow(R.id.nav_anim, "アニメーション", R.id.animFragment),
    HomeRow(R.id.nav_tooltip, "ツールチップ", R.id.tooltipFragment),
    HomeRow(R.id.nav_chips, "チップと分割ボタン", R.id.chipsFragment),
    HomeRow(R.id.nav_search, "検索バー", R.id.searchFragment),
    HomeRow(R.id.nav_detail, "引数付き遷移", R.id.argNavFragment),
    // 第2弾(E2EXAppCMP/docs/ui-contract-wave2.md)。
    HomeRow(R.id.nav_collapse, "伸縮するヘッダ", R.id.collapseFragment),
    HomeRow(R.id.nav_sticky, "貼り付く見出し", R.id.stickyFragment),
    HomeRow(R.id.nav_time, "時刻ピッカー", R.id.timeFragment),
    HomeRow(R.id.nav_dialogs, "ダイアログ", R.id.dialogsFragment),
    HomeRow(R.id.nav_context, "長押しメニュー", R.id.contextFragment),
    HomeRow(R.id.nav_reorder, "並べ替え", R.id.reorderFragment),
    HomeRow(R.id.nav_inputs, "入力の種類", R.id.inputsFragment),
    HomeRow(R.id.nav_fab, "FAB", R.id.fabFragment),
    HomeRow(R.id.nav_expand, "展開するリスト", R.id.expandFragment),
    HomeRow(R.id.nav_stepper, "ステッパーと進捗", R.id.stepperFragment),
    HomeRow(R.id.nav_infinite, "無限スクロール", R.id.infiniteFragment),
    HomeRow(R.id.nav_zoom, "ピンチで拡大", R.id.zoomFragment),
    HomeRow(R.id.nav_native, "固有部品", R.id.nativeFragment),
)

class HomeFragment : Fragment(R.layout.fragment_home) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val recycler = view.findViewById<RecyclerView>(R.id.recycler_home)
        recycler.layoutManager = LinearLayoutManager(requireContext())
        recycler.adapter = HomeAdapter()
    }

    private inner class HomeAdapter : RecyclerView.Adapter<HomeAdapter.Holder>() {
        inner class Holder(itemView: View) : RecyclerView.ViewHolder(itemView)

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Holder {
            val itemView = LayoutInflater.from(parent.context)
                .inflate(R.layout.item_home_row, parent, false)
            return Holder(itemView)
        }

        override fun onBindViewHolder(holder: Holder, position: Int) {
            val row = HOME_ROWS[position]
            // Compose の testTag と違い View は実行時に resource-id を生成できないため、
            // ids.xml に静的宣言した id を割り当てる(E2EAppAndroid/docs/ui-contract.md §1)。
            holder.itemView.id = row.idRes
            (holder.itemView as TextView).text = row.label
            holder.itemView.setOnClickListener {
                holder.itemView.findNavController().navigate(row.destId)
            }
        }

        override fun getItemCount() = HOME_ROWS.size
    }
}
