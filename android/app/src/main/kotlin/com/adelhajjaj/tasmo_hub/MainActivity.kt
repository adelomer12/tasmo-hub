package com.adelhajjaj.tasmo_hub

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tasmohub/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Flutter pushes the device list so widgets and tiles can
                    // work without starting the Flutter engine.
                    "syncDevices" -> {
                        val json = call.argument<String>("devices") ?: "[]"
                        @Suppress("UNCHECKED_CAST")
                        val passwords =
                            call.argument<Map<String, String>>("passwords") ?: emptyMap()
                        Thread {
                            try {
                                DeviceRepo.sync(applicationContext, json, passwords)
                                DeviceWidgetProvider.refreshAll(applicationContext)
                            } catch (_: Exception) {
                            }
                        }.start()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
