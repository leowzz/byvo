package com.example.byvo.insert_text

import android.content.Intent
import android.util.Log
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
        if (call.method == "insertTextToFocusedField") {
            val text = call.argument<String>("text") ?: ""
            val ctx = applicationContext
            if (ctx == null) {
                Log.w(TAG, "insertTextToFocusedField: no context")
                result.success(false)
                return
            }
            Log.d(TAG, "insertTextToFocusedField: sending broadcast, text.length=${text.length}")
            ctx.sendBroadcast(
                Intent(ACTION_INSERT_TEXT).setPackage(ctx.packageName).putExtra(EXTRA_TEXT, text)
            )
            result.success(true)
        } else {
            result.notImplemented()
        }
    }

    companion object {
        private const val TAG = "ByvoInsertText"
        const val ACTION_INSERT_TEXT = "com.example.byvo.INSERT_TEXT"
        const val EXTRA_TEXT = "text"
    }
}
