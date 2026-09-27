package com.ftester.e2ex.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
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

@Composable
fun GridScreen() {
    var result by remember { mutableStateOf("none") }

    Column(modifier = Modifier.fillMaxSize()) {
        TaggedText(Tags.GRID_RESULT, "grid=$result", modifier = Modifier.padding(16.dp))
        LazyVerticalGrid(
            columns = GridCells.Fixed(3),
            modifier = Modifier.fillMaxSize().testTag(Tags.GRID_MAIN)
        ) {
            items(Tags.GRID_CELL_COUNT) { n ->
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(96.dp)
                        .testTag(Tags.cell(n))
                        .clickable { result = n.toString().padStart(2, '0') },
                    contentAlignment = Alignment.Center
                ) {
                    Text(Tags.cellLabel(n))
                }
            }
        }
    }
}
