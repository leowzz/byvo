package com.example.byvo.insert_text

import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityManager
import android.widget.Toast
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class ByvoInsertTextPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private var applicationContext: android.content.Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "byvo/insert_text")
        channel!!.setMethodCallHandler(this)
        Log.d(TAG, "ByvoInsertTextPlugin attached")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        applicationContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = applicationContext
        if (ctx == null) {
            Log.w(TAG, "${call.method}: no context")
            result.success(false)
            return
        }
        when (call.method) {
            "insertTextToFocusedField" -> {
                val text = call.argument<String>("text") ?: ""
                Log.d(TAG, "insertTextToFocusedField: sending broadcast, text.length=${text.length}")
                ctx.sendBroadcast(
                    Intent(ACTION_INSERT_TEXT).setPackage(ctx.packageName).putExtra(EXTRA_TEXT, text)
                )
                result.success(true)
            }
            "isAccessibilityServiceEnabled" -> {
                result.success(isAccessibilityServiceEnabled(ctx))
            }
            "vibrate" -> {
                val durationMs = (call.argument<Number>("durationMs")?.toLong() ?: 12L)
                    .coerceIn(1L, 50L)
                vibrate(ctx, durationMs)
                result.success(true)
            }
            "openAccessibilitySettings" -> {
                Toast.makeText(
                    ctx,
                    "请在无障碍设置中开启 byvo，允许将转写结果填入当前输入框",
                    Toast.LENGTH_LONG
                ).show()
                Handler(Looper.getMainLooper()).postDelayed({
                    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    ctx.startActivity(intent)
                }, 1200)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun isAccessibilityServiceEnabled(ctx: android.content.Context): Boolean {
        val manager = ctx.getSystemService(android.content.Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
            ?: return false
        val target = ComponentName(ctx, "com.example.byvo.ByvoAccessibilityService").flattenToString()
        val enabledServices = Settings.Secure.getString(
            ctx.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return manager.isEnabled && enabledServices.split(':').any { it.equals(target, ignoreCase = true) }
    }

    private fun vibrate(ctx: android.content.Context, durationMs: Long) {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val manager = ctx.getSystemService(android.content.Context.VIBRATOR_MANAGER_SERVICE)
                    as? VibratorManager
                manager?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                ctx.getSystemService(android.content.Context.VIBRATOR_SERVICE) as? Vibrator
            } ?: return

            if (!vibrator.hasVibrator()) return

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(
                    VibrationEffect.createOneShot(
                        durationMs,
                        VibrationEffect.DEFAULT_AMPLITUDE
                    )
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(durationMs)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "vibrate failed", t)
        }
    }

    companion object {
        private const val TAG = "ByvoInsertText"
        const val ACTION_INSERT_TEXT = "com.example.byvo.INSERT_TEXT"
        const val EXTRA_TEXT = "text"
    }
}
