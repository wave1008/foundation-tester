package com.ftester.e2ex.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.TaggedText

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SwipeScreen() {
    var rows by remember { mutableStateOf((1..Tags.SWIPE_ROW_COUNT).toList()) }
    var removed by remember { mutableStateOf("none") }

    androidx.compose.foundation.layout.Column(modifier = Modifier.fillMaxSize()) {
        TaggedText(Tags.SWIPE_RESULT, "removed=$removed", modifier = Modifier.padding(16.dp, 16.dp, 16.dp, 0.dp))
        TaggedText(Tags.SWIPE_COUNT, "rows=${rows.size}", modifier = Modifier.padding(16.dp, 4.dp, 16.dp, 8.dp))
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            items(rows, key = { it }) { n ->
                val dismissState = rememberSwipeToDismissBoxState(
                    confirmValueChange = { value ->
                        if (value == SwipeToDismissBoxValue.EndToStart) {
                            rows = rows - n
                            removed = n.toString()
                            true
                        } else {
                            false
                        }
                    }
                )
                SwipeToDismissBox(
                    state = dismissState,
                    enableDismissFromStartToEnd = false,
                    enableDismissFromEndToStart = true,
                    modifier = Modifier.fillMaxWidth().testTag(Tags.swipeRow(n)),
                    backgroundContent = {
                        Box(modifier = Modifier.fillMaxSize().background(Color.Red))
                    }
                ) {
                    ListItem(headlineContent = { Text(Tags.swipeRowLabel(n)) })
                }
            }
        }
    }
}
