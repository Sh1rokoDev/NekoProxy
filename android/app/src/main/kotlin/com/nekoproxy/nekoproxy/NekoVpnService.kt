package com.nekoproxy.nekoproxy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import com.nekoproxy.mobile.Engine
import com.nekoproxy.mobile.Mobile
import com.nekoproxy.mobile.Protector
import org.json.JSONArray
import org.json.JSONObject

class NekoVpnService : VpnService() {
    companion object {
        private const val TAG = "NekoVpnService"
        private const val CHANNEL_ID = "nekoproxy-vpn"
        private const val NOTIFICATION_ID = 1029
        private const val ACTION_START = "com.nekoproxy.nekoproxy.START"
        private const val ACTION_STOP = "com.nekoproxy.nekoproxy.STOP"
        private const val EXTRA_CONFIG = "config"
        private const val EXTRA_CACHE = "cache"
        private const val EXTRA_LOG = "log"
        private const val EXTRA_PER_APP_MODE = "per_app_mode"
        private const val EXTRA_PER_APP_PACKAGES = "per_app_packages"

        const val STATE_IDLE = 0
        const val STATE_STARTING = 1
        const val STATE_RUNNING = 2
        const val STATE_ERROR = 3

        @Volatile
        var state: Int = STATE_IDLE
            private set

        @Volatile
        var lastError: String? = null
            private set

        @Volatile
        private var engine: Engine? = null

        @Volatile
        private var startToken = 0

        @Volatile
        private var instance: NekoVpnService? = null

        fun start(
            context: Context,
            config: String,
            cachePath: String,
            logPath: String,
            perAppMode: String,
            perAppPackages: List<String>,
        ) {
            startToken++
            state = STATE_STARTING
            lastError = null
            val intent = Intent(context, NekoVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_CONFIG, config)
                putExtra(EXTRA_CACHE, cachePath)
                putExtra(EXTRA_LOG, logPath)
                putExtra(EXTRA_PER_APP_MODE, perAppMode)
                putStringArrayListExtra(EXTRA_PER_APP_PACKAGES, ArrayList(perAppPackages))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            startToken++
            val current = engine
            engine = null
            instance?.markStopRequested()
            instance?.closeTun()
            instance?.stopSelf()
            state = STATE_IDLE
            lastError = null
            // Engine shutdown can block while the TUN reader drains; never wait
            // for it on the caller (main) thread or stopSelf would be skipped.
            current?.let { stale ->
                Thread({ runCatching { stale.stop() } }, "nekoproxy-stop").start()
            }
        }

        fun status(): Map<String, Any?> {
            val current = engine
            if (state != STATE_RUNNING || current == null) {
                return mapOf(
                    "running" to false,
                    "error" to lastError,
                )
            }
            return try {
                jsonToMap(JSONObject(current.statusJSON()))
            } catch (error: Throwable) {
                mapOf("running" to false, "error" to (lastError ?: error.message))
            }
        }

        fun traffic(): Map<String, Any?> {
            val current = engine ?: return emptyMap()
            return try {
                jsonToMap(JSONObject(current.trafficJSON()))
            } catch (_: Throwable) {
                emptyMap()
            }
        }

        fun connections(): List<Map<String, Any?>> {
            val current = engine ?: return emptyList()
            return try {
                val array = JSONArray(current.connectionsJSON())
                buildList {
                    for (index in 0 until array.length()) {
                        add(jsonToMap(array.getJSONObject(index)))
                    }
                }
            } catch (_: Throwable) {
                emptyList()
            }
        }

        fun select(tag: String) {
            engine?.select(tag)
        }

        fun refreshAuto(delays: String) {
            engine?.refreshAuto(delays)
        }

        fun test(tags: List<String>, url: String): Map<String, Any?> {
            val current = engine ?: return emptyMap()
            return try {
                val payload = JSONArray(tags).toString()
                jsonToMap(JSONObject(current.test(payload, url)))
            } catch (_: Throwable) {
                emptyMap()
            }
        }

        fun closeConnection(id: String) {
            engine?.closeConnection(id)
        }

        fun clearConnections() {
            engine?.clearConnections()
        }

    }

    private var tunInterface: ParcelFileDescriptor? = null
    private var worker: Thread? = null

