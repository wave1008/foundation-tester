package com.ftester.e2e.util

import platform.Foundation.NSUserDefaults

actual object Prefs {
    private val defaults = NSUserDefaults.standardUserDefaults

    actual fun getInt(key: String, def: Int): Int {
        if (defaults.objectForKey(key) == null) return def
        return defaults.integerForKey(key).toInt()
    }

    actual fun setInt(key: String, value: Int) {
        defaults.setInteger(value.toLong(), key)
    }

    // objectForKey == null でキー未設定と false を区別する(boolForKey は未設定でも false を返すため)。
    actual fun getBool(key: String, def: Boolean): Boolean {
        if (defaults.objectForKey(key) == null) return def
        return defaults.boolForKey(key)
    }

    actual fun setBool(key: String, value: Boolean) {
        defaults.setBool(value, key)
    }
}
