package dev.fluxdown.android.data

import org.json.JSONObject
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * 作者: long
 * org.json 的 optString 会把 JSON null 读成字面量 "null"，属性面板曾因此显示 "null"。
 * 这里锁死归一化行为，避免回归。
 * 必须跑在 Robolectric 下：JVM 单测里的 android.jar 是桩实现，org.json 会抛 "not mocked"。
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class QueueParsingNullTest {
    @Test
    fun jsonNullBecomesKotlinNull() {
        val task = JSONObject("""{"id":"t1","error":null,"torrent_name":null,"credential_ref":null}""")
        assertNull(task.optNullableString("error"))
        assertNull(task.optNullableString("torrent_name", "torrentName"))
        assertNull(task.optNullableString("credential_ref", "credentialRef"))
    }

    @Test
    fun literalNullTextIsTreatedAsNull() {
        val task = JSONObject("""{"error":"null","torrent_name":"  ","credential_ref":""}""")
        assertNull(task.optNullableString("error"))
        assertNull(task.optNullableString("torrent_name"))
        assertNull(task.optNullableString("credential_ref"))
    }

    @Test
    fun realValueSurvives() {
        val task = JSONObject("""{"error":"连接被重置"}""")
        assertEquals("连接被重置", task.optNullableString("error"))
    }

    @Test
    fun parseTasksDropsNullError() {
        val raw = """{"ok":true,"data":[
            {"id":"t1","file_name":"a.bin","source":"http://h/a.bin","state":"finished","downloaded_bytes":10,"total_bytes":10,"error":null}
        ]}"""
        val tasks = parseTasks(raw)
        assertEquals(1, tasks.size)
        assertNull(tasks.first().error)
    }
}
