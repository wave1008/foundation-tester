package com.ftester.e2ex.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ListItem
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.TaggedText

@Composable
fun StickyScreen() {
    var result by remember { mutableStateOf("none") }

    Column(modifier = Modifier.fillMaxSize()) {
        // リストの上に固定(契約 §貼り付く見出し)。
        TaggedText(Tags.STICKY_RESULT, "sticky=$result", modifier = Modifier.padding(16.dp))
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            Tags.STICKY_SECTIONS.forEach { section ->
                stickyHeader {
                    Surface(tonalElevation = 2.dp) {
                        Text(
                            Tags.stickyHeaderLabel(section),
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag(Tags.stickyHeader(section))
                                .padding(12.dp)
                        )
                    }
                }
                items(Tags.STICKY_ROWS_PER_SECTION) { n ->
                    ListItem(
                        headlineContent = { Text(Tags.stickyRowLabel(section, n)) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(Tags.stickyRow(section, n))
                            .clickable { result = Tags.stickyRow(section, n) }
                    )
                }
            }
        }
    }
}
