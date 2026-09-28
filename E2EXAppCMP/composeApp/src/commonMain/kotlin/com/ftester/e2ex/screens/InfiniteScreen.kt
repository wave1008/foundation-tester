package com.ftester.e2ex.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.ListItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.TaggedText
import kotlinx.coroutines.delay

@Composable
fun InfiniteScreen() {
    var loadedCount by remember { mutableStateOf(Tags.INFINITE_INITIAL_COUNT) }
    var isLoading by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf("none") }
    val listState = rememberLazyListState()

    LaunchedEffect(listState) {
        snapshotFlow { listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index }
            .collect { lastVisible ->
                if (lastVisible != null &&
                    !isLoading &&
                    loadedCount < Tags.INFINITE_MAX_COUNT &&
                    lastVisible >= loadedCount - 1 - Tags.INFINITE_PREFETCH_THRESHOLD
                ) {
                    isLoading = true
                    delay(Tags.INFINITE_LOAD_DELAY_MS)
                    loadedCount = (loadedCount + Tags.INFINITE_PAGE_SIZE).coerceAtMost(Tags.INFINITE_MAX_COUNT)
                    isLoading = false
                }
            }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        TaggedText(Tags.INFINITE_COUNT, "loaded=$loadedCount", modifier = Modifier.padding(16.dp))
        TaggedText(Tags.INFINITE_RESULT, "infinite=$result", modifier = Modifier.padding(start = 16.dp, bottom = 8.dp))
        LazyColumn(state = listState, modifier = Modifier.fillMaxSize().testTag(Tags.LIST_INFINITE)) {
            items(loadedCount) { n ->
                val rowTag = Tags.infiniteRow(n)
                ListItem(
                    headlineContent = { Text(Tags.infiniteRowLabel(n)) },
                    modifier = Modifier.fillMaxWidth().testTag(rowTag).clickable { result = rowTag }
                )
            }
            if (isLoading) {
                item {
                    Text(
                        "読み込み中",
                        modifier = Modifier.fillMaxWidth().padding(16.dp).testTag(Tags.TXT_LOADING)
                    )
                }
            }
        }
    }
}
