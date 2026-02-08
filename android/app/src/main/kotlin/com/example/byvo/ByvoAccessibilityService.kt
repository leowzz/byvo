package com.example.byvo

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Toast

/**
 * 辅助功能服务：在收到插入请求时查找当前焦点可编辑节点，将指定文本填入。
 * 仅用于将 byvo 转写结果填入当前输入框，不用于其他用途。
 */
class ByvoAccessibilityService : AccessibilityService() {

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 插入由 performInsertText 触发，不依赖事件；此处可留空或用于缓存焦点
    }

    override fun onInterrupt() {}

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
    }

    /**
     * 查找焦点可编辑节点并填入文本；若无则复制到剪贴板并 Toast。
     */
    fun performInsertText(text: CharSequence?) {
        if (text.isNullOrEmpty()) {
            Log.d(TAG, "performInsertText: text null or empty")
            return
        }
        Log.d(TAG, "performInsertText: text.length=${text.length}")
        val root = rootInActiveWindow
        if (root == null) {
            Log.w(TAG, "performInsertText: rootInActiveWindow null, copy to clipboard")
            copyToClipboardAndToast(text)
            return
        }
        val focused = findFocusedInput(root) ?: findFocusedEditable(root)
        if (focused != null) {
            val ok = performSetText(focused, text)
            Log.d(TAG, "performInsertText: ACTION_SET_TEXT result=$ok")
            if (ok) return
        } else {
            Log.d(TAG, "performInsertText: no focused editable node")
        }
        Log.d(TAG, "performInsertText: fallback copy to clipboard")
        copyToClipboardAndToast(text)
    }

    /** 优先使用系统焦点（输入焦点） */
    private fun findFocusedInput(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN) {
            root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.takeIf { it.isEditable }
        } else null
    }

    private fun findFocusedEditable(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (root.isEditable && root.isFocused) return root
        for (i in 0 until root.childCount) {
            val child = root.getChild(i) ?: continue
            val found = findFocusedEditable(child)
            if (found != null) return found
        }
        return null
    }

    private fun performSetText(node: AccessibilityNodeInfo, text: CharSequence): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return false
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    private fun copyToClipboardAndToast(text: CharSequence) {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
        cm.setPrimaryClip(ClipData.newPlainText("byvo", text))
        Toast.makeText(this, "未找到输入框，已复制到剪贴板，请长按输入框粘贴", Toast.LENGTH_SHORT).show()
    }

    companion object {
        private const val TAG = "ByvoAccessibility"

        @Volatile
        var instance: ByvoAccessibilityService? = null
            private set

        /**
         * 从外部（如 InsertTextReceiver）请求插入文本；若服务未启用则返回 false。
         */
        fun performInsertText(context: Context, text: CharSequence?): Boolean {
            val service = instance
            if (service == null) {
                Log.w(TAG, "performInsertText: service not enabled")
                Toast.makeText(context, "请到设置-无障碍中开启 byvo，以将转写结果填入输入框", Toast.LENGTH_LONG).show()
                return false
            }
            service.performInsertText(text)
            return true
        }
    }
}
