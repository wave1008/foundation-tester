package com.ftester.e2e.util

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

// counted ガードは composition の再実行(recomposition)による二重加算を防ぐ。App() から1回だけ呼ばれる前提。
object LaunchCounter {
    private var counted = false
    var value by mutableStateOf(0)
        private set

    fun ensureCounted() {
        if (!counted) {
            counted = true
            value = Prefs.getInt("launch_count", 0) + 1
            Prefs.setInt("launch_count", value)
        }
    }

    fun reset() {
        value = 1
        Prefs.setInt("launch_count", 1)
    }
}
