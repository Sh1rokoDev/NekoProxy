package com.nekoproxy.nekoproxy

import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import com.nekoproxy.mobile.Mobile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "nekoproxy/runtime"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newCachedThreadPool()
    private var pendingStart: PendingStart? = null
    private var startAttempt = 0

    private data class PendingStart(
        val config: String,
        val cachePath: String,
        val logPath: String,
        val useVpn: Boolean,
        val perAppMode: String,
        val perAppPackages: List<String>,
        val result: MethodChannel.Result,
    )

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            handleCall(call, result)
        }
        AppUpdateInstaller.register(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> handleStart(call, result)
                "status" -> runAsync(result) { NekoVpnService.status() }
                "traffic" -> runAsync(result) { NekoVpnService.traffic() }
                "connections" -> runAsync(result) { NekoVpnService.connections() }
                "apps" -> runAsync(result, "apps_error") { listLaunchableApps() }
                "systemDns" -> runAsync(result) { systemDnsServers() }
                "convertRules" -> runAsync(result, "rules_conversion") {
                    Mobile.convertRules(
                        requireNotNull(call.argument<String>("kind")),
                        requireNotNull(call.argument<String>("input")),
                        requireNotNull(call.argument<String>("output")),
                    )
                    null
                }
                "select" -> runAsync(result) {
                    NekoVpnService.select(call.argument<String>("tag") ?: "")
                    null
                }
                "refreshAuto" -> runAsync(result) {
                    NekoVpnService.refreshAuto(requireNotNull(call.arguments as? String))
                    null
                }
                "test" -> {
                    val tags = call.argument<List<String>>("tags") ?: emptyList()
                    val url = call.argument<String>("url") ?: ""
                    executor.execute {
                        val output = if (NekoVpnService.state == NekoVpnService.STATE_RUNNING) {
                            NekoVpnService.test(tags, url)
                        } else {
                            TestRuntime.test(tags, url)
                        }
                        mainHandler.post { result.success(output) }
                    }
                }
                "startTest" -> runAsync(result, "test_start") {
                    if (NekoVpnService.state == NekoVpnService.STATE_RUNNING) {
                        throw IllegalStateException("请先断开当前连接")
                    }
                    TestRuntime.start(applicationContext, call.argument<String>("config") ?: "")
                }
                "stopTest" -> runAsync(result) {
                    TestRuntime.stop()
                    null
                }
                "closeConnection" -> runAsync(result) {
                    NekoVpnService.closeConnection(requireNotNull(call.argument<String>("connectionId")))
                    null
                }
                "clear" -> runAsync(result) {
                    NekoVpnService.clearConnections()
                    null
                }
                "stop" -> {
                    startAttempt++
                    pendingStart?.result?.error("vpn_start", "内核启动已取消", null)
                    pendingStart = null
                    NekoVpnService.stop(this)
                    result.success(null)
                }
                "cleanup" -> {
                    if (NekoVpnService.state == NekoVpnService.STATE_ERROR) {
                        NekoVpnService.stop(this)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error("runtime_error", error.message, null)
        }
    }

    private fun runAsync(
        result: MethodChannel.Result,
        errorCode: String = "runtime_error",
        block: () -> Any?,
    ) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                mainHandler.post { result.error(errorCode, error.message, null) }
            }
        }
    }

    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config") ?: ""
        val cachePath = call.argument<String>("cachePath") ?: ""
        val logPath = call.argument<String>("logPath") ?: ""
        val useVpn = call.argument<String>("mode") != "normal"
        val perAppMode = call.argument<String>("perAppMode") ?: "off"
        val perAppPackages = call.argument<List<String>>("perAppPackages") ?: emptyList()
        if (config.isBlank()) {
            result.error("invalid_config", "内核配置为空", null)
            return
        }
        val pending = PendingStart(config, cachePath, logPath, useVpn, perAppMode, perAppPackages, result)
        val prepareIntent = if (useVpn) VpnService.prepare(this) else null
        if (prepareIntent != null) {
            pendingStart = pending
            startActivityForResult(prepareIntent, VPN_PERMISSION_REQUEST)
        } else {
            launchCore(pending)
        }
    }

    private fun launchCore(pending: PendingStart) {
        try {
            NekoVpnService.start(
                this,
                pending.config,
                pending.cachePath,
                pending.logPath,
                pending.useVpn,
                pending.perAppMode,
                pending.perAppPackages,
            )
        } catch (error: Throwable) {
            pending.result.error("vpn_start", error.message, null)
            return
        }
        awaitStarted(pending.result, System.currentTimeMillis(), ++startAttempt)
    }

    private fun awaitStarted(result: MethodChannel.Result, startedAt: Long, attempt: Int) {
        if (attempt != startAttempt) {
            result.error("vpn_start", "内核启动已取消", null)
            return
        }
        val state = NekoVpnService.state
        if (state == NekoVpnService.STATE_RUNNING) {
            result.success(NekoVpnService.status())
            return
        }
        if (state == NekoVpnService.STATE_ERROR) {
            result.error("vpn_start", NekoVpnService.lastError ?: "启动失败", null)
            return
        }
        if (System.currentTimeMillis() - startedAt > 60_000) {
            // Never leave a TUN up when the core never finished starting.
            NekoVpnService.stop(this)
            result.error("vpn_start", "等待内核启动超时", null)
            return
        }
        mainHandler.postDelayed({ awaitStarted(result, startedAt, attempt) }, 150)
    }

    /**
     * DNS servers of the physical network underneath the VPN. Proxy server
     * addresses must be resolved with the platform resolver, like every other
     * client does: public DoH can be slow or filtered on some networks, which
     * inflates latency probes and marks reachable nodes as failed.
     */
    private fun systemDnsServers(): List<String> {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return emptyList()
        val ranked = ArrayList<Pair<Int, List<String>>>()
        for (network in manager.allNetworks) {
            val capabilities = manager.getNetworkCapabilities(network) ?: continue
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            val rank = when {
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 0
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 1
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 2
                else -> 3
            }
            val properties = manager.getLinkProperties(network) ?: continue
            val servers = properties.dnsServers
                .mapNotNull { address -> address.hostAddress?.takeIf { it.contains('.') } }
                .distinct()
            if (servers.isNotEmpty()) ranked.add(rank to servers)
        }
        ranked.sortBy { it.first }
        return ranked.flatMap { it.second }.distinct()
    }

    private fun listLaunchableApps(): List<Map<String, Any?>> {
        val manager = packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = manager.queryIntentActivities(launcher, 0)
        val seen = HashSet<String>(resolved.size)
        val apps = ArrayList<Map<String, Any?>>(resolved.size)
        for (item in resolved) {
            val packageName = item.activityInfo.packageName
            if (!seen.add(packageName)) continue
            val info = item.activityInfo.applicationInfo
            apps.add(
                mapOf(
                    "package" to packageName,
                    "label" to item.loadLabel(manager).toString(),
                    "system" to ((info.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                ),
            )
        }
        apps.sortBy { (it["label"] as String).lowercase() }
        return apps
    }

    @Deprecated("FlutterActivity still delivers VPN consent through this callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_PERMISSION_REQUEST) return
        val pending = pendingStart ?: return
        pendingStart = null
        if (resultCode == Activity.RESULT_OK) {
            launchCore(pending)
        } else {
            pending.result.error("vpn_permission", "用户拒绝了 VPN 授权", null)
        }
    }

    override fun onDestroy() {
        TestRuntime.stopAsync()
        executor.shutdownNow()
        super.onDestroy()
    }

    companion object {
        private const val VPN_PERMISSION_REQUEST = 0x5650
    }
}
