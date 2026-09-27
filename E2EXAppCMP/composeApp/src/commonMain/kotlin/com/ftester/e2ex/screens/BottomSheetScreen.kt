package com.ftester.e2ex.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
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
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedButton
import com.ftester.e2ex.ui.TaggedText
import com.ftester.e2ex.util.exposeTestTagsAsResourceId
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BottomSheetScreen() {
    var showSheet by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf("none") }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    val scope = rememberCoroutineScope()

    fun selectAndClose(value: String) {
        result = value
        scope.launch { sheetState.hide() }.invokeOnCompletion {
            if (!sheetState.isVisible) showSheet = false
        }
    }

    ScreenColumn(scrollable = true) {
        TaggedText(Tags.SHEET_RESULT, "sheet=$result")
        TaggedButton(Tags.BTN_OPEN_SHEET, "シートを開く") { showSheet = true }
    }

    if (showSheet) {
        ModalBottomSheet(
            onDismissRequest = {
                result = "dismissed"
                showSheet = false
            },
            sheetState = sheetState,
            // 別ウィンドウなのでルートの exposeTestTagsAsResourceId が効かない(契約 §全体規約)。
            modifier = Modifier.exposeTestTagsAsResourceId()
        ) {
            Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
                TaggedText(Tags.SHEET_TITLE, "シートの見出し")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (n in 1..3) {
                        TaggedButton(Tags.sheetOpt(n), Tags.sheetOptLabel(n)) {
                            selectAndClose("opt$n")
                        }
                    }
                }
                LazyColumn(modifier = Modifier.fillMaxWidth().height(320.dp)) {
                    items(Tags.SHEET_ROW_COUNT) { n ->
                        ListItem(
                            headlineContent = { Text(Tags.sheetRowLabel(n)) },
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag(Tags.sheetRow(n))
                                .clickable { selectAndClose("row" + n.toString().padStart(2, '0')) }
                        )
                    }
                }
            }
        }
    }
}
