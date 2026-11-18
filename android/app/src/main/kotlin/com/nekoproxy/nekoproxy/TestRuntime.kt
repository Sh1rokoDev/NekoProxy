package com.nekoproxy.nekoproxy

import android.content.Context
import android.net.ConnectivityManager
import com.nekoproxy.mobile.Engine
import com.nekoproxy.mobile.Mobile
import com.nekoproxy.mobile.OwnerFinder
import org.json.JSONArray
import org.json.JSONObject

/**
 * A short-lived sing-box instance used only for latency tests while no VPN is
 * active. The generated configuration has no TUN or inbound, so this engine
 * cannot change device routing.
 */
object TestRuntime {
    private val lock = Any()

    @Volatile
    private var engine: Engine? = null
    private var networkMonitor: AndroidNetworkMonitor? = null

    fun start(context: Context, config: String): Map<String, Any?> {
        synchronized(lock) {
            stopLocked()
            val core = Mobile.newEngine(null, NoopOwnerFinder)
            val monitor = AndroidNetworkMonitor(context.getSystemService(ConnectivityManager::class.java), core)
            try {
                monitor.start()
                core.start(config)
            } catch (error: Throwable) {
                monitor.close()
                runCatching { core.stop() }
                throw IllegalStateException(error.message ?: "测速核心启动失败", error)
            }
            networkMonitor = monitor
            engine = core
            return mapOf("running" to true)
        }
    }

    fun stop() {
        synchronized(lock) {
            stopLocked()
        }
    }

    fun stopAsync() {
        Thread({ runCatching { stop() } }, "nekoproxy-test-stop").start()
    }

    fun test(tags: List<String>, url: String): Map<String, Any?> {
        val current = engine ?: return emptyMap()
        return try {
            jsonToMap(JSONObject(current.test(JSONArray(tags).toString(), url)))
        } catch (_: Throwable) {
            emptyMap()
        }
    }

    private fun stopLocked() {
        networkMonitor?.close()
        networkMonitor = null
        val current = engine ?: return
        engine = null
        runCatching { current.stop() }
    }

    private object NoopOwnerFinder : OwnerFinder {
        override fun findOwner(
            protocol: Int,
            sourceAddress: String,
            sourcePort: Int,
            destinationAddress: String,
            destinationPort: Int,
        ): String = ""
    }
}
