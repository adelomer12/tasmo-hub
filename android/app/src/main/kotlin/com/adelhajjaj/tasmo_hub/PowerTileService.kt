package com.adelhajjaj.tasmo_hub

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick Settings tile bound to one device output. Tap toggles; tap when
 * unassigned (or long-press) opens the device picker. Android needs one
 * manifest entry per tile, hence the three tiny subclasses below.
 */
abstract class PowerTileService : TileService() {

    private val main = Handler(Looper.getMainLooper())
    private val slot: String get() = javaClass.simpleName

    private fun target() = DeviceRepo.target(this, DeviceRepo.boundKey(this, slot))

    override fun onStartListening() {
        super.onStartListening()
        render(busy = false)
        val t = target() ?: return
        Thread {
            DeviceRepo.query(applicationContext, t)
            main.post { render(busy = false) }
        }.start()
    }

    override fun onClick() {
        super.onClick()
        val t = target()
        if (t == null) {
            openPicker()
            return
        }
        if (t.locked) {
            render(busy = false)
            return
        }
        render(busy = true)
        Thread {
            DeviceRepo.toggle(applicationContext, t)
            main.post { render(busy = false) }
        }.start()
    }

    private fun openPicker() {
        val intent = Intent(this, DevicePickerActivity::class.java)
            .putExtra(DevicePickerActivity.EXTRA_TILE_SLOT, slot)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    this, slot.hashCode(), intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun render(busy: Boolean) {
        val tile = qsTile ?: return
        val t = target()
        tile.icon = Icon.createWithResource(this, R.drawable.ic_tile_power)
        if (t == null) {
            tile.label = getString(R.string.tile_pick)
            tile.state = Tile.STATE_INACTIVE
            setSubtitle(tile, getString(R.string.tile_pick_hint))
        } else {
            val s = DeviceRepo.cachedState(this, t.key)
            tile.label = t.name
            tile.state = when {
                s == 1 -> Tile.STATE_ACTIVE
                s == 0 -> Tile.STATE_INACTIVE
                else -> Tile.STATE_UNAVAILABLE
            }
            setSubtitle(
                tile,
                when {
                    busy -> "…"
                    t.locked -> getString(R.string.state_locked)
                    s == 1 -> getString(R.string.state_on)
                    s == 0 -> getString(R.string.state_off)
                    else -> getString(R.string.state_unknown)
                }
            )
            // Keep an unreachable tile tappable so it can retry.
            if (s == -1 && !busy) tile.state = Tile.STATE_INACTIVE
        }
        tile.updateTile()
    }

    private fun setSubtitle(tile: Tile, text: String) {
        if (Build.VERSION.SDK_INT >= 29) tile.subtitle = text
    }

    companion object {
        val slots = listOf(
            PowerTile1::class.java, PowerTile2::class.java, PowerTile3::class.java
        )

        fun requestUpdate(ctx: Context, slot: String) {
            slots.firstOrNull { it.simpleName == slot }?.let {
                TileService.requestListeningState(ctx, ComponentName(ctx, it))
            }
        }
    }
}

class PowerTile1 : PowerTileService()
class PowerTile2 : PowerTileService()
class PowerTile3 : PowerTileService()
