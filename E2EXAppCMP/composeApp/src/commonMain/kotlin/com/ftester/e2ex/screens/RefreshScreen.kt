package com.ftester.e2ex.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.TaggedText
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RefreshScreen() {
    var isRefreshing by remember { mutableStateOf(false) }
    var refreshCount by remember { mutableStateOf(0) }
    val scope = rememberCoroutineScope()

    Column(modifier = Modifier.fillMaxSize()) {
        TaggedText(Tags.REFRESH_COUNT, "refresh=$refreshCount", modifier = Modifier.padding(16.dp))
        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                isRefreshing = true
                scope.launch {
                    delay(1000)
                    isRefreshing = false
                    refreshCount++
                }
            },
            modifier = Modifier.weight(1f).fillMaxWidth().testTag(Tags.BOX_REFRESH)
        ) {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(Tags.REFRESH_ROW_COUNT) { n ->
                    ListItem(
                        headlineContent = { Text(Tags.refreshRowLabel(n)) },
                        modifier = Modifier.fillMaxWidth().testTag(Tags.refreshRow(n))
                    )
                }
            }
        }
    }
}
