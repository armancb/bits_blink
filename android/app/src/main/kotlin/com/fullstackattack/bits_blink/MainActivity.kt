package com.fullstackattack.bits_blink

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraManager
import android.content.Context
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.bitsblink/hardware"
    private val CAMERA_PERMISSION_CODE = 1001
    private var pendingResult: MethodChannel.Result? = null
    private var cameraProvider: ProcessCameraProvider? = null

    // Existing modem channel
    private val modemChannelName = "bitsblink/modem"

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
                            android.util.Log.e("BITSBlink", "Transmit error: ${e.message}")
                        } finally {
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

        // ── Debug capture channel ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "captureDebugFrame") {
                    pendingResult = result
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
                        == PackageManager.PERMISSION_GRANTED
                    ) {
                        captureFrame()
                    } else {
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.CAMERA),
                            CAMERA_PERMISSION_CODE
                        )
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAMERA_PERMISSION_CODE) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                captureFrame()
            } else {
                pendingResult?.error("PERMISSION_DENIED", "Camera permission denied", null)
                pendingResult = null
            }
        }
    }

    private fun captureFrame() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            try {
                val provider = cameraProviderFuture.get()
                this.cameraProvider = provider
                val executor = Executors.newSingleThreadExecutor()

                val imageAnalysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()

                imageAnalysis.setAnalyzer(executor) { imageProxy ->
                    var jpegBytes: ByteArray? = null
                    var errorMsg: String? = null

                    try {
                        jpegBytes = processFrame(imageProxy)
                    } catch (e: Exception) {
                        errorMsg = e.message ?: "Unknown processing error"
                        e.printStackTrace()
                    } finally {
                        imageProxy.close()
                    }

                    runOnUiThread {
                        try {
                            provider.unbindAll()
                        } catch (_: Exception) {}

                        if (jpegBytes != null) {
                            pendingResult?.success(jpegBytes)
                        } else {
                            pendingResult?.error("CAPTURE_ERROR", errorMsg, null)
                        }
                        pendingResult = null
                    }
                }

                provider.unbindAll()
                provider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    imageAnalysis
                )
            } catch (e: Exception) {
                pendingResult?.error("CAMERA_ERROR", e.message, null)
                pendingResult = null
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun processFrame(image: ImageProxy): ByteArray {
        val yPlane = image.planes[0]
        val yBuffer = yPlane.buffer.duplicate()
        val width = image.width
        val height = image.height
        val rowStride = yPlane.rowStride
        val pixelStride = yPlane.pixelStride

        val yBytes = ByteArray(width * height)
        yBuffer.rewind()

        if (rowStride == width && pixelStride == 1) {
            yBuffer.get(yBytes, 0, width * height)
        } else {
            val rowBuffer = ByteArray(rowStride)
            for (row in 0 until height) {
                val remaining = yBuffer.remaining()
                val toRead = if (row == height - 1) {
                    minOf(remaining, width)
                } else {
                    minOf(remaining, rowStride)
                }

                if (toRead <= 0) break

                if (row == height - 1 && remaining < rowStride) {
                    yBuffer.get(rowBuffer, 0, toRead)
                    System.arraycopy(rowBuffer, 0, yBytes, row * width, minOf(toRead, width))
                } else {
                    yBuffer.get(rowBuffer, 0, rowStride)
                    System.arraycopy(rowBuffer, 0, yBytes, row * width, width)
                }
            }
        }

        val blockSize = 8
        val roiBlocks = 4
        var bestSum = 0L
        var bestX = 0
        var bestY = 0

        val gridW = width / blockSize
        val gridH = height / blockSize

        if (gridW > roiBlocks && gridH > roiBlocks) {
            for (gy in 0 until gridH - roiBlocks) {
                for (gx in 0 until gridW - roiBlocks) {
                    var sum = 0L
                    for (by in 0 until roiBlocks) {
                        for (bx in 0 until roiBlocks) {
                            val px = (gx + bx) * blockSize + blockSize / 2
                            val py = (gy + by) * blockSize + blockSize / 2
                            if (py < height && px < width) {
                                sum += (yBytes[py * width + px].toInt() and 0xFF)
                            }
                        }
                    }
                    if (sum > bestSum) {
                        bestSum = sum
                        bestX = gx * blockSize
                        bestY = gy * blockSize
                    }
                }
            }
        }

        val roiSize = roiBlocks * blockSize
        val roiX = bestX.coerceIn(0, (width - roiSize).coerceAtLeast(0))
        val roiY = bestY.coerceIn(0, (height - roiSize).coerceAtLeast(0))

        drawRect(yBytes, width, height, roiX, roiY, roiSize, roiSize, 2)

        val nv21 = ByteArray(width * height * 3 / 2)
        System.arraycopy(yBytes, 0, nv21, 0, width * height)
        java.util.Arrays.fill(nv21, width * height, nv21.size, 128.toByte())

        val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
        val out = ByteArrayOutputStream()
        yuvImage.compressToJpeg(Rect(0, 0, width, height), 85, out)
        return out.toByteArray()
    }

    private fun drawRect(
        data: ByteArray, w: Int, h: Int,
        rx: Int, ry: Int, rw: Int, rh: Int, thickness: Int
    ) {
        val white: Byte = 0xFF.toByte()
        for (t in 0 until thickness) {
            for (x in rx until minOf(rx + rw, w)) {
                val topY = ry + t
                val botY = ry + rh - 1 - t
                if (topY in 0 until h) data[topY * w + x] = white
                if (botY in 0 until h) data[botY * w + x] = white
            }
            for (y in ry until minOf(ry + rh, h)) {
                val leftX = rx + t
                val rightX = rx + rw - 1 - t
                if (leftX in 0 until w) data[y * w + leftX] = white
                if (rightX in 0 until w) data[y * w + rightX] = white
            }
        }
    }
}
