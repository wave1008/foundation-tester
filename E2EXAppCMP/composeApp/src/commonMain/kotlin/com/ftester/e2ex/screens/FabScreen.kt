package com.ftester.e2ex.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.BottomAppBar
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.TaggedText

@Composable
fun FabScreen() {
    var result by remember { mutableStateOf("none") }

    Scaffold(
        floatingActionButton = {
            Column(horizontalAlignment = Alignment.End) {
                ExtendedFloatingActionButton(
                    onClick = { result = "extended" },
                    modifier = Modifier.testTag(Tags.FAB_EXTENDED)
                ) { Text("新規作成") }
                Spacer(modifier = Modifier.height(8.dp))
                FloatingActionButton(
                    onClick = { result = "add" },
                    modifier = Modifier.testTag(Tags.FAB_ADD)
                ) {
                    Text("+", modifier = Modifier.clearAndSetSemantics { contentDescription = "追加" })
                }
            }
        },
        bottomBar = {
            BottomAppBar {
                IconButton(onClick = { result = "search" }, modifier = Modifier.testTag(Tags.BAR_ACTION_SEARCH)) {
                    Text("⌕", modifier = Modifier.clearAndSetSemantics { contentDescription = "検索" })
                }
                IconButton(onClick = { result = "share" }, modifier = Modifier.testTag(Tags.BAR_ACTION_SHARE)) {
                    Text("↗", modifier = Modifier.clearAndSetSemantics { contentDescription = "共有" })
                }
            }
        }
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize()) {
            TaggedText(Tags.FAB_RESULT, "fab=$result", modifier = Modifier.padding(16.dp))
            LazyColumn(modifier = Modifier.fillMaxSize(), contentPadding = padding) {
                items(Tags.FAB_ROW_COUNT) { n ->
                    ListItem(
                        headlineContent = { Text(Tags.fabRowLabel(n)) },
                        modifier = Modifier.fillMaxWidth().testTag(Tags.fabRow(n))
                    )
                }
            }
        }
    }
}
