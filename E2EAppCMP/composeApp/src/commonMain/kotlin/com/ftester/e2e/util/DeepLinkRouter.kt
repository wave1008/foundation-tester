package com.ftester.e2e.util

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * ディープリンク(fte2ecmp://…)の受け口。iOS(onOpenURL)/Android(Intent)がプロセスの外から
 * handle() を呼び、App() の LaunchedEffect が消費してナビゲーションへ反映する
 * (契約: E2EAppCMP/docs/ui-contract.md §ディープリンク)。
 * lastUrl はプロセス内メモリのみ(永続しない)= LifecycleScreen の SessionCounter と同じ規律。
 */
enum class DeepLinkScreen { SELECTOR, LIFECYCLE }

object DeepLinkRouter {
    var lastUrl by mutableStateOf<String?>(null)
        private set
    var pendingScreen by mutableStateOf<DeepLinkScreen?>(null)
        private set

    // 同じ URL が連続しても LaunchedEffect を確実に再トリガーするためのキー(pendingScreen の
    // 値そのものは enum の同一インスタンスなので、2回連続で同じ画面を指すと差分無しと誤認され得る)。
    var token by mutableStateOf(0)
        private set

    fun handle(url: String) {
        lastUrl = url
        pendingScreen = resolve(url)
        token++
    }

    fun consumePending() {
        pendingScreen = null
    }

    private fun resolve(url: String): DeepLinkScreen? {
        val path = url.substringAfter("://", missingDelimiterValue = "").substringBefore("?")
        return when (path) {
            "screen/selector" -> DeepLinkScreen.SELECTOR
            "screen/lifecycle" -> DeepLinkScreen.LIFECYCLE
            else -> null
        }
    }
}
