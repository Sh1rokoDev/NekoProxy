package com.nekoproxy.nekoproxy

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import com.nekoproxy.mobile.OwnerFinder
import org.json.JSONArray
import org.json.JSONObject
import java.net.InetAddress
import java.net.InetSocketAddress

class VpnOwnerFinder(private val service: NekoVpnService) : OwnerFinder {
    override fun findOwner(
        protocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return ""
        return try {
            val manager = service.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return ""
            val local = InetSocketAddress(InetAddress.getByName(sourceAddress), sourcePort)
            val remote = InetSocketAddress(InetAddress.getByName(destinationAddress), destinationPort)
            val uid = manager.getConnectionOwnerUid(protocol, local, remote)
            if (uid < 0) return ""
            val packages = service.packageManager.getPackagesForUid(uid) ?: emptyArray()
            if (packages.isEmpty()) return ""
            JSONObject()
                .put("processId", uid)
                .put("userId", uid)
                .put("processPath", "")
                .put("packageNames", JSONArray(packages))
                .toString()
        } catch (_: Throwable) {
            ""
        }
    }
}
