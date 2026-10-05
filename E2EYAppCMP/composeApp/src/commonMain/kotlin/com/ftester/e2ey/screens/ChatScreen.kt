package com.ftester.e2ey.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.ftester.e2ey.ui.TaggedButton
import com.ftester.e2ey.ui.TaggedText
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private data class Msg(val id: Int, val text: String)

private fun pad2(n: Int) = n.toString().padStart(2, '0')

// A2: LazyColumn(reverseLayout = true)。index 0 = 最新(画面の下端)なので木の順と見た目の上下が逆。
@Composable
fun ChatScreen() {
    var messages by remember { mutableStateOf((0..59).map { Msg(it, "メッセージ ${pad2(it)}") }) }
    var result by remember { mutableStateOf("none") }
    var draft by remember { mutableStateOf("") }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    var atBottomEcho by remember { mutableStateOf(true) }

    // echo は「止まった時点」の値(スクロール中は更新しない)。
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { scrolling ->
            if (!scrolling) atBottomEcho = listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset == 0
        }
    }

    fun nextId() = (messages.maxOfOrNull { it.id } ?: -1) + 1

    Column(modifier = Modifier.fillMaxSize().imePadding()) {
        Column(modifier = Modifier.fillMaxWidth().padding(16.dp, 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            TaggedText("txt_chat_result", "chat=$result")
            TaggedText("txt_chat_count", "count=${messages.size}")
            TaggedText("txt_chat_pos", "at_bottom=$atBottomEcho")
            TaggedButton("btn_incoming", "着信") {
                scope.launch {
                    delay(1000)
                    val wasBottom = listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset == 0
                    val id = nextId()
                    messages = messages + Msg(id, "着信 ${pad2(id)}")
                    if (wasBottom) listState.animateScrollToItem(0)
                }
            }
        }
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(
                state = listState,
                reverseLayout = true,
                modifier = Modifier.fillMaxSize().testTag("list_chat")
            ) {
                items(messages.asReversed(), key = { it.id }) { m ->
                    Box(
                        modifier = Modifier.fillMaxWidth().height(56.dp)
                            .testTag("msg_${pad2(m.id)}")
                            .clickable { result = "msg_${pad2(m.id)}" }
                            .padding(horizontal = 16.dp),
                        contentAlignment = Alignment.CenterStart
                    ) { Text(m.text) }
                }
            }
            if (!atBottomEcho) {
                TaggedButton("btn_jump_bottom", "最新へ", Modifier.align(Alignment.BottomEnd).padding(16.dp)) {
                    scope.launch { listState.animateScrollToItem(0) }
                }
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OutlinedTextField(
                value = draft,
                onValueChange = { draft = it },
                placeholder = { Text("メッセージを入力") },
                modifier = Modifier.weight(1f).testTag("field_chat"),
                singleLine = true
            )
            TaggedButton("btn_send", "送信") {
                if (draft.isNotEmpty()) {
                    messages = messages + Msg(nextId(), draft)
                    draft = ""
                    scope.launch { listState.animateScrollToItem(0) }
                }
            }
        }
    }
}
