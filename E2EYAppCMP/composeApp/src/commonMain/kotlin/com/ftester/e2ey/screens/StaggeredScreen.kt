package com.ftester.e2ey.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.items
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

private fun pad2(n: Int) = n.toString().padStart(2, '0')

// A12: LazyVerticalStaggeredGrid(2 列)。タイル i の高さ = 80 + ((i*37)%5)*30 dp。
@Composable
fun StaggeredScreen() {
    var result by remember { mutableStateOf("none") }
    Column(modifier = Modifier.fillMaxSize()) {
        TaggedText("txt_staggered_result", "stag=$result", Modifier.padding(16.dp, 8.dp))
        LazyVerticalStaggeredGrid(
            columns = StaggeredGridCells.Fixed(2),
            modifier = Modifier.weight(1f).fillMaxWidth().testTag("grid_staggered"),
            contentPadding = PaddingValues(8.dp),
            verticalItemSpacing = 8.dp,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            items((0 until 60).toList(), key = { it }) { i ->
                Box(
                    modifier = Modifier.fillMaxWidth().height((80 + ((i * 37) % 5) * 30).dp)
                        .background(MaterialTheme.colorScheme.tertiaryContainer)
                        .testTag("stag_${pad2(i)}")
                        .clickable { result = "stag_${pad2(i)}" },
                    contentAlignment = Alignment.Center
                ) { Text("タイル ${pad2(i)}") }
            }
        }
    }
}
