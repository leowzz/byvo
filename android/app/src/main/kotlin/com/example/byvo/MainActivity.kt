package com.example.byvo

import io.flutter.embedding.android.FlutterActivity

/**
 * 填入输入框的 MethodChannel 由 byvo_insert_text 插件注册（主引擎与 overlay 引擎均有），
 * 插件收到调用后发送广播，由 InsertTextReceiver 调用 ByvoAccessibilityService。
 */
class MainActivity : FlutterActivity()
