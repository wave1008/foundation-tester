package com.ftester.e2e.util

// 永続化キーは "launch_count" / "auto_dialog" / "heal_schema_v1" の3つのみ(docs/ui-contract.md §永続化する値)。
expect object Prefs {
    fun getInt(key: String, def: Int): Int
    fun setInt(key: String, value: Int)
    fun getBool(key: String, def: Boolean): Boolean
    fun setBool(key: String, value: Boolean)
}
