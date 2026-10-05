package com.ftester.e2ey.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
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
import com.ftester.e2ey.ui.TaggedText

// A1: LazyColumn(縦)の中に LazyRow(横)。横の行は画面外のカードを木に持たない(仮想化)。
@Composable
fun NestedScreen() {
    var result by remember { mutableStateOf("none") }
    Column(modifier = Modifier.fillMaxSize()) {
        TaggedText("txt_nested_result", "nested=$result", Modifier.padding(16.dp, 8.dp))
        LazyColumn(modifier = Modifier.fillMaxWidth().weight(1f).testTag("list_nested")) {
            items(10) { i ->
                Column(modifier = Modifier.padding(vertical = 4.dp)) {
                    TaggedText("txt_shelf_$i", "棚 $i", Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                    LazyRow(
                        modifier = Modifier.fillMaxWidth().testTag("shelf_$i"),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        items(15) { j ->
                            val jj = j.toString().padStart(2, '0')
                            Box(
                                modifier = Modifier
                                    .width(140.dp).height(120.dp)
                                    .background(MaterialTheme.colorScheme.secondaryContainer)
                                    .testTag("card_${i}_$jj")
                                    .clickable { result = "card_${i}_$jj" },
                                contentAlignment = Alignment.Center
                            ) { Text("カード $i-$jj") }
                        }
                    }
                }
            }
        }
    }
}
