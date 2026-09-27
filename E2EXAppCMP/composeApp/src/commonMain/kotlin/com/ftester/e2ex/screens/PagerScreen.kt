package com.ftester.e2ex.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedButton
import com.ftester.e2ex.ui.TaggedText
import kotlinx.coroutines.launch

@Composable
fun PagerScreen() {
    val pagerState = rememberPagerState(pageCount = { Tags.PAGE_COUNT })
    val scope = rememberCoroutineScope()
    var result by remember { mutableStateOf("none") }

    ScreenColumn(scrollable = true) {
        HorizontalPager(
            state = pagerState,
            modifier = Modifier.fillMaxWidth().height(240.dp).testTag(Tags.PAGER_MAIN)
        ) { page ->
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                ScreenColumn(scrollable = false) {
                    TaggedText(Tags.page(page), Tags.pageLabel(page))
                    TaggedButton(Tags.pageButton(page), Tags.pageButtonLabel(page)) {
                        result = "tapped $page"
                    }
                }
            }
        }
        TaggedText(Tags.PAGER_STATE, "page=${pagerState.settledPage}")
        TaggedText(Tags.PAGER_RESULT, "pager=$result")
        TaggedButton(Tags.PAGER_NEXT, "次のページ") {
            val next = pagerState.currentPage + 1
            if (next < Tags.PAGE_COUNT) {
                scope.launch { pagerState.animateScrollToPage(next) }
            }
        }
    }
}
