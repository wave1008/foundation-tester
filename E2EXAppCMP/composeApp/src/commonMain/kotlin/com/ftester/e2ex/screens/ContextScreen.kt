package com.ftester.e2ex.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ListItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedText
import com.ftester.e2ex.util.exposeTestTagsAsResourceId

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ContextScreen() {
    var result by remember { mutableStateOf("none") }
    var expandedRow by remember { mutableStateOf<Int?>(null) }

    ScreenColumn(scrollable = true) {
        TaggedText(Tags.CONTEXT_RESULT, "context=$result")
        for (n in 1..Tags.CTX_ROW_COUNT) {
            // DropdownMenu は行と同じ Box に置く(置かないと親 Column に揃って画面下に出る)。
            Box {
                ListItem(
                    headlineContent = { Text(Tags.ctxRowLabel(n)) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(Tags.ctxRow(n))
                        .combinedClickable(onClick = {}, onLongClick = { expandedRow = n })
                )
                DropdownMenu(
                    expanded = expandedRow == n,
                    onDismissRequest = { expandedRow = null },
                    modifier = Modifier.exposeTestTagsAsResourceId()
                ) {
                    DropdownMenuItem(
                        text = { Text("編集") },
                        onClick = { result = "row$n:edit"; expandedRow = null },
                        modifier = Modifier.testTag(Tags.CTX_ITEM_EDIT)
                    )
                    DropdownMenuItem(
                        text = { Text("複製") },
                        onClick = { result = "row$n:copy"; expandedRow = null },
                        modifier = Modifier.testTag(Tags.CTX_ITEM_COPY)
                    )
                    DropdownMenuItem(
                        text = { Text("削除") },
                        onClick = { result = "row$n:delete"; expandedRow = null },
                        modifier = Modifier.testTag(Tags.CTX_ITEM_DELETE)
                    )
                }
            }
        }
    }
}