    @Volatile
    private var destroyed = false

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action != ACTION_START) {
            return START_NOT_STICKY
        }
        if (destroyed) {
            // A quick stop/start can reuse this instance before onDestroy runs.
            destroyed = false
            worker = null
            state = STATE_STARTING
            lastError = null
        }
        startForeground(NOTIFICATION_ID, buildNotification("正在启动 sing-box…"))
        val config = intent.getStringExtra(EXTRA_CONFIG) ?: ""
        val logPath = intent.getStringExtra(EXTRA_LOG) ?: ""
        val perAppMode = intent.getStringExtra(EXTRA_PER_APP_MODE) ?: "off"
        val perAppPackages = intent.getStringArrayListExtra(EXTRA_PER_APP_PACKAGES) ?: ArrayList()
        if (config.isBlank()) {
            fail("缺少内核配置")
            return START_NOT_STICKY
        }
        if (engine == null && worker?.isAlive != true) {
            val token = startToken
            worker = Thread(
                {
                    try {
                        startEngine(config, logPath, perAppMode, perAppPackages, token)
                    } finally {
                        if (token == startToken) worker = null
                    }
                },
                "nekoproxy-core",
            ).also { it.start() }
        }
        return START_NOT_STICKY
    }

    private fun startEngine(
        config: String,
        logPath: String,
        perAppMode: String,
        perAppPackages: List<String>,
        token: Int,
    ) {
        var core: Engine? = null
        try {
            val parsed = JSONObject(config)
            val tunOptions = findTunInbound(parsed)
                ?: throw IllegalStateException("配置中没有 TUN 入站")
            val addresses = tunOptions.optJSONArray("address") ?: JSONArray()
            val mtu = if (tunOptions.has("mtu")) tunOptions.optInt("mtu", 9000) else 9000
            val ipv6 = (0 until addresses.length()).any {
                addresses.optString(it).contains(':')
            }
            val autoRoute = tunOptions.optBoolean("auto_route", true)

            val builder = Builder()
                .setSession("NekoProxy")
                .setMtu(mtu)
                .setBlocking(true)
            val addressValues = ArrayList<String>(addresses.length())
            for (index in 0 until addresses.length()) {
                val value = addresses.optString(index)
                val slash = value.indexOf('/')
                if (slash > 0) {
                    builder.addAddress(value.substring(0, slash), value.substring(slash + 1).toInt())
                } else {
                    builder.addAddress(value, if (value.contains(':')) 128 else 32)
                }
                addressValues.add(value)
            }
            if (autoRoute) {
                builder.addRoute("0.0.0.0", 0)
                if (ipv6) builder.addRoute("::", 0)
            }
            applyPerAppSelection(builder, perAppMode, perAppPackages)
            builder.addDnsServer("172.19.0.2")
            if (ipv6) builder.addDnsServer("fdfe:dcba:9876::2")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }
            val pfd = builder.establish() ?: throw IllegalStateException("VpnService 未能建立 TUN 接口")
            tunInterface = pfd

            val protector = object : Protector {
                override fun protect(fd: Int): Boolean = this@NekoVpnService.protect(fd)
            }
            core = Mobile.newEngine(protector, VpnOwnerFinder(this))
            core.prepareTun(pfd.fd, JSONArray(addressValues).toString())
            Log.i(TAG, "starting sing-box core, log=$logPath")
            core.start(config)
            if (destroyed || token != startToken) {
                core.stop()
                pfd.close()
                if (tunInterface === pfd) tunInterface = null
                return
            }
            engine = core
            state = STATE_RUNNING
            lastError = null
            Log.i(TAG, "sing-box started, log=$logPath")
            updateNotification("已连接")
        } catch (error: Throwable) {
            Log.e(TAG, "failed to start sing-box", error)
            closeTun()
            core?.let { stale ->
                Thread({ runCatching { stale.stop() } }, "nekoproxy-stop").start()
            }
            if (token != startToken) return
            fail(error.message ?: "启动失败")
        }
    }

    private fun applyPerAppSelection(builder: Builder, mode: String, packages: List<String>) {
        val valid = packages
            .filter { it.matches(Regex("^[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+$")) }
            .filter { it != packageName }
            .distinct()
        if (valid.isEmpty()) {
            if (mode == "allow" || mode == "block") {
                Log.w(TAG, "per-app $mode list is empty; all installed apps are proxied")
            }
            return
        }
        when (mode) {
            "allow" -> valid.forEach { name ->
                runCatching { builder.addAllowedApplication(name) }
                    .onFailure { Log.w(TAG, "cannot allow $name", it) }
            }
            "block" -> valid.forEach { name ->
                runCatching { builder.addDisallowedApplication(name) }
                    .onFailure { Log.w(TAG, "cannot exclude $name", it) }
            }
        }
    }

    private fun findTunInbound(config: JSONObject): JSONObject? {
        val inbounds = config.optJSONArray("inbounds") ?: return null
        for (index in 0 until inbounds.length()) {
            val inbound = inbounds.optJSONObject(index) ?: continue
            if (inbound.optString("type") == "tun") return inbound
        }
        return null
    }

    private fun fail(message: String) {
        lastError = message
        state = STATE_ERROR
        val current = engine
        engine = null
        current?.let { stale ->
            Thread({ runCatching { stale.stop() } }, "nekoproxy-stop").start()
        }
        closeTun()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun closeTun() {
        try {
            tunInterface?.close()
        } catch (_: Throwable) {
        }
        tunInterface = null
    }

    override fun onRevoke() {
        stopSelf()
        super.onRevoke()
    }

    fun markStopRequested() {
        destroyed = true
    }

    override fun onDestroy() {
        destroyed = true
        closeTun()
        val current = engine
        engine = null
        current?.let { stale ->
            Thread({ runCatching { stale.stop() } }, "nekoproxy-stop").start()
        }
        instance = null
        if (state != STATE_ERROR) {
            state = STATE_IDLE
        }
        super.onDestroy()
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun buildNotification(text: String): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "代理连接",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }
        val pending = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("NekoProxy")
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
    }
}
