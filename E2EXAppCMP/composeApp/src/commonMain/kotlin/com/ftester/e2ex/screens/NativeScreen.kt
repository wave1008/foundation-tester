package com.ftester.e2ex.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.BottomSheetScaffold
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Text
import androidx.compose.material3.carousel.HorizontalMultiBrowseCarousel
import androidx.compose.material3.carousel.rememberCarouselState
import androidx.compose.material3.rememberBottomSheetScaffoldState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.TaggedButton
import com.ftester.e2ex.ui.TaggedText

private val RAIL_ITEMS = listOf(
    Triple(Tags.RAIL_ITEM_HOME, "ホーム", "home"),
    Triple(Tags.RAIL_ITEM_SEARCH, "探す", "search"),
    Triple(Tags.RAIL_ITEM_SETTINGS, "設定", "settings"),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NativeScreen() {
    var result by remember { mutableStateOf("none") }
    var railSelected by remember { mutableStateOf("home") }
    val carouselState = rememberCarouselState(initialItem = 0) { Tags.CAROUSEL_ITEM_COUNT }

    BottomSheetScaffold(
        scaffoldState = rememberBottomSheetScaffoldState(),
        sheetPeekHeight = 96.dp,
        sheetContent = {
            Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
                Text("ピークシート")
                TaggedButton(Tags.BSS_PEEK_BUTTON, "ピークのボタン") { result = "bss:tapped" }
            }
        }
    ) { padding ->
        Row(modifier = Modifier.fillMaxSize().padding(padding)) {
            NavigationRail {
                RAIL_ITEMS.forEach { (tag, label, value) ->
                    NavigationRailItem(
                        selected = railSelected == value,
                        onClick = { railSelected = value; result = "rail:$value" },
                        icon = { Text("●", modifier = Modifier.clearAndSetSemantics {}) },
                        label = { Text(label) },
                        modifier = Modifier.testTag(tag)
                    )
                }
            }
            Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
                TaggedText(Tags.NATIVE_RESULT, "native=$result")
                HorizontalMultiBrowseCarousel(
                    state = carouselState,
                    preferredItemWidth = 140.dp,
                    modifier = Modifier.fillMaxWidth().height(160.dp).padding(top = 16.dp)
                ) { index ->
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .testTag(Tags.carouselItem(index))
                            .background(Color(0xFF6650a4))
                            .clickable { result = "carousel:$index" },
                        contentAlignment = Alignment.Center
                    ) {
                        Text("Item $index", color = Color.White)
                    }
                }
            }
        }
    }
}
