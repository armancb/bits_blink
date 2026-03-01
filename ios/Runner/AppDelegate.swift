import Flutter
import UIKit
import AVFoundation

@main
<<<<<<< HEAD
@objc class AppDelegate: FlutterAppDelegate {

    private var captureSession: AVCaptureSession?
    private var pendingResult: FlutterResult?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        let controller = window?.rootViewController as! FlutterViewController
        let channel = FlutterMethodChannel(
            name: "com.bitsblink/hardware",
            binaryMessenger: controller.binaryMessenger
        )

        channel.setMethodCallHandler { [weak self] (call, result) in
            if call.method == "captureDebugFrame" {
                self?.pendingResult = result
                self?.requestCameraAndCapture()
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func requestCameraAndCapture() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            startCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startCapture()
                    } else {
                        self?.pendingResult?(
                            FlutterError(code: "PERMISSION_DENIED",
                                         message: "Camera permission denied", details: nil)
                        )
                        self?.pendingResult = nil
                    }
                }
            }
        default:
            pendingResult?(
                FlutterError(code: "PERMISSION_DENIED",
                             message: "Camera permission denied", details: nil)
            )
            pendingResult = nil
        }
    }

    private func startCapture() {
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        self.captureSession = session

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            pendingResult?(
                FlutterError(code: "CAMERA_ERROR", message: "Cannot open camera", details: nil)
            )
            pendingResult = nil
            return
        }

        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]

        let queue = DispatchQueue(label: "com.bitsblink.cameraQueue")
        let delegate = SingleFrameDelegate { [weak self] pixelBuffer in
            self?.captureSession?.stopRunning()
            self?.captureSession = nil

            guard let jpegData = self?.processPixelBuffer(pixelBuffer) else {
                DispatchQueue.main.async {
                    self?.pendingResult?(
                        FlutterError(code: "PROCESS_ERROR",
                                     message: "Failed to process frame", details: nil)
                    )
                    self?.pendingResult = nil
                }
                return
            }

            DispatchQueue.main.async {
                self?.pendingResult?(FlutterStandardTypedData(bytes: jpegData))
                self?.pendingResult = nil
            }
        }
        output.setSampleBufferDelegate(delegate, queue: queue)
        // Keep a strong reference so delegate isn't released
        objc_setAssociatedObject(output, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        session.addOutput(output)
        session.startRunning()
    }

    private func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return nil
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        // ── 1. Copy Y-plane to contiguous array ──
        let yData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        defer { yData.deallocate() }

        let src = yBaseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let srcRow = src.advanced(by: row * yRowBytes)
            let dstRow = yData.advanced(by: row * width)
            dstRow.update(from: srcRow, count: width)
        }

        // ── 2. Find brightest ROI (8×8 block scan, 4-block cluster) ──
        let blockSize = 8
        let roiBlocks = 4
        let gridW = width / blockSize
        let gridH = height / blockSize

        var bestSum: Int = 0
        var bestX = 0
        var bestY = 0

        for gy in 0..<(gridH - roiBlocks) {
            for gx in 0..<(gridW - roiBlocks) {
                var sum = 0
                for by in 0..<roiBlocks {
                    for bx in 0..<roiBlocks {
                        let px = (gx + bx) * blockSize + blockSize / 2
                        let py = (gy + by) * blockSize + blockSize / 2
                        sum += Int(yData[py * width + px])
                    }
                }
                if sum > bestSum {
                    bestSum = sum
                    bestX = gx * blockSize
                    bestY = gy * blockSize
                }
            }
        }

        let roiSize = roiBlocks * blockSize
        let roiX = min(max(bestX, 0), width - roiSize)
        let roiY = min(max(bestY, 0), height - roiSize)

        // ── 3. Draw bounding box (white, 2px) ──
        drawRect(yData, width: width, height: height,
                 rx: roiX, ry: roiY, rw: roiSize, rh: roiSize, thickness: 2)

        // ── 4. Create grayscale CGImage → JPEG ──
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: yData, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let cgImage = context.makeImage() else {
            return nil
        }

        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 0.85)
    }

    private func drawRect(_ data: UnsafeMutablePointer<UInt8>,
                          width: Int, height: Int,
                          rx: Int, ry: Int, rw: Int, rh: Int, thickness: Int) {
        let white: UInt8 = 255
        for t in 0..<thickness {
            for x in rx..<min(rx + rw, width) {
                let topIdx = (ry + t) * width + x
                let botIdx = (ry + rh - 1 - t) * width + x
                if ry + t < height { data[topIdx] = white }
                if ry + rh - 1 - t >= 0 && ry + rh - 1 - t < height { data[botIdx] = white }
            }
            for y in ry..<min(ry + rh, height) {
                let leftIdx = y * width + (rx + t)
                let rightIdx = y * width + (rx + rw - 1 - t)
                if rx + t < width { data[leftIdx] = white }
                if rx + rw - 1 - t >= 0 && rx + rw - 1 - t < width { data[rightIdx] = white }
            }
        }
    }
}

/// Captures exactly one frame then stops.
private class SingleFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var captured = false
    private let handler: (CVPixelBuffer) -> Void

    init(handler: @escaping (CVPixelBuffer) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !captured else { return }
        captured = true

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(pixelBuffer)
    }
=======
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let channelName = "bitsblink/modem"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Set up the method channel on the root FlutterViewController.
    if let controller = window?.rootViewController as? FlutterViewController {
      let modemChannel = FlutterMethodChannel(
        name: channelName,
        binaryMessenger: controller.binaryMessenger
      )

      modemChannel.setMethodCallHandler { [weak self] (call, result) in
        guard call.method == "transmit" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.handleTransmit(call: call, result: result)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  // MARK: - Transmit handler

  /// Receives a `List<bool>` signal from Dart and toggles the torch accordingly.
  private func handleTransmit(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let signal = args["signal"] as? [Bool]
    else {
      result(
        FlutterError(
          code: "BAD_ARGS",
          message: "Missing 'signal' argument",
          details: nil
        )
      )
      return
    }

    // Fire-and-forget: return success immediately, blink on a background thread.
    result(nil)

    DispatchQueue.global(qos: .userInitiated).async {
      guard
        let device = AVCaptureDevice.default(for: .video),
        device.hasTorch
      else {
        NSLog("BITSBlink: No torch available on this device")
        return
      }

      do {
        try device.lockForConfiguration()

        defer {
          // Safety: always turn the torch OFF when done.
          device.torchMode = .off
          device.unlockForConfiguration()
        }

        for state in signal {
          device.torchMode = state ? .on : .off
          Thread.sleep(forTimeInterval: 0.015)  // 15 ms per chip
        }
      } catch {
        NSLog("BITSBlink: Transmit error: \(error.localizedDescription)")
      }
    }
  }
>>>>>>> c76fb6c ("feat: iOS build succeeded, ready for transmitter logic")
}
