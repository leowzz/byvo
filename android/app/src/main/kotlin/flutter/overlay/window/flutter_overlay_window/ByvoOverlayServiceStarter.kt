package flutter.overlay.window.flutter_overlay_window

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.JSONMessageCodec

object ByvoOverlayServiceStarter {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val STORAGE_KEY_OVERLAY_LAST_X = "flutter.overlay_last_x"
    private const val STORAGE_KEY_OVERLAY_LAST_Y = "flutter.overlay_last_y"
    private const val SHARED_PREFERENCES_DOUBLE_PREFIX =
        "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu"
    private const val OVERLAY_SIZE = 180
    private const val OVERLAY_TITLE = "byvo"
    private const val OVERLAY_CONTENT = "长按约 0.5 秒录音"

    fun startFloatingBall(context: Context): ComponentName? {
        val appContext = context.applicationContext
        ensureCachedEngine(appContext)
        ensureOverlayMessenger()
        configureWindowSetup()

        val intent = Intent(appContext, OverlayService::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("startX", overlayStartCoordinate(appContext, STORAGE_KEY_OVERLAY_LAST_X))
            putExtra("startY", overlayStartCoordinate(appContext, STORAGE_KEY_OVERLAY_LAST_Y))
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            appContext.startForegroundService(intent)
        } else {
            appContext.startService(intent)
        }
    }

    private fun ensureCachedEngine(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(OverlayConstants.CACHED_TAG)?.let { return it }

        val engine = FlutterEngineGroup(context).createAndRunEngine(
            context,
            DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                "overlayMain",
            ),
        )
        FlutterEngineCache.getInstance().put(OverlayConstants.CACHED_TAG, engine)
        return engine
    }

    private fun ensureOverlayMessenger() {
        if (WindowSetup.messenger != null) {
            return
        }
        val flutterEngine = FlutterEngineCache.getInstance().get(OverlayConstants.CACHED_TAG) ?: return
        WindowSetup.messenger = BasicMessageChannel(
            flutterEngine.dartExecutor,
            OverlayConstants.MESSENGER_TAG,
            JSONMessageCodec.INSTANCE,
        )
    }

    private fun configureWindowSetup() {
        WindowSetup.width = OVERLAY_SIZE
        WindowSetup.height = OVERLAY_SIZE
        WindowSetup.enableDrag = true
        WindowSetup.setGravityFromAlignment("centerRight")
        WindowSetup.setFlag("flagNotFocusable")
        WindowSetup.overlayTitle = OVERLAY_TITLE
        WindowSetup.overlayContent = OVERLAY_CONTENT
        WindowSetup.positionGravity = "none"
        WindowSetup.setNotificationVisibility("visibilitySecret")
    }

    private fun overlayStartCoordinate(context: Context, key: String): Int {
        val rawValue = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).all[key]
        return when (rawValue) {
            is String -> rawValue
                .removePrefix(SHARED_PREFERENCES_DOUBLE_PREFIX)
                .toDoubleOrNull()
                ?.toInt()
                ?: OverlayConstants.DEFAULT_XY
            is Number -> rawValue.toInt()
            else -> OverlayConstants.DEFAULT_XY
        }
    }
}
