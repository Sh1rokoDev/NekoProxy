package com.nekoproxy.nekoproxy

import org.json.JSONArray
import org.json.JSONObject

internal fun jsonToMap(value: JSONObject): Map<String, Any?> {
    val result = LinkedHashMap<String, Any?>()
    val keys = value.keys()
    while (keys.hasNext()) {
        val key = keys.next()
        result[key] = when (val item = value.opt(key)) {
            is JSONObject -> jsonToMap(item)
            is JSONArray -> jsonToList(item)
            JSONObject.NULL -> null
            else -> item
        }
    }
    return result
}

internal fun jsonToList(value: JSONArray): List<Any?> {
    val result = ArrayList<Any?>(value.length())
    for (index in 0 until value.length()) {
        result.add(
            when (val item = value.opt(index)) {
                is JSONObject -> jsonToMap(item)
                is JSONArray -> jsonToList(item)
                JSONObject.NULL -> null
                else -> item
            },
        )
    }
    return result
}
