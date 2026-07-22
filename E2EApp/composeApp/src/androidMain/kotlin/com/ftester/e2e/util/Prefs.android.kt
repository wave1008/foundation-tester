package com.ftester.e2e.util

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.database.Cursor
import android.net.Uri

// Context を Activity から渡さずに済ませるための初期化経路。E2EInitializer が
// appContext を埋める(AndroidManifest への provider 登録が必須。登録が無いと未初期化で落ちる)。
internal lateinit var appContext: Context

private const val PREFS_NAME = "e2e_prefs"

private val sharedPreferences: SharedPreferences
    get() = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

actual object Prefs {
    actual fun getInt(key: String, def: Int): Int = sharedPreferences.getInt(key, def)

    actual fun setInt(key: String, value: Int) {
        sharedPreferences.edit().putInt(key, value).apply()
    }

    actual fun getBool(key: String, def: Boolean): Boolean = sharedPreferences.getBoolean(key, def)

    actual fun setBool(key: String, value: Boolean) {
        sharedPreferences.edit().putBoolean(key, value).apply()
    }
}

// androidx.startup 等を依存に足さずに applicationContext を得るための ContentProvider トリック。
// onCreate() は Application より先(プロセス起動時)に呼ばれるため、初期 composition 時点で appContext が確定している。
// AndroidManifest.xml に authorities="${applicationId}.e2einit" で登録すること。
class E2EInitializer : ContentProvider() {
    override fun onCreate(): Boolean {
        appContext = context!!.applicationContext
        return true
    }

    override fun query(
        uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?
    ): Int = 0
}
