package com.fullstackattack.bits_blink

import android.hardware.camera2.CameraManager
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "bitsblink/modem"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "transmit") {
                    val signal = call.argument<List<Boolean>>("signal")
                    if (signal == null) {
                        result.error("BAD_ARGS", "Missing 'signal' argument", null)
                        return@setMethodCallHandler
                    }

                    // Run flashlight control on a background thread to avoid ANR.
                    Thread {
                        val cameraManager =
                            getSystemService(Context.CAMERA_SERVICE) as CameraManager
                        val cameraId = cameraManager.cameraIdList[0]

                        try {
                            for (state in signal) {
                                cameraManager.setTorchMode(cameraId, state)
                                Thread.sleep(15)
                            }
                        } catch (e: Exception) {
                            // Log but don't crash the background thread.
                            android.util.Log.e("BITSBlink", "Transmit error: ${e.message}")
                        } finally {
                            // Safety: always turn the flashlight OFF when done.
                            try {
                                cameraManager.setTorchMode(cameraId, false)
                            } catch (_: Exception) {}
                        }
                    }.start()

                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }
}
