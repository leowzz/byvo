package cn.wleo.byvo

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity

/**
 * 填入输入框的 MethodChannel 由 byvo_insert_text 插件注册（主引擎与 overlay 引擎均有），
 * 插件收到调用后发送广播，由 InsertTextReceiver 调用 ByvoAccessibilityService。
 */
class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        maybeRequestMicrophonePermission(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        maybeRequestMicrophonePermission(intent)
    }

    private fun maybeRequestMicrophonePermission(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_REQUEST_MIC_PERMISSION, false) != true) return
        intent.removeExtra(EXTRA_REQUEST_MIC_PERMISSION)
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            REQUEST_RECORD_AUDIO,
        )
    }

    companion object {
        private const val REQUEST_RECORD_AUDIO = 1001
        private const val EXTRA_REQUEST_MIC_PERMISSION = "request_mic_permission"
    }
}
