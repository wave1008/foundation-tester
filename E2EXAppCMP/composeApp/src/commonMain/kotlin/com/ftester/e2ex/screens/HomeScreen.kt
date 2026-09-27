package com.ftester.e2ex.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ListItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.navigation.NavHostController
import com.ftester.e2ex.Routes
import com.ftester.e2ex.Tags

private data class HomeRow(val tag: String, val label: String, val route: String)

private val HOME_ROWS = listOf(
    HomeRow(Tags.NAV_PAGER, "ページャ", Routes.PAGER),
    HomeRow(Tags.NAV_SHEET, "ボトムシート", Routes.SHEET),
    HomeRow(Tags.NAV_MENU, "メニュー", Routes.MENU),
    HomeRow(Tags.NAV_DATE, "日付ピッカー", Routes.DATE),
    HomeRow(Tags.NAV_DRAWER, "ドロワー", Routes.DRAWER),
    HomeRow(Tags.NAV_REFRESH, "引っ張って更新", Routes.REFRESH),
    HomeRow(Tags.NAV_SNACKBAR, "スナックバー", Routes.SNACKBAR),
    HomeRow(Tags.NAV_GRID, "グリッド", Routes.GRID),
    HomeRow(Tags.NAV_SWIPE, "スワイプで削除", Routes.SWIPE),
    HomeRow(Tags.NAV_TABS, "タブ", Routes.TABS),
    HomeRow(Tags.NAV_ANIM, "アニメーション", Routes.ANIM),
    HomeRow(Tags.NAV_TOOLTIP, "ツールチップ", Routes.TOOLTIP),
    HomeRow(Tags.NAV_CHIPS, "チップと分割ボタン", Routes.CHIPS),
    HomeRow(Tags.NAV_SEARCH, "検索バー", Routes.SEARCH),
    HomeRow(Tags.NAV_DETAIL, "引数付き遷移", Routes.ARG_NAV),
)

@Composable
fun HomeScreen(navController: NavHostController) {
    LazyColumn {
        items(HOME_ROWS) { row ->
            ListItem(
                headlineContent = { Text(row.label) },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(row.tag)
                    .clickable { navController.navigate(row.route) }
            )
        }
    }
}
