package com.nekoproxy.nekoproxy

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal object LauncherIcon {
    private const val SYSTEM = "MainActivity"
    private const val LIGHT = "LightLauncher"
    private const val DARK = "DarkLauncher"
    private val aliases = listOf(SYSTEM, LIGHT, DARK)

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "nekoproxy/launcher_icon").setMethodCallHandler { call, result ->
            if (call.method != "setTheme") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val selected = when (call.arguments) {
                "system" -> SYSTEM
                "light" -> LIGHT
                "dark" -> DARK
                else -> {
                    result.error("invalid_theme", "Unknown launcher icon theme", null)
                    return@setMethodCallHandler
                }
            }
            try {
                if (app.resources.getBoolean(R.bool.switch_launcher_icon)) {
                    switchAlias(app, selected)
                }
                result.success(null)
            } catch (error: RuntimeException) {
                result.error("launcher_icon_error", error.message, null)
            }
        }
    }

    private fun switchAlias(context: Context, selected: String) {
        val manager = context.packageManager
        // On older Android versions, enable the replacement before disabling the old entry.
        val changes = (listOf(selected) + aliases.filter { it != selected }).mapNotNull { alias ->
            val component = ComponentName(context, "${context.packageName}.$alias")
            val state = when {
                alias == SYSTEM && selected != SYSTEM -> PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                alias == selected && alias != SYSTEM -> PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else -> PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
            }
            if (manager.getComponentEnabledSetting(component) == state) null else component to state
        }
        if (changes.isEmpty()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.setComponentEnabledSettings(changes.map { (component, state) ->
                PackageManager.ComponentEnabledSetting(component, state, PackageManager.DONT_KILL_APP)
            })
        } else {
            for ((component, state) in changes) {
                manager.setComponentEnabledSetting(component, state, PackageManager.DONT_KILL_APP)
            }
        }
    }
}
