package com.example.byvo

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 接收「填入当前输入框」请求（由 overlay 经插件广播），调用辅助功能执行插入。
 */
class InsertTextReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_INSERT_TEXT) return
        val text = intent.getStringExtra(EXTRA_TEXT) ?: return
        Log.d(TAG, "InsertTextReceiver: received, text.length=${text.length}")
        ByvoAccessibilityService.performInsertText(context, text)
    }

    companion object {
        private const val TAG = "ByvoInsertText"
        const val ACTION_INSERT_TEXT = "com.example.byvo.INSERT_TEXT"
        const val EXTRA_TEXT = "text"
    }
}
