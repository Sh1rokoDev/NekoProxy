package com.nekoproxy.nekoproxy

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

class UpdateFileProvider : FileProvider()

internal object AppUpdateInstaller {
    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, "nekoproxy/update").setMethodCallHandler { call, result ->
            if (call.method != "installApk") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                result.success(installApk(activity, call.arguments as? String))
            } catch (error: IllegalArgumentException) {
                result.error("invalid_apk", error.message, null)
            } catch (error: android.content.ActivityNotFoundException) {
                result.error("installer_unavailable", "未找到系统安装程序。", null)
            } catch (error: SecurityException) {
                result.error("install_not_allowed", "系统不允许从 NekoProxy 安装更新。", null)
            } catch (error: java.io.IOException) {
                result.error("apk_unreadable", "无法读取下载的 APK。", null)
            }
        }
    }

    @Suppress("DEPRECATION") // The legacy overload also works on API 24–32.
    private fun installApk(activity: Activity, path: String?): Boolean {
        require(!path.isNullOrBlank()) { "缺少更新包路径。" }
        val updates = File(activity.cacheDir, "updates").canonicalFile
        val apk = File(path).canonicalFile
        require(apk.parentFile == updates && apk.isFile && apk.extension == "apk") {
            "只能安装 NekoProxy 下载的更新包。"
        }

        val packages = activity.packageManager
        val packageName = activity.packageName
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packages.canRequestPackageInstalls()) {
            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            return false
        }

        val archive = requireNotNull(packages.getPackageArchiveInfo(apk.path, 0)) {
            "系统无法识别此 APK。"
        }
        require(archive.packageName == packageName) { "更新包不属于 NekoProxy。" }
        val installed = packages.getPackageInfo(packageName, 0)
        require(PackageInfoCompat.getLongVersionCode(archive) > PackageInfoCompat.getLongVersionCode(installed)) {
            "更新包的构建号没有高于当前版本。"
        }

        val uri = FileProvider.getUriForFile(activity, "$packageName.updates", apk)
        activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
        return true
    }
}
