package com.nekoproxy.nekoproxy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import com.nekoproxy.mobile.Engine
import com.nekoproxy.mobile.Mobile
import com.nekoproxy.mobile.Protector
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

class NekoVpnService : VpnService() {
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    companion object {
        private const val TAG = "NekoVpnService"
        private const val CHANNEL_ID = "nekoproxy-vpn"
        private const val NOTIFICATION_ID = 1029
        private const val ACTION_START = "com.nekoproxy.nekoproxy.START"
        private const val ACTION_STOP = "com.nekoproxy.nekoproxy.STOP"
        private const val EXTRA_CONFIG = "config"
        private const val EXTRA_CACHE = "cache"
        private const val EXTRA_LOG = "log"
        private const val EXTRA_USE_VPN = "use_vpn"
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
        // A restart must release the old listener before binding the same port.
        private val lifecycle = Executors.newSingleThreadExecutor()

        private fun stopEngine(core: Engine?) {
            if (core == null) return
            lifecycle.execute {
                runCatching { core.stop() }
                    .onFailure { Log.w(TAG, "could not stop sing-box", it) }
            }
        }

        @Synchronized
        fun start(
            context: Context,
            config: String,
            cachePath: String,
            logPath: String,
            useVpn: Boolean,
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
                putExtra(EXTRA_USE_VPN, useVpn)
                putExtra(EXTRA_PER_APP_MODE, perAppMode)
                putStringArrayListExtra(EXTRA_PER_APP_PACKAGES, ArrayList(perAppPackages))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        @Synchronized
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
            stopEngine(current)
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
    private var queuedToken: Int? = null
    @Volatile
    private var usesVpn = false

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
            state = STATE_STARTING
            lastError = null
        }
        val useVpn = intent.getBooleanExtra(EXTRA_USE_VPN, true)
        usesVpn = useVpn
        val notification = buildNotification("正在启动 sing-box…")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    if (useVpn) ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED
                    else ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: RuntimeException) {
            fail(error.message ?: "前台服务启动失败")
            return START_NOT_STICKY
        }
        val config = intent.getStringExtra(EXTRA_CONFIG) ?: ""
        val logPath = intent.getStringExtra(EXTRA_LOG) ?: ""
        val perAppMode = intent.getStringExtra(EXTRA_PER_APP_MODE) ?: "off"
        val perAppPackages = intent.getStringArrayListExtra(EXTRA_PER_APP_PACKAGES) ?: ArrayList()
        if (config.isBlank()) {
            fail("缺少内核配置")
            return START_NOT_STICKY
        }
        val token = startToken
        if (engine == null && queuedToken != token) {
            queuedToken = token
            lifecycle.execute {
                if (!destroyed && token == startToken) {
                    startEngine(config, logPath, useVpn, perAppMode, perAppPackages, token)
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun startEngine(
        config: String,
        logPath: String,
        useVpn: Boolean,
        perAppMode: String,
        perAppPackages: List<String>,
        token: Int,
    ) {
        var core: Engine? = null
        try {
            val parsed = JSONObject(config)
            resolveManagedWireGuardPeers(parsed)
            val protector = if (useVpn) object : Protector {
                override fun protect(fd: Int): Boolean = this@NekoVpnService.protect(fd)
            } else null
            core = Mobile.newEngine(protector, if (useVpn) VpnOwnerFinder(this) else null)
            if (useVpn) prepareVpn(core, parsed, perAppMode, perAppPackages)
            Log.i(TAG, "starting sing-box core")
            core.start(parsed.toString())
            val published = synchronized(Companion) {
                if (destroyed || token != startToken) {
                    false
                } else {
                    engine = core
                    if (parsed.optJSONArray("endpoints")?.let { endpoints ->
                        (0 until endpoints.length()).any { endpoints.optJSONObject(it)?.optString("type") == "wireguard" }
                    } == true) observeWireGuardNetwork(core)
                    state = STATE_RUNNING
                    lastError = null
                    updateNotification(if (useVpn) "VPN 已连接" else "本地代理已启动")
                    true
                }
            }
            if (!published) {
                closeTun()
                core.stop()
                return
            }
            Log.i(TAG, "sing-box started, log=$logPath")
        } catch (error: Throwable) {
            Log.e(TAG, "failed to start sing-box", error)
            closeTun()
            if (engine === core) engine = null
            try {
                core?.stop()
            } catch (stopError: Exception) {
                Log.w(TAG, "could not stop failed sing-box engine", stopError)
            }
            synchronized(Companion) {
                if (!destroyed && token == startToken) fail(error.message ?: "启动失败")
            }
        }
    }

    private fun prepareVpn(
        core: Engine,
        parsed: JSONObject,
        perAppMode: String,
        perAppPackages: List<String>,
    ) {
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
            val routes = tunOptions.optJSONArray("route_address")
            if (routes == null || routes.length() == 0) {
                builder.addRoute("0.0.0.0", 0)
                if (ipv6) builder.addRoute("::", 0)
            } else {
                for (index in 0 until routes.length()) {
                    val route = routes.getString(index)
                    builder.addRoute(route.substringBefore('/'), route.substringAfter('/').toInt())
                }
                builder.addRoute("172.19.0.2", 32)
                if (ipv6) builder.addRoute("fdfe:dcba:9876::2", 128)
            }
        }
        applyPerAppSelection(builder, perAppMode, perAppPackages)
        builder.addDnsServer("172.19.0.2")
        if (ipv6) builder.addDnsServer("fdfe:dcba:9876::2")
        parsed.optJSONObject("dns")?.optJSONArray("servers")?.let { servers ->
            for (i in 0 until servers.length()) {
                val server = servers.optJSONObject(i) ?: continue
                if (server.optString("type") != "neko-wireguard-dns") continue
                server.optJSONArray("search_domains")?.let { domains ->
                    for (j in 0 until domains.length()) builder.addSearchDomain(domains.getString(j))
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }
        val pfd = builder.establish() ?: throw IllegalStateException("VpnService 未能建立 TUN 接口")
        tunInterface = pfd

        core.prepareTun(pfd.fd, JSONArray(addressValues).toString())
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
        stopEngine(current)
        closeTun()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun closeTun() {
        networkCallback?.let { callback ->
            networkCallback = null
            try {
                getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(callback)
            } catch (error: RuntimeException) {
                Log.w(TAG, "could not unregister underlying network callback", error)
            }
        }
        try {
            tunInterface?.close()
        } catch (_: Throwable) {
        }
        tunInterface = null
    }

    private fun observeWireGuardNetwork(core: Engine) {
        val manager = getSystemService(ConnectivityManager::class.java)
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (engine === core) core.rebindWireGuard()
            }
            override fun onLost(network: Network) {
                if (engine === core) core.rebindWireGuard()
            }
        }
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        manager.registerNetworkCallback(request, callback)
        networkCallback = callback
    }

    private fun resolveManagedWireGuardPeers(config: JSONObject) {
        val outbounds = config.optJSONArray("outbounds") ?: return
        val route = (0 until outbounds.length()).asSequence()
            .mapNotNull(outbounds::optJSONObject)
            .firstOrNull { it.optString("type") == "neko-wireguard-route" } ?: return
        val endpoints = config.getJSONArray("endpoints")
        val endpoint = (0 until endpoints.length()).asSequence()
            .mapNotNull(endpoints::optJSONObject)
            .first { it.optString("tag") == route.getString("endpoint") }
        val peers = endpoint.getJSONArray("peers")
        for (i in 0 until peers.length()) {
            val peer = peers.getJSONObject(i)
            val host = peer.getString("address")
            if (host.contains(':') || host.split('.').let { parts ->
                    parts.size == 4 && parts.all { part ->
                        part.toIntOrNull()?.let { it in 0..255 } == true
                    }
                }) continue
            val manager = getSystemService(ConnectivityManager::class.java)
            val network = (listOfNotNull(manager.activeNetwork) + manager.allNetworks)
                .firstOrNull {
                    val caps = manager.getNetworkCapabilities(it)
                    caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) == true &&
                        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                } ?: throw IllegalStateException("没有可用于解析 WireGuard 对端的底层网络")
            val address = network.getAllByName(host).firstOrNull()?.hostAddress
                ?: throw IllegalStateException("无法解析 WireGuard 对端")
            peer.put("address", address)
        }
        endpoint.remove("domain_resolver")
    }

    override fun onRevoke() {
        if (!usesVpn) return
        stopSelf()
        super.onRevoke()
    }

    fun markStopRequested() {
        destroyed = true
    }

    override fun onDestroy() {
        synchronized(Companion) {
            destroyed = true
            closeTun()
            if (instance === this) {
                stopEngine(engine)
                engine = null
                instance = null
                if (state != STATE_ERROR && queuedToken == startToken) {
                    state = STATE_IDLE
                }
            }
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
