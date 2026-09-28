package com.ftester.e2ex.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.ListItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.testTag
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.TaggedText

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CollapseScreen() {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    var result by remember { mutableStateOf("none") }

    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = { TaggedText(Tags.COLLAPSE_HEADER, "大きな見出し") },
                // ヘッダが縮んでも actions は常に木に残る(title 行だけが畳まれる。契約 §伸縮するヘッダ)。
                actions = { TaggedText(Tags.COLLAPSE_RESULT, "collapse=$result") },
                scrollBehavior = scrollBehavior
            )
        }
    ) { padding ->
        LazyColumn(modifier = Modifier.fillMaxSize(), contentPadding = padding) {
            items(Tags.COLLAPSE_ROW_COUNT) { n ->
                ListItem(
                    headlineContent = { Text(Tags.collapseRowLabel(n)) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(Tags.collapseRow(n))
                        .clickable { result = Tags.collapseRow(n) }
                )
            }
        }
    }
}
