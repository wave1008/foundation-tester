package com.ftester.e2ex.android

// E2EXAppCMP/composeApp .../util/EpochDate.kt と同一アルゴリズム(Howard Hinnant の
// civil_from_days)。MaterialDatePicker の選択値(UTC epoch millis)も同じ値域なので共有できる。

const val INITIAL_DATE_EPOCH_MILLIS = 1768435200000L

private const val MILLIS_PER_DAY = 86_400_000L

private fun floorDiv(a: Long, b: Long): Long {
    val q = a / b
    return if ((a % b != 0L) && ((a < 0) != (b < 0))) q - 1 else q
}

fun formatUtcDate(epochMillis: Long): String {
    val days = floorDiv(epochMillis, MILLIS_PER_DAY)
    var z = days + 719468
    val era = floorDiv(if (z >= 0) z else z - 146096, 146097)
    val doe = z - era * 146097
    val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    val y = yoe + era * 400
    val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    val mp = (5 * doy + 2) / 153
    val d = doy - (153 * mp + 2) / 5 + 1
    val m = if (mp < 10) mp + 3 else mp - 9
    val year = if (m <= 2) y + 1 else y
    val mm = m.toString().padStart(2, '0')
    val dd = d.toString().padStart(2, '0')
    return "$year-$mm-$dd"
}
