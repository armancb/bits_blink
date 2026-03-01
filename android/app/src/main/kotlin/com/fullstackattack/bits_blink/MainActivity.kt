package com.fullstackattack.bits_blink

import android.Manifest
import android.content.pm.PackageManager
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.content.Context
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.bitsblink/hardware"
    private val STREAM_CHANNEL = "com.bitsblink/debug_stream"
    private val CAMERA_PERMISSION_CODE = 1001

    private val modemChannelName = "bitsblink/modem"

    private var cameraProvider: ProcessCameraProvider? = null
    private var eventSink: EventChannel.EventSink? = null
    private val isStreaming = AtomicBoolean(false)
    private var pendingStartResult: MethodChannel.Result? = null

    // DSP analyzer — maintains state across frames
    private val modemAnalyzer = ModemAnalyzer()

    // Throttle: ~15 FPS
    private var lastFrameTimeMs = 0L
    private val frameDeltaMs = 66L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Existing modem / transmit channel ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, modemChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "transmit") {
                    val signal = call.argument<List<Boolean>>("signal")
                    if (signal == null) {
                        result.error("BAD_ARGS", "Missing 'signal' argument", null)
                        return@setMethodCallHandler
                    }

                    Thread {
                        val cameraManager =
                            getSystemService(Context.CAMERA_SERVICE) as CameraManager
                        val cameraId = cameraManager.cameraIdList[0]
                        // Chip period in nanoseconds — 200ms gives ~6 frames per chip.
                        // This is the proven sweet spot for reliable frame-level OOK.
                        val chipPeriodNs = 200_000_000L  // 200ms

                        try {
                            for (state in signal) {
                                val startNs = System.nanoTime()
                                cameraManager.setTorchMode(cameraId, state)
                                // Busy-wait for precise timing (Thread.sleep has ~15ms jitter)
                                while (System.nanoTime() - startNs < chipPeriodNs) {
                                    // spin
                                }
                            }
                        } catch (e: Exception) {
                            android.util.Log.e("BITSBlink", "Transmit error: ${e.message}")
                        } finally {
                            try { cameraManager.setTorchMode(cameraId, false) } catch (_: Exception) {}
                        }
                    }.start()
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

        // ── Debug stream control channel ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startDebugStream" -> {
                        pendingStartResult = result
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
                            == PackageManager.PERMISSION_GRANTED
                        ) {
                            startStreaming()
                            result.success(true)
                            pendingStartResult = null
                        } else {
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.CAMERA),
                                CAMERA_PERMISSION_CODE
                            )
                        }
                    }
                    "stopDebugStream" -> {
                        stopStreaming()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── EventChannel for continuous frame streaming ──
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STREAM_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    stopStreaming()
                }
            })
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAMERA_PERMISSION_CODE) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startStreaming()
                pendingStartResult?.success(true)
            } else {
                pendingStartResult?.error("PERMISSION_DENIED", "Camera permission denied", null)
            }
            pendingStartResult = null
        }
    }

    private fun startStreaming() {
        if (isStreaming.get()) return
        isStreaming.set(true)

        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            try {
                val provider = cameraProviderFuture.get()
                this.cameraProvider = provider
                val executor = Executors.newSingleThreadExecutor()

                val builder = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)

                // ── CRITICAL: Lock to short exposure for rolling-shutter decoding ──
                // Without this, auto-exposure uses 10-33ms and the flash bands blur out.
                // 2ms exposure @ ISO 400 makes each row capture a brief instant,
                // revealing the ON/OFF bands from the transmitter's flashlight.
                @Suppress("UnsafeOptInUsageError")
                val extender = Camera2Interop.Extender(builder)
                extender.setCaptureRequestOption(
                    CaptureRequest.CONTROL_AE_MODE,
                    CaptureRequest.CONTROL_AE_MODE_OFF
                )
                extender.setCaptureRequestOption(
                    CaptureRequest.SENSOR_EXPOSURE_TIME,
                    2_000_000L  // 2 milliseconds (in nanoseconds)
                )
                extender.setCaptureRequestOption(
                    CaptureRequest.SENSOR_SENSITIVITY,
                    400  // ISO 400
                )

                val imageAnalysis = builder.build()

                imageAnalysis.setAnalyzer(executor) { imageProxy ->
                    if (!isStreaming.get()) {
                        imageProxy.close()
                        return@setAnalyzer
                    }

                    // Throttle frame rate
                    val now = System.currentTimeMillis()
                    if (now - lastFrameTimeMs < frameDeltaMs) {
                        imageProxy.close()
                        return@setAnalyzer
                    }
                    lastFrameTimeMs = now

                    try {
                        // Use the stateful ModemAnalyzer for DSP processing
                        val frameResult = modemAnalyzer.analyze(imageProxy)
                        val dataMap = frameResult.toMap()
                        runOnUiThread {
                            eventSink?.success(dataMap)
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                    } finally {
                        imageProxy.close()
                    }
                }

                provider.unbindAll()
                provider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    imageAnalysis
                )
            } catch (e: Exception) {
                android.util.Log.e("BITSBlink", "Camera error: ${e.message}")
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun stopStreaming() {
        isStreaming.set(false)
        try { cameraProvider?.unbindAll() } catch (_: Exception) {}
        cameraProvider = null
    }
}
