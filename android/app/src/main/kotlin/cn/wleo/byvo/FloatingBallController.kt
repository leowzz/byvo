package cn.wleo.byvo

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.app.ActivityManager
import android.os.Build
import android.provider.Settings
import android.service.quicksettings.TileService
import cn.wleo.byvo.insert_text.AccessibilityStatus

class FloatingBallController(
    private val context: Context,
) {
    fun desiredEnabled(): Boolean = prefs().getBoolean(STORAGE_KEY_SHOW_FLOATING_BALL, false)

    fun setDesiredEnabled(value: Boolean) {
        prefs().edit().putBoolean(STORAGE_KEY_SHOW_FLOATING_BALL, value).apply()
        requestTileRefresh()
    }

    fun enable(): ToggleResult {
        if (!AccessibilityStatus.isByvoAccessibilityEnabled(context)) {
            setDesiredEnabled(false)
            return ToggleResult.ACCESSIBILITY_DENIED
        }
        if (!Settings.canDrawOverlays(context)) {
            setDesiredEnabled(false)
            return ToggleResult.OVERLAY_PERMISSION_DENIED
        }

        return runCatching {
            startOverlayService()
        }.fold(
            onSuccess = { started ->
                if (!started) {
                    setDesiredEnabled(false)
                    return ToggleResult.START_FAILED
                }
                setDesiredEnabled(true)
                ToggleResult.ENABLED
            },
            onFailure = {
                setDesiredEnabled(false)
                ToggleResult.START_FAILED
            },
        )
    }

    fun disable(): ToggleResult {
        runCatching {
            context.stopService(Intent().setClassName(context, OVERLAY_SERVICE_CLASS_NAME))
        }
        setDesiredEnabled(false)
        return ToggleResult.DISABLED
    }

    fun tileActive(): Boolean = desiredEnabled()

    fun resolvedTileActive(): Boolean = desiredEnabled() && isOverlayRunning()

    fun isOverlayRunning(): Boolean = isOverlayServiceRunning()

    private fun requestTileRefresh() {
        if (!hasTileServiceClass()) {
            return
        }
        TileService.requestListeningState(
            context,
            ComponentName(context.packageName, "${context.packageName}.$FLOATING_BALL_TILE_SERVICE_CLASS_NAME"),
        )
    }

    private fun isOverlayServiceRunning(): Boolean {
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return false
        @Suppress("DEPRECATION")
        return activityManager.getRunningServices(Int.MAX_VALUE).any {
            it.service.className == OVERLAY_SERVICE_CLASS_NAME
        }
    }

    private fun startOverlayService(): Boolean {
        val intent = Intent().setClassName(context, OVERLAY_SERVICE_CLASS_NAME)
        val service = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
        return service != null
    }

    private fun hasTileServiceClass(): Boolean {
        return runCatching {
            Class.forName("${context.packageName}.$FLOATING_BALL_TILE_SERVICE_CLASS_NAME")
        }.isSuccess
    }

    private fun prefs() = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    enum class ToggleResult {
        ENABLED,
        DISABLED,
        ACCESSIBILITY_DENIED,
        OVERLAY_PERMISSION_DENIED,
        START_FAILED,
    }

    companion object {
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val KEY_SHOW_FLOATING_BALL = "show_floating_ball"
        private const val STORAGE_KEY_SHOW_FLOATING_BALL = "flutter.$KEY_SHOW_FLOATING_BALL"
        private const val OVERLAY_SERVICE_CLASS_NAME =
            "flutter.overlay.window.flutter_overlay_window.OverlayService"
        private const val FLOATING_BALL_TILE_SERVICE_CLASS_NAME = "FloatingBallTileService"
    }
}
