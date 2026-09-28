package com.ftester.e2ex.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ListItem
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
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedText

private data class ExpandGroup(val tag: String, val label: String, val groupKey: String, val items: List<String>)

private val GROUPS = listOf(
    ExpandGroup(Tags.GROUP_FRUIT, "果物", "fruit", Tags.FRUIT_ITEMS),
    ExpandGroup(Tags.GROUP_VEG, "野菜", "veg", Tags.VEG_ITEMS),
    ExpandGroup(Tags.GROUP_DRINK, "飲み物", "drink", Tags.DRINK_ITEMS),
)

@Composable
fun ExpandScreen() {
    var result by remember { mutableStateOf("none") }
    val expanded = remember { mutableStateOf(setOf<String>()) }

    ScreenColumn(scrollable = true) {
        TaggedText(Tags.EXPAND_RESULT, "expand=$result")
        GROUPS.forEach { group ->
            val isOpen = group.groupKey in expanded.value
            ListItem(
                headlineContent = { Text(group.label) },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(group.tag)
                    .clickable {
                        expanded.value = if (isOpen) expanded.value - group.groupKey else expanded.value + group.groupKey
                    }
            )
            AnimatedVisibility(visible = isOpen) {
                Column {
                    group.items.forEachIndexed { index, label ->
                        val n = index + 1
                        val itemTag = Tags.expandItem(group.groupKey, n)
                        ListItem(
                            headlineContent = { Text(label) },
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(start = 16.dp)
                                .testTag(itemTag)
                                .clickable { result = itemTag }
                        )
                    }
                }
            }
        }
    }
}
