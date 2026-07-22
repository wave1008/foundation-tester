package com.ftester.e2e.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.TaggedButton
import com.ftester.e2e.ui.TaggedText
import kotlinx.coroutines.launch

@Composable
fun ScrollScreen() {
    var selected by remember { mutableStateOf("-") }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()

    // ScreenColumn は使わず自前で組む: LazyColumn を weight で残り高さいっぱいに伸ばすため。
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        TaggedText(Tags.TXT_ROW_SELECTED, "selected=$selected")
        TaggedButton(Tags.BTN_SCROLL_TOP, "先頭へ") {
            scope.launch { listState.animateScrollToItem(0) }
        }
        LazyColumn(state = listState, modifier = Modifier.weight(1f)) {
            items(Tags.ROW_COUNT) { index ->
                val n = index + 1
                // 56dp 未満だと Compose iOS の高密度スクロールで frame がクランプされ tap が外れる(契約 §全体規約)。
                TaggedButton(
                    tag = Tags.row(n),
                    label = Tags.rowLabel(n),
                    modifier = Modifier.fillMaxWidth().height(56.dp)
                ) {
                    selected = Tags.row(n)
                }
            }
        }
    }
}
