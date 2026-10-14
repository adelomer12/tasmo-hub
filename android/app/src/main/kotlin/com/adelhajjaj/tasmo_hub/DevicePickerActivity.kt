package com.adelhajjaj.tasmo_hub

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.TileService
import android.widget.ArrayAdapter
import android.widget.ListView
import android.widget.TextView

/**
 * Chooses which device output a widget or Quick Settings tile controls.
 * Opened by the launcher when a widget is added (or reconfigured), from an
 * unassigned tile, or by long-pressing a tile.
 */
class DevicePickerActivity : Activity() {

    companion object {
        const val EXTRA_TILE_SLOT = "tile_slot"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)

        val widgetId = intent.getIntExtra(
            AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID
        )
        val tileSlot = intent.getStringExtra(EXTRA_TILE_SLOT) ?: tileFromPreferences()
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID && tileSlot == null) {
            finish()
            return
        }
        setTitle(R.string.picker_title)

        val targets = DeviceRepo.targets(this).filter { it.host.isNotEmpty() }
        if (targets.isEmpty()) {
            setContentView(TextView(this).apply {
                setText(R.string.picker_empty)
                setPadding(48, 48, 48, 48)
            })
            return
        }
        val list = ListView(this)
        list.adapter = ArrayAdapter(
            this, android.R.layout.simple_list_item_1,
            targets.map { if (it.locked) "${it.name} (${getString(R.string.state_locked)})" else it.name }
        )
        list.setOnItemClickListener { _, _, pos, _ ->
            val t = targets[pos]
            if (widgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                DeviceRepo.bind(this, DeviceWidgetProvider.slot(widgetId), t.key)
                DeviceWidgetProvider.render(applicationContext, widgetId, busy = false)
                Thread {
                    DeviceRepo.query(applicationContext, t)
                    DeviceWidgetProvider.render(applicationContext, widgetId, busy = false)
                }.start()
                setResult(
                    RESULT_OK,
                    Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
                )
            } else if (tileSlot != null) {
                DeviceRepo.bind(this, tileSlot, t.key)
                PowerTileService.requestUpdate(applicationContext, tileSlot)
            }
            finish()
        }
        setContentView(list)
    }

    /** Long-press on a tile sends QS_TILE_PREFERENCES with the tile's component. */
    private fun tileFromPreferences(): String? {
        if (intent.action != TileService.ACTION_QS_TILE_PREFERENCES) return null
        val cn: ComponentName? = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_COMPONENT_NAME, ComponentName::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_COMPONENT_NAME)
        }
        val name = cn?.className?.substringAfterLast('.') ?: return null
        return PowerTileService.slots.firstOrNull { it.simpleName == name }?.simpleName
    }
}
