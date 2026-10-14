package com.adelhajjaj.tasmo_hub

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * 1x1 / 2x1 home-screen widget bound to one device output. Tap toggles it
 * over the device's local HTTP API; the app does not need to be running.
 */
class DeviceWidgetProvider : AppWidgetProvider() {

    companion object {
        const val ACTION_TOGGLE = "com.adelhajjaj.tasmo_hub.WIDGET_TOGGLE"

        fun slot(id: Int) = "w$id"

        fun ids(ctx: Context): IntArray = AppWidgetManager.getInstance(ctx)
            .getAppWidgetIds(ComponentName(ctx, DeviceWidgetProvider::class.java))

        /** Redraws every widget from cache, then refreshes states. Blocking. */
        fun refreshAll(ctx: Context) {
            val ids = ids(ctx)
            ids.forEach { render(ctx, it, busy = false) }
            val threads = ids.map { id ->
                Thread {
                    DeviceRepo.target(ctx, DeviceRepo.boundKey(ctx, slot(id)))
                        ?.let { DeviceRepo.query(ctx, it) }
                    render(ctx, id, busy = false)
                }.also { it.start() }
            }
            threads.forEach { it.join(8000) }
        }

        fun render(ctx: Context, id: Int, busy: Boolean) {
            val views = RemoteViews(ctx.packageName, R.layout.widget_device)
            val t = DeviceRepo.target(ctx, DeviceRepo.boundKey(ctx, slot(id)))
            if (t == null) {
                views.setTextViewText(R.id.widget_name, ctx.getString(R.string.widget_pick))
                views.setTextViewText(R.id.widget_state, "")
                views.setInt(R.id.widget_root, "setBackgroundResource", R.drawable.widget_bg_off)
                val pick = Intent(ctx, DevicePickerActivity::class.java)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                views.setOnClickPendingIntent(
                    R.id.widget_root,
                    PendingIntent.getActivity(
                        ctx, id, pick,
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                    )
                )
            } else {
                val state = DeviceRepo.cachedState(ctx, t.key)
                views.setTextViewText(R.id.widget_name, t.name)
                views.setTextViewText(
                    R.id.widget_state,
                    when {
                        busy -> "…"
                        t.locked -> ctx.getString(R.string.state_locked)
                        state == 1 -> ctx.getString(R.string.state_on)
                        state == 0 -> ctx.getString(R.string.state_off)
                        else -> ctx.getString(R.string.state_unknown)
                    }
                )
                views.setInt(
                    R.id.widget_root, "setBackgroundResource",
                    if (state == 1) R.drawable.widget_bg_on else R.drawable.widget_bg_off
                )
                val toggle = Intent(ctx, DeviceWidgetProvider::class.java)
                    .setAction(ACTION_TOGGLE)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                views.setOnClickPendingIntent(
                    R.id.widget_root,
                    PendingIntent.getBroadcast(
                        ctx, id, toggle,
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                    )
                )
            }
            AppWidgetManager.getInstance(ctx).updateAppWidget(id, views)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        val ctx = context.applicationContext
        when (intent.action) {
            ACTION_TOGGLE -> {
                val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1)
                val t = DeviceRepo.target(ctx, DeviceRepo.boundKey(ctx, slot(id))) ?: return
                if (t.locked) {
                    render(ctx, id, busy = false)
                    return
                }
                render(ctx, id, busy = true)
                val pending = goAsync()
                Thread {
                    try {
                        DeviceRepo.toggle(ctx, t)
                        // Same output may sit on several widgets.
                        ids(ctx).forEach { render(ctx, it, busy = false) }
                    } finally {
                        pending.finish()
                    }
                }.start()
            }
            AppWidgetManager.ACTION_APPWIDGET_UPDATE -> {
                val pending = goAsync()
                Thread {
                    try {
                        refreshAll(ctx)
                    } finally {
                        pending.finish()
                    }
                }.start()
            }
            else -> super.onReceive(context, intent)
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        appWidgetIds.forEach { DeviceRepo.unbind(context, slot(it)) }
    }
}
