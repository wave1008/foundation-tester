package com.ftester.e2ey.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Tab
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.ftester.e2ey.ui.TaggedButton
import com.ftester.e2ey.ui.TaggedText
import kotlinx.coroutines.launch

private fun pad2(n: Int) = n.toString().padStart(2, '0')

private val TABS = listOf(Triple("posts", "投稿", "post"), Triple("media", "メディア", "media"), Triple("likes", "いいね", "like"))
private val TAB_LABELS = mapOf("post" to "投稿", "media" to "メディア", "like" to "いいね")

// A11: 縮むヘッダ(nestedScroll)+ 貼り付くタブ(TabRow)+ HorizontalPager の縦の一覧。
// 縦に送ると先にヘッダが縮み、縮み切ってから一覧が動く(戻すときは一覧が先頭に着いてからヘッダが戻る)。
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TabHeaderScreen() {
    val density = LocalDensity.current
    val headerMax = with(density) { 200.dp.toPx() }
    var collapsed by remember { mutableStateOf(0f) }
    var result by remember { mutableStateOf("none") }
    val pagerState = rememberPagerState { 3 }
    val scope = rememberCoroutineScope()

    val connection = remember {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (available.y < 0f && collapsed < headerMax) {
                    val next = (collapsed - available.y).coerceAtMost(headerMax)
                    val used = next - collapsed
                    collapsed = next
                    return Offset(0f, -used)
                }
                return Offset.Zero
            }

            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (available.y > 0f && collapsed > 0f) {
                    val next = (collapsed - available.y).coerceAtLeast(0f)
                    val used = collapsed - next
                    collapsed = next
                    return Offset(0f, used)
                }
                return Offset.Zero
            }
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Column(modifier = Modifier.fillMaxWidth().padding(16.dp, 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            TaggedText("txt_tabhdr_result", "tabhdr=$result")
            TaggedText("txt_tabhdr_tab", "tab=${TABS[pagerState.currentPage].first}")
            TaggedText("txt_tabhdr_header", if (collapsed >= headerMax) "header=collapsed" else "header=expanded")
        }
        Column(modifier = Modifier.weight(1f).fillMaxWidth().nestedScroll(connection)) {
            Box(
                modifier = Modifier.fillMaxWidth().clipToBounds()
                    .layout { measurable, constraints ->
                        val p = measurable.measure(constraints)
                        val h = (p.height - collapsed).toInt().coerceAtLeast(0)
                        layout(p.width, h) { p.place(0, -collapsed.toInt()) }
                    }
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth().height(200.dp).background(MaterialTheme.colorScheme.primaryContainer).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    TaggedText("txt_profile_header", "プロフィール見出し")
                    TaggedButton("btn_follow", "フォロー") { result = "follow" }
                }
            }
            PrimaryTabRow(selectedTabIndex = pagerState.currentPage) {
                TABS.forEachIndexed { i, (key, label, _) ->
                    Tab(
                        selected = pagerState.currentPage == i,
                        onClick = { scope.launch { pagerState.animateScrollToPage(i) } },
                        modifier = Modifier.testTag("tab_$key"),
                        text = { Text(label) }
                    )
                }
            }
            HorizontalPager(state = pagerState, modifier = Modifier.weight(1f).fillMaxWidth()) { page ->
                val (_, _, prefix) = TABS[page]
                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(40) { n ->
                        Box(
                            modifier = Modifier.fillMaxWidth().height(56.dp)
                                .testTag("${prefix}_${pad2(n)}")
                                .clickable { result = "${prefix}_${pad2(n)}" }
                                .padding(horizontal = 16.dp),
                            contentAlignment = Alignment.CenterStart
                        ) { Text("${TAB_LABELS[prefix]} ${pad2(n)}") }
                    }
                }
            }
        }
    }
}
