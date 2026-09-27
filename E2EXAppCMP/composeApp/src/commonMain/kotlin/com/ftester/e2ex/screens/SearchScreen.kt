package com.ftester.e2ex.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.SearchBar
import androidx.compose.material3.SearchBarDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.TaggedText

private val CANDIDATES = listOf(
    "apple" to Tags.SUGGESTION_APPLE,
    "apricot" to Tags.SUGGESTION_APRICOT,
    "banana" to Tags.SUGGESTION_BANANA,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchScreen() {
    var expanded by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var result by remember { mutableStateOf("none") }

    fun confirm(value: String) {
        result = value
        expanded = false
    }

    Box(modifier = Modifier.fillMaxSize()) {
        SearchBar(
            modifier = Modifier.align(Alignment.TopCenter),
            inputField = {
                SearchBarDefaults.InputField(
                    query = query,
                    onQueryChange = { query = it },
                    onSearch = { confirm(query) },
                    expanded = expanded,
                    onExpandedChange = { expanded = it },
                    placeholder = { Text("検索") },
                    modifier = Modifier.testTag(Tags.FIELD_SEARCH)
                )
            },
            expanded = expanded,
            onExpandedChange = { expanded = it }
        ) {
            Column(modifier = Modifier.fillMaxWidth()) {
                CANDIDATES.filter { (word, _) -> word.startsWith(query, ignoreCase = true) }
                    .forEach { (word, tag) ->
                        ListItem(
                            headlineContent = { Text(word) },
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag(tag)
                                .clickable { confirm(word) }
                        )
                    }
            }
        }
        TaggedText(
            Tags.SEARCH_RESULT,
            "search=$result",
            modifier = Modifier.align(Alignment.BottomStart).padding(16.dp)
        )
    }
}
