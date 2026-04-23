package cn.wleo.byvo

import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast
import cn.wleo.byvo.FloatingBallController.ToggleResult

class FloatingBallTileService : TileService() {
    private val controller by lazy { FloatingBallController(applicationContext) }

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        when (if (controller.isOverlayRunning()) controller.disable() else controller.enable()) {
            ToggleResult.ENABLED,
            ToggleResult.DISABLED -> updateTile()
            ToggleResult.ACCESSIBILITY_DENIED -> {
                Toast.makeText(
                    this,
                    R.string.quick_settings_accessibility_denied,
                    Toast.LENGTH_SHORT,
                ).show()
                updateTile()
            }
            ToggleResult.OVERLAY_PERMISSION_DENIED -> {
                Toast.makeText(
                    this,
                    R.string.quick_settings_overlay_permission_denied,
                    Toast.LENGTH_SHORT,
                ).show()
                updateTile()
            }
            ToggleResult.START_FAILED -> {
                Toast.makeText(
                    this,
                    R.string.quick_settings_enable_failed,
                    Toast.LENGTH_SHORT,
                ).show()
                updateTile()
            }
        }
    }

    private fun updateTile() {
        qsTile?.apply {
            label = getString(R.string.quick_settings_tile_label)
            state = if (controller.resolvedTileActive()) {
                Tile.STATE_ACTIVE
            } else {
                Tile.STATE_INACTIVE
            }
            updateTile()
        }
    }
}
