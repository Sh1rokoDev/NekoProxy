package com.nekoproxy.nekoproxy

import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.nekoproxy.mobile.Engine
import java.net.NetworkInterface
import java.net.SocketException

internal class AndroidNetworkMonitor(
    private val manager: ConnectivityManager,
    private val core: Engine,
) : AutoCloseable {
    private val handler = Handler(Looper.getMainLooper())
    private val usesBestMatch = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
    private var registered = false
    private var current: Pair<Network, LinkProperties>? = null
    private val refresh = Runnable { refreshInterface() }
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            if (!usesBestMatch) scheduleRefresh()
        }

        override fun onLost(network: Network) {
            if (usesBestMatch) loseInterface(network) else scheduleRefresh()
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            if (!usesBestMatch) scheduleRefresh()
        }

        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
            if (usesBestMatch) updateInterface(network to properties) else scheduleRefresh()
        }
    }

    @Synchronized
    fun start() {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            manager.registerBestMatchingNetworkCallback(request, callback, handler)
        } else {
            manager.registerNetworkCallback(request, callback)
        }
        registered = true
        refreshInterface()
    }

    @Synchronized
    override fun close() {
        if (!registered) return
        registered = false
        handler.removeCallbacks(refresh)
        try {
            manager.unregisterNetworkCallback(callback)
        } catch (error: IllegalArgumentException) {
            Log.w(TAG, "could not unregister underlying network callback", error)
        }
    }

    @Synchronized
    private fun scheduleRefresh() {
        if (!registered) return
        handler.removeCallbacks(refresh)
        handler.post(refresh)
    }

    @Synchronized
    private fun refreshInterface() {
        if (!registered) return
        updateInterface(underlyingNetwork(manager)?.let { network ->
            manager.getLinkProperties(network)?.let { network to it }
        })
    }

    @Synchronized
    private fun loseInterface(network: Network) {
        if (current?.first == network) updateInterface(null)
    }

    @Synchronized
    private fun updateInterface(next: Pair<Network, LinkProperties>?) {
        if (!registered || next == current) return
        val name = next?.second?.interfaceName
        val index = try {
            name?.let { NetworkInterface.getByName(it)?.index }
        } catch (error: SocketException) {
            Log.w(TAG, "could not look up underlying network interface", error)
            null
        }
        if (name == null || index == null || index <= 0) {
            current = null
            core.updateDefaultInterface("", 0)
        } else {
            current = next
            core.updateDefaultInterface(name, index)
        }
    }

    companion object {
        private const val TAG = "AndroidNetworkMonitor"

        fun underlyingNetwork(manager: ConnectivityManager): Network? {
            fun physicalCapabilities(network: Network): NetworkCapabilities? =
                manager.getNetworkCapabilities(network)?.takeIf {
                    it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                        it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                }

            val active = manager.activeNetwork
            if (active != null && physicalCapabilities(active) != null) return active
            val candidates = manager.allNetworks.mapNotNull { network ->
                physicalCapabilities(network)?.let { network to it }
            }
            return (candidates.firstOrNull { (_, caps) ->
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            } ?: candidates.firstOrNull())?.first
        }
    }
}
