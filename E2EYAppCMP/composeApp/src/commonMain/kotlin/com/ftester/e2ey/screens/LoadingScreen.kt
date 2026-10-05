package com.ftester.e2ey.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.ftester.e2ey.ui.TaggedButton
import com.ftester.e2ey.ui.TaggedText
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private fun pad2(n: Int) = n.toString().padStart(2, '0')

// A3: 骨組みの行は本物と同じ #id・ラベルで enabled=false。末尾の読み込み(1回目は必ず失敗)は固定秒。
@Composable
fun LoadingScreen() {
    var state by remember { mutableStateOf("loading") }
    var count by remember { mutableStateOf(0) }
    var result by remember { mutableStateOf("none") }
    var footerLoading by remember { mutableStateOf(false) }
    var failedOnce by remember { mutableStateOf(false) }
    var reloadKey by remember { mutableStateOf(0) }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    var job by remember { mutableStateOf<Job?>(null) }

    LaunchedEffect(reloadKey) {
        state = "loading"; count = 0; footerLoading = false; failedOnce = false
        delay(2000)
        count = 30; state = "loaded"
    }

    val atEnd = listState.layoutInfo.let { info ->
        info.totalItemsCount > 0 && info.visibleItemsInfo.lastOrNull()?.index == info.totalItemsCount - 1
    }
    LaunchedEffect(atEnd, state, count) {
        if (!atEnd || state != "loaded" || count == 0) return@LaunchedEffect
        if (count >= 50) { state = "end"; return@LaunchedEffect }
        job = scope.launch {
            state = "loading"; footerLoading = true
            delay(1000)
            footerLoading = false
            if (!failedOnce) { failedOnce = true; state = "error" } else { count = 50; state = "loaded" }
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Column(modifier = Modifier.fillMaxWidth().padding(16.dp, 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            TaggedText("txt_loading_state", "state=$state")
            TaggedText("txt_loading_count", "loaded=$count")
            TaggedText("txt_loading_result", "loading=$result")
            TaggedButton("btn_reload", "読み込み直す") {
                job?.cancel(); result = "none"; reloadKey++
            }
        }
        LazyColumn(state = listState, modifier = Modifier.weight(1f).fillMaxWidth().testTag("list_loading")) {
            if (count == 0) {
                items(8) { n ->
                    Box(
                        modifier = Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 16.dp, vertical = 6.dp)
                            .background(Color(0xFFE0E0E0))
                            .testTag("row_l_${pad2(n)}")
                            .clickable(enabled = false) { },
                        contentAlignment = Alignment.CenterStart
                    ) { Text("記事 ${pad2(n)}", color = Color(0xFFBDBDBD), modifier = Modifier.padding(start = 8.dp)) }
                }
            } else {
                items(count) { n ->
                    Box(
                        modifier = Modifier.fillMaxWidth().height(56.dp)
                            .testTag("row_l_${pad2(n)}")
                            .clickable { result = "row_l_${pad2(n)}" }
                            .padding(horizontal = 16.dp),
                        contentAlignment = Alignment.CenterStart
                    ) { Text("記事 ${pad2(n)}") }
                }
                if (footerLoading) item {
                    Box(Modifier.fillMaxWidth().height(56.dp), contentAlignment = Alignment.Center) {
                        TaggedText("txt_footer_loading", "読み込み中")
                    }
                }
                if (state == "error") item {
                    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        TaggedText("txt_footer_error", "読み込みに失敗しました")
                        TaggedButton("btn_retry", "再試行") {
                            job = scope.launch {
                                state = "loading"; footerLoading = true
                                delay(1000)
                                footerLoading = false; count = 50; state = "loaded"
                            }
                        }
                    }
                }
                if (state == "end") item {
                    Box(Modifier.fillMaxWidth().height(56.dp), contentAlignment = Alignment.Center) {
                        TaggedText("txt_footer_end", "これ以上ありません")
                    }
                }
            }
        }
    }
}
