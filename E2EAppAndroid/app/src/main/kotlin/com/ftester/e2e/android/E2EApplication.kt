package com.ftester.e2e.android

import android.app.Application
import android.content.Context
import android.content.SharedPreferences

// 永続化キーは "launch_count" / "auto_dialog" / "heal_schema_v1" の3つのみ
// (E2EApp/docs/ui-contract.md §永続化する値)。launchApp はアプリのデータを消さないため、
// これ以外を永続化するとシナリオの前提が崩れる。
object Prefs {
    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences("ft_e2e", Context.MODE_PRIVATE)
    }

    fun getInt(key: String, def: Int): Int = prefs.getInt(key, def)
    fun setInt(key: String, value: Int) = prefs.edit().putInt(key, value).apply()
    fun getBool(key: String, def: Boolean): Boolean = prefs.getBoolean(key, def)
    fun setBool(key: String, value: Boolean) = prefs.edit().putBoolean(key, value).apply()
}

// プロセス起動ごとに +1。Application.onCreate は1プロセス1回なので二重加算ガードは不要。
object LaunchCounter {
    var value = 0
        private set

    fun count() {
        value = Prefs.getInt("launch_count", 0) + 1
        Prefs.setInt("launch_count", value)
    }

    fun reset() {
        value = 1
        Prefs.setInt("launch_count", 1)
    }
}

// プロセス内メモリのみ。relaunch 検証は「画面離脱後も session が保持され、relaunch でのみ 0 に戻る」
// ことが要件のため Activity ではなくここに置く。
object SessionCounter {
    var value = 0
}

object AppInfo {
    const val VERSION = "1.0.0"
    const val APP_ID = "com.ftester.e2e.android"
}

class E2EApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Prefs.init(this)
        LaunchCounter.count()
    }
}
