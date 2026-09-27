package com.ftester.e2ex.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.platform.testTag
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.TaggedText

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TabsScreen() {
    var tabIndex by remember { mutableStateOf(0) }
    var stabIndex by remember { mutableStateOf(0) }
    var navResult by remember { mutableStateOf("home") }

    val tabContent = ('A' + tabIndex).toString()
    val stabContent = (stabIndex + 1).toString().padStart(2, '0')

    Column(modifier = Modifier.fillMaxSize()) {
        Column(modifier = Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            PrimaryTabRow(selectedTabIndex = tabIndex) {
                Tab(
                    selected = tabIndex == 0,
                    onClick = { tabIndex = 0 },
                    text = { Text("タブA") },
                    modifier = Modifier.testTag(Tags.TAB_A)
                )
                Tab(
                    selected = tabIndex == 1,
                    onClick = { tabIndex = 1 },
                    text = { Text("タブB") },
                    modifier = Modifier.testTag(Tags.TAB_B)
                )
                Tab(
                    selected = tabIndex == 2,
                    onClick = { tabIndex = 2 },
                    text = { Text("タブC") },
                    modifier = Modifier.testTag(Tags.TAB_C)
                )
            }
            TaggedText(Tags.TAB_CONTENT, "content=$tabContent")

            ScrollableTabRow(selectedTabIndex = stabIndex, modifier = Modifier.testTag(Tags.STAB_ROW)) {
                for (i in 1..Tags.STAB_COUNT) {
                    Tab(
                        selected = stabIndex == i - 1,
                        onClick = { stabIndex = i - 1 },
                        text = { Text(Tags.stabLabel(i)) },
                        modifier = Modifier.testTag(Tags.stab(i))
                    )
                }
            }
            TaggedText(Tags.STAB_CONTENT, "scroll-tab=$stabContent")
            TaggedText(Tags.NAVBAR_RESULT, "navbar=$navResult")
        }

        NavigationBar(modifier = Modifier.fillMaxWidth()) {
            NavigationBarItem(
                selected = navResult == "home",
                onClick = { navResult = "home" },
                icon = { Text("⌂", modifier = Modifier.clearAndSetSemantics {}) },
                label = { Text("ホーム") },
                modifier = Modifier.testTag(Tags.NAVBAR_HOME)
            )
            NavigationBarItem(
                selected = navResult == "search",
                onClick = { navResult = "search" },
                icon = { Text("⌕", modifier = Modifier.clearAndSetSemantics {}) },
                label = { Text("探す") },
                modifier = Modifier.testTag(Tags.NAVBAR_SEARCH)
            )
            NavigationBarItem(
                selected = navResult == "settings",
                onClick = { navResult = "settings" },
                icon = { Text("⚙", modifier = Modifier.clearAndSetSemantics {}) },
                label = { Text("設定") },
                modifier = Modifier.testTag(Tags.NAVBAR_SETTINGS)
            )
        }
    }
}
